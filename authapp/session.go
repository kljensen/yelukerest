package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
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

// openSessionDatabase connects to the session store and proves it is usable
// before the server starts listening.
//
// Two separate failures are being ruled out here. database/sql opens lazily,
// so without a ping a bad password or an unreachable database becomes a 500 on
// somebody's first login rather than a container that refuses to start. And a
// ping that succeeds says nothing about the store itself, so verifySessionStore
// then exercises the real table -- see there for what that catches.
//
// ctx bounds the whole thing, so a database that accepts connections but never
// answers cannot hang the process at startup.
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
	if err := verifySessionStore(ctx, db, sessionTableName); err != nil {
		db.Close()
		// The two things that produce this, and neither is visible from a ping:
		// a database that has never had the migration deployed, and a role that
		// exists but was never granted anything on the table.
		return nil, fmt.Errorf("%w; deploy migrations/01a05285-...-add-authapp-session-store "+
			"and run authapp/sql/create-authapp-db-role.sh", err)
	}
	return db, nil
}

// verifySessionStore proves the store is genuinely usable, which PingContext
// does not: a ping only says PostgreSQL accepted the connection. A database
// restored or created without the migration, or a role whose grants were
// revoked, pings perfectly and then fails on every request -- Load 500s for
// anyone holding a cookie, and a fresh CAS login dies when SCS commits.
//
// So this runs the store's own statements against the real table, inside a
// transaction that is always rolled back. Writing rather than only reading is
// deliberate: SELECT alone would pass for a read-only or grant-starved role,
// which is exactly the half-provisioned case worth catching. INSERT ... ON
// CONFLICT DO UPDATE is privilege-checked for both INSERT and UPDATE when it is
// planned, so one statement covers two of the four grants.
//
// tableName is a compile-time constant at the only call site, not anything a
// request can influence, which is why it is interpolated rather than bound.
func verifySessionStore(ctx context.Context, db *sql.DB, tableName string) error {
	// Random, so the probe can never take a row lock on a live session for the
	// life of the transaction, and can never be mistaken for one if it somehow
	// escaped the rollback.
	tokenBytes := make([]byte, 16)
	if _, err := rand.Read(tokenBytes); err != nil {
		return fmt.Errorf("cannot generate a session store probe token: %w", err)
	}
	token := "startup-probe-" + hex.EncodeToString(tokenBytes)

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("cannot begin a transaction on the session database: %w", err)
	}
	// Every path out of here discards the probe, including the happy one below.
	defer tx.Rollback()

	// Already expired, so even an impossible leak of this row is unreadable:
	// SCS's Find filters on expiry.
	if _, err := tx.ExecContext(ctx,
		"INSERT INTO "+tableName+" (token, data, expiry) VALUES ($1, $2, $3)"+
			" ON CONFLICT (token) DO UPDATE SET data = excluded.data, expiry = excluded.expiry",
		token, []byte{}, time.Now().Add(-time.Minute),
	); err != nil {
		return fmt.Errorf("cannot write to the session store %s: %w", tableName, err)
	}
	var data []byte
	if err := tx.QueryRowContext(ctx,
		"SELECT data FROM "+tableName+" WHERE token = $1", token,
	).Scan(&data); err != nil {
		return fmt.Errorf("cannot read from the session store %s: %w", tableName, err)
	}
	if _, err := tx.ExecContext(ctx,
		"DELETE FROM "+tableName+" WHERE token = $1", token,
	); err != nil {
		return fmt.Errorf("cannot delete from the session store %s: %w", tableName, err)
	}

	// The rollback is the success path. If it fails the connection died partway
	// through, which is not a store to start listening on.
	if err := tx.Rollback(); err != nil {
		return fmt.Errorf("cannot roll back the session store check: %w", err)
	}
	return nil
}

// newSessionStore returns the SCS store backed by db, running its expiry
// cleanup every cleanupInterval.
func newSessionStore(db *sql.DB, cleanupInterval time.Duration) *postgresstore.PostgresStore {
	return postgresstore.NewWithConfig(db, postgresstore.Config{
		CleanUpInterval: cleanupInterval,
		TableName:       sessionTableName,
	})
}
