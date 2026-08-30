package main

import (
	"context"
	"database/sql"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestOpenSessionDatabaseRejectsNonPostgresURLs(t *testing.T) {
	cases := []struct {
		name string
		url  string
	}{
		{"empty", ""},
		{"not a url", "://"},
		{"wrong scheme", "mysql://user:pw@host/db"},
		// A bare DSN would be accepted by lib/pq but is not what compose
		// supplies, and silently accepting both makes it harder to tell which
		// form a broken deploy was given.
		{"key value dsn", "host=db user=authapp"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db, err := openSessionDatabase(context.Background(), tc.url)
			if err == nil {
				db.Close()
				t.Fatalf("openSessionDatabase(%q) succeeded, want an error", tc.url)
			}
			// The URL carries the session store password, so the message must
			// never quote it back.
			if tc.url != "" && contains(err.Error(), tc.url) {
				t.Fatalf("error message repeats the connection URL: %v", err)
			}
		})
	}
}

func contains(haystack, needle string) bool {
	if needle == "" {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

// sessionTestDatabaseURL returns the connection URL for the tests below, or
// skips. They need a real database because the whole claim being tested is
// that the session outlives the process, and an in-memory store cannot fail
// that test for the right reason.
//
// Point it at a disposable database with the migration applied:
//
//	AUTHAPP_TEST_DATABASE_URL=postgres://... go test ./...
func sessionTestDatabaseURL(t *testing.T) string {
	t.Helper()
	databaseURL := os.Getenv("AUTHAPP_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("AUTHAPP_TEST_DATABASE_URL is not set; skipping the session store tests")
	}
	return databaseURL
}

// startSessionServer stands up one authapp-shaped process: its own connection
// pool, its own store, its own session manager. Calling it twice is what a
// container recreate looks like from the session's point of view.
func startSessionServer(t *testing.T, databaseURL string) *httptest.Server {
	t.Helper()
	db, err := openSessionDatabase(context.Background(), databaseURL)
	if err != nil {
		t.Fatalf("openSessionDatabase: %v", err)
	}
	store := newSessionStore(db, sessionCleanupInterval)
	sessionManager := newSessionManager(true, store)

	mux := http.NewServeMux()
	mux.HandleFunc("/put", func(w http.ResponseWriter, r *http.Request) {
		sessionManager.Put(r.Context(), "netid", r.URL.Query().Get("netid"))
	})
	mux.HandleFunc("/get", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, sessionManager.GetString(r.Context(), "netid"))
	})

	server := httptest.NewServer(sessionManager.LoadAndSave(mux))
	t.Cleanup(func() {
		server.Close()
		store.StopCleanup()
		db.Close()
	})
	return server
}

func TestSessionSurvivesAProcessRestart(t *testing.T) {
	databaseURL := sessionTestDatabaseURL(t)

	first := startSessionServer(t, databaseURL)
	response, err := http.Get(first.URL + "/put?netid=jane99")
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	response.Body.Close()

	var sessionCookie *http.Cookie
	for _, cookie := range response.Cookies() {
		if cookie.Name == "session" {
			sessionCookie = cookie
		}
	}
	if sessionCookie == nil {
		t.Fatal("no session cookie was set")
	}

	// Everything the first process held is gone: pool, store, and the
	// SessionManager's own state.
	first.Close()

	second := startSessionServer(t, databaseURL)
	request, err := http.NewRequest(http.MethodGet, second.URL+"/get", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	request.AddCookie(sessionCookie)
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if string(body) != "jane99" {
		t.Fatalf("netid after restart = %q, want %q", body, "jane99")
	}
}

func TestExpiredSessionsAreDeleted(t *testing.T) {
	databaseURL := sessionTestDatabaseURL(t)

	db, err := openSessionDatabase(context.Background(), databaseURL)
	if err != nil {
		t.Fatalf("openSessionDatabase: %v", err)
	}
	defer db.Close()

	// A short interval so the test does not wait five minutes for the
	// production one. The behaviour under test is the cleanup pass itself.
	store := newSessionStore(db, 20*time.Millisecond)
	defer store.StopCleanup()

	const token = "expired-session-token-for-tests"
	if err := store.Commit(token, []byte("payload"), time.Now().Add(-time.Minute)); err != nil {
		t.Fatalf("commit: %v", err)
	}
	t.Cleanup(func() {
		db.Exec("DELETE FROM "+sessionTableName+" WHERE token = $1", token)
	})

	// Already unreadable before any cleanup runs: Find filters on expiry, so
	// an expired row is never honoured even if the row outlives it.
	if _, exists, err := store.Find(token); err != nil || exists {
		t.Fatalf("Find of an expired session: exists = %v, err = %v", exists, err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		var rows int
		if err := db.QueryRow("SELECT count(*) FROM "+sessionTableName+" WHERE token = $1", token).Scan(&rows); err != nil && err != sql.ErrNoRows {
			t.Fatalf("count: %v", err)
		}
		if rows == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the expired session row was still there after 5s")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
