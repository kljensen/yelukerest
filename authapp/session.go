package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"time"

	"github.com/alexedwards/scs/postgresstore"

	// database/sql driver for the session store. lib/pq rather than pgx: it is
	// pure Go with no dependencies of its own, which keeps the vendored tree
	// and the scratch image the size they are, and a session store uses none
	// of what pgx adds.
	_ "github.com/lib/pq"
)

// sessionTableName is where SCS keeps sessions. Schema-qualified so the store
// does not depend on the connection's search_path, which is one environment
// variable away from being something else. The migration that creates it is
// migrations/01a05285-...-add-authapp-session-store.
const sessionTableName = "data.authapp_session"

// sessionCleanupInterval is how often expired rows are deleted. Sessions live
// 24 hours and nothing reads an expired one -- Find() filters on expiry -- so
// this only bounds how long dead rows sit there.
const sessionCleanupInterval = 5 * time.Minute

// openSessionDatabase connects to the session store and proves the connection
// works before the server starts listening.
//
// The ping is the point: database/sql opens lazily, so without it a bad
// password or an unreachable database becomes a 500 on somebody's first login
// rather than a container that refuses to start.
func openSessionDatabase(ctx context.Context, databaseURL string) (*sql.DB, error) {
	// Parsed here so that a malformed URL is our error message and not the
	// driver's, which has no reason to keep the password out of it.
	parsed, err := url.Parse(databaseURL)
	if err != nil {
		return nil, errors.New("AUTHAPP_DB_URL is not a valid URL")
	}
	if parsed.Scheme != "postgres" && parsed.Scheme != "postgresql" {
		return nil, fmt.Errorf("AUTHAPP_DB_URL must be a postgres:// URL, not %q", parsed.Scheme)
	}

	db, err := sql.Open("postgres", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("cannot open the session database: %w", err)
	}

	// Every request through LoadAndSave touches this pool, but a request costs
	// one short statement and the whole course is ~60 people, so the pool is
	// sized to stay well clear of the database's connection limit rather than
	// to absorb concurrency. Hydra's is the same shape.
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(2)
	db.SetConnMaxIdleTime(5 * time.Minute)
	// Bounded so a rotated password or a restarted database is picked up by
	// connections aging out, instead of a pooled connection holding the old
	// state indefinitely.
	db.SetConnMaxLifetime(time.Hour)

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("cannot reach the session database: %w", err)
	}
	return db, nil
}

// newSessionStore returns the SCS store backed by db, running its expiry
// cleanup every cleanupInterval.
func newSessionStore(db *sql.DB, cleanupInterval time.Duration) *postgresstore.PostgresStore {
	return postgresstore.NewWithConfig(db, postgresstore.Config{
		CleanUpInterval: cleanupInterval,
		TableName:       sessionTableName,
	})
}
