package persistence

import (
	"context"
	"database/sql"
	"fmt"
	"github.com/sirupsen/logrus"
	"time"

	"github.com/cds-snc/covid-alert-server/pkg/keyclaim"
)

// Event the event that we are to log
// Identifier The EventType of the event
// DeviceType the DeviceType of the event
// Date The date the event was generated on
// Count The number of times the event occurred
// Originator The bearerToken that the event belongs to
type Event struct {
	Identifier EventType
	DeviceType DeviceType
	Date       time.Time
	Count      int
	Originator string
}

var originatorLookup keyclaim.Authenticator

// SetupLookup Setup the originator lookup used to map events to bearerTokens
func SetupLookup(lookup keyclaim.Authenticator) {
	originatorLookup = lookup
}

func translateToken(token string) string {
	region, ok := originatorLookup.Authenticate(token)

	// If we forgot to map a token to a PT just return the token
	if region == "302" {
		return token
	}

	// If it's an old token or unknown just return the token
	if ok == false {
		return token
	}

	return region
}

// translateTokenForLogs Since we don't want to log bearer tokens to the log file we only use the first and last character
func translateTokenForLogs(token string) string {
	region, ok := originatorLookup.Authenticate(token)

	if region == "302" || ok == false {
		return fmt.Sprintf("%v...%v", token[0:1], token[len(token)-1:len(token)])
	}

	return region
}

// LogEvent Log a failed Event
func LogEvent(ctx context.Context, err error, event Event) {

	log(ctx, err).WithFields(logrus.Fields{
		"Originator": translateTokenForLogs(event.Originator),
		"DeviceType": event.DeviceType,
		"Identifier": event.Identifier,
		"Date":       event.Date,
		"Count":      event.Count,
	}).Warn("Unable to log event")
}

// SaveEvent log an Event in the database
func (c *conn) SaveEvent(event Event) error {

	if err := saveEvent(c.db, event); err != nil {
		return err
	}
	return nil
}

func saveEvent(db *sql.DB, e Event) error {
	if err := e.DeviceType.IsValid(); err != nil {
		return err
	}

	if err := e.Identifier.IsValid(); err != nil {
		return err
	}

	originator := translateToken(e.Originator)

	tx, err := db.Begin()
	if err != nil {
		return err
	}

	if _, err := tx.Exec(`
		INSERT INTO events
		(source, identifier, device_type, date, count)
		VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE count = count + ?`,
		originator, e.Identifier, e.DeviceType, e.Date.Format("2006-01-02"), e.Count, e.Count); err != nil {

		if err := tx.Rollback(); err != nil {
			return err
		}
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	return nil
}

type Events struct {
	Source string `json:"source"`
	Date       string `json:"date"`
	Count      int64  `json:"count"`
}

func (c *conn) GetServerEventsByType(eventType EventType, startDate string, endDate string) ([]Events, error) {
	return getServerEventsByType(c.db, eventType, startDate, endDate)
}

func getServerEventsByType(db *sql.DB, eventType EventType, startDate string, endDate string) ([]Events, error){

	if startDate == "" {
		return nil, fmt.Errorf("start date is required for querying server dates")
	}

	var rows *sql.Rows
	if endDate == "" {
		var err error
		rows, err = db.Query(`
		SELECT source, date, count 
		FROM events 
		WHERE events.identifier = ? AND events.device_type = ? AND events.date = ?`,
			eventType, Server, startDate)

		if err != nil {
			return nil, err
		}
	} else {

		var err error
		rows, err = db.Query(`
		SELECT source, date, count 
		FROM events 
		WHERE events.identifier = ? 
		  AND events.device_type = ? 
		  AND events.Date >= ?
		  AND events.Date <= ?`,
			eventType, Server, startDate, endDate)

		if err != nil {
			return nil, err
		}
	}

	var events []Events

	for rows.Next() {
		e := Events{}
		var t time.Time

		err := rows.Scan(&e.Source, &t, &e.Count)

		if err != nil {
			return nil, err
		}

		e.Date = t.Format("2006-01-02")
		events = append(events, e)
	}

	if events == nil {
		events = make([]Events,0)
	}
	return events, nil
}

