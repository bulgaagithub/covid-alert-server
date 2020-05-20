# frozen_string_literal: true

require('bundler/setup')

require_relative('protocol/covidshield_pb')
require('minitest/autorun')
require('mocha/minitest')
require('open3')
require('faraday')
require('rbnacl')
require('mysql2')

KEY_SUBMISSION_SERVER = File.expand_path('../../build/debug/key-submission', __dir__)
KEY_RETRIEVAL_SERVER = File.expand_path('../../build/debug/key-retrieval', __dir__)

begin
  DB_HOST = ENV.fetch('DB_HOST')
  DB_USER = ENV.fetch('DB_USER')
  DB_PASS = ENV.fetch('DB_PASS')
  DB_NAME = ENV.fetch('DB_NAME', 'test')
rescue KeyError
  raise('DB_HOST, DB_USER, and DB_PASS are all required environment variables')
end

DATABASE_URL = "#{DB_USER}#{DB_PASS}@tcp(#{DB_HOST})/#{DB_NAME}"

SUBMISSION_SERVER_ADDR = "127.0.0.1:18481"
RETRIEVAL_SERVER_ADDR = "127.0.0.1:18482"

module Helper
  module Include
    def run
      Helper.with_server_with_pristine_database do |sub_conn, ret_conn|
        @sub_conn = sub_conn
        @ret_conn = ret_conn
        @dbconn = Mysql2::Client.new(
          host: DB_HOST, username: DB_USER, password: DB_PASS, database: DB_NAME,
        )
        super
      end
    end

    def get_exposure_config(region, method: :get)
      @ret_conn.send(method, "/exposure-configuration/#{region}.json")
    end

    def get_day(day, method: :get)
      date = day.is_a?(String) ? day : day.iso8601
      hmac = OpenSSL::HMAC.hexdigest(
        "SHA256",
        [ENV.fetch("RETRIEVE_HMAC_KEY")].pack("H*"),
        "#{date}:#{Time.now.to_i / 3600}"
      )
      @ret_conn.send(method, "/retrieve-day/#{date}/#{hmac}")
    end

    def get_hour(day, hour)
      date = day.is_a?(String) ? day : day.iso8601
      hour = format("%02d", hour)
      hmac = OpenSSL::HMAC.hexdigest(
        "SHA256",
        [ENV.fetch("RETRIEVE_HMAC_KEY")].pack("H*"),
        "#{date}:#{hour}:#{Time.now.to_i / 3600}"
      )
      @ret_conn.get("/retrieve-hour/#{date}/#{hour}/#{hmac}")
    end

    def new_valid_one_time_code
      resp = @sub_conn.post do |req|
        req.url('/new-key-claim')
        req.headers['Authorization'] = 'Bearer first-token'
      end
      assert_response(resp, 200, 'text/plain; charset=utf-8')
      resp.body.chomp
    end

    def new_valid_keyset
      otc = new_valid_one_time_code

      app_private_key = RbNaCl::PrivateKey.generate
      app_public_key  = app_private_key.public_key

      kcq = Covidshield::KeyClaimRequest.new(
        one_time_code: otc,
        app_public_key: app_public_key.to_s,
      )
      resp = @sub_conn.post('/claim-key', kcq.to_proto)
      assert_response(resp, 200, 'application/x-protobuf')
      kcr = Covidshield::KeyClaimResponse.decode(resp.body)
      assert_equal(:NONE, kcr.error)
      assert_equal(32, kcr.server_public_key.each_byte.size)

      {
        app_public: app_public_key,
        app_private: app_private_key,
        server_public: kcr.server_public_key
      }
    end

    def move_forward_days(days)
      move_forward_hours(days * 24)
    end

    def move_forward_seconds(seconds)
      raise('does not adjust diagnosis_keys') if seconds >= 1200

      @dbconn.prepare(<<~SQL).execute(seconds)
        UPDATE encryption_keys SET created = created - INTERVAL ? SECOND
      SQL
    end

    def move_forward_hours(hours)
      @dbconn.prepare(<<~SQL).execute(hours)
        UPDATE encryption_keys SET created = created - INTERVAL ? HOUR
      SQL
      @dbconn.prepare(<<~SQL).execute(hours, hours)
        UPDATE diagnosis_keys SET
          rolling_start_interval_number = rolling_start_interval_number - (6 * ?),
          hour_of_submission = hour_of_submission - ?
      SQL
    end

    def assert_response(resp, status, content_type, body: nil)
      assert_equal(status, resp.status)
      assert_equal(resp.headers['Content-Type'], content_type)
      case body
      when String
        assert_equal(body, resp.body)
      when Regexp
        assert_match(/\A[0-9]{8}\n\z/m, resp.body)
      end
    end

    def today_utc
      Date.parse(Time.now.utc.strftime("%Y-%m-%d"))
    end

    def yesterday_utc
      today_utc.prev_day
    end

    def time_in_date(time, date)
      Time.parse("#{date.iso8601}T#{time}Z")
    end

    def expect(*data)
      data = Array(data).flatten
      assert_equal(data, @buf.shift(data.size), "  (from #{caller_locations[0]})")
    end

    BIG_ENDIAN_UINT32 = 'N'
    BIG_ENDIAN_UINT16 = 'n'

    def uint32(int)
      [int].pack(BIG_ENDIAN_UINT32).bytes.to_a
    end

    def uint16(int)
      [int].pack(BIG_ENDIAN_UINT16).bytes.to_a
    end

    def load_retrieve_stream
      files = []
      first = true
      until @buf.empty?
        len = read_uint32
        return [] if len == 0 && first
        first = false
        files << Covidshield::TemporaryExposureKeyExport.decode(@buf.shift(len).map(&:chr).join)
      end
      files
    end

    def expect_retrieve_data(resp, exp, depth=0)
      @buf = resp.body.each_byte.to_a
      files = load_retrieve_stream
      assert_equal(exp, files, "  (from #{caller[depth]})")
    end

    def read_uint16
      @buf.shift(2).map(&:chr).join.unpack(BIG_ENDIAN_UINT16).first
    end

    def read_uint32
      @buf.shift(4).map(&:chr).join.unpack(BIG_ENDIAN_UINT32).first
    end
  end

  class << self
    def with_server_with_pristine_database(&block)
      with_pristine_database { with_servers(&block) }
    end

    def with_servers(&block)
      with_server(KEY_RETRIEVAL_SERVER, RETRIEVAL_SERVER_ADDR) do |ret_conn|
        with_server(KEY_SUBMISSION_SERVER, SUBMISSION_SERVER_ADDR) do |sub_conn|
          block.call(sub_conn, ret_conn)
        end
      end
    end

    def with_server(bin, addr, &block)
      pid = Process.spawn(
        {
          'BIND_ADDR' => addr,
          'KEY_CLAIM_TOKEN' => 'first-token=ON:second-token=PE',
          'DATABASE_URL' => DATABASE_URL,
        },
        bin, STDERR => File.open('/dev/null')
      )
      conn = Faraday.new(url: "http://#{addr}")
      20.times do
        sleep(0.02)
        begin
          body = conn.get("/services/ping").body.chomp
        rescue Faraday::ConnectionFailed
        end
        break if body == "OK"
      end
      block.call(conn)
    ensure
      Process.kill('TERM', pid)
      begin
        Timeout.timeout(1) { Process.waitpid(pid) }
      rescue Timeout::ERROR
        Process.kill('KILL', pid)
      end
    end

    private

    def with_pristine_database(&block)
      purge_db
      block.call
    ensure
      purge_db
    end

    def purge_db
      oe, stat = Open3.capture2e(
        'mysqladmin', "--host=#{DB_HOST}", "--user=#{DB_USER}",
        "--password=#{DB_PASS}", '-f', 'drop', DB_NAME
      )
      return if stat.success?
      raise("purge_db failed: #{oe}") unless oe.include?("doesn't exist")
    end
  end
end
