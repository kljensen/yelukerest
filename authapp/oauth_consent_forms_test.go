package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/alexedwards/scs/v2"
)

// withSession runs fn inside a real scs session so the consent-form helpers
// exercise the same storage the handlers use.
func withSession(t *testing.T, fn func(r *http.Request, sm *scs.SessionManager)) {
	t.Helper()
	sm := scs.New()
	sm.Lifetime = time.Hour
	handler := sm.LoadAndSave(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fn(r, sm)
	}))
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))
}

// The bug this replaces: the consent token lived in one slot, so rendering a
// second consent page invalidated the first. Safari opened /oauth2/auth twice
// in the same second during a Claude Desktop connect, and clicking Allow on the
// page the user was looking at returned "this form has expired".
func TestSecondConsentPageDoesNotInvalidateTheFirst(t *testing.T) {
	withSession(t, func(r *http.Request, sm *scs.SessionManager) {
		rememberConsentForm(r, sm, "challenge-one", "token-one")
		rememberConsentForm(r, sm, "challenge-two", "token-two")

		if got := consumeConsentForm(r, sm, "challenge-one"); got != "token-one" {
			t.Fatalf("first form should still be submittable, got %q", got)
		}
		if got := consumeConsentForm(r, sm, "challenge-two"); got != "token-two" {
			t.Fatalf("second form should still be submittable, got %q", got)
		}
	})
}

// Each form stays single-use, so a replayed submission cannot re-grant.
func TestConsentFormIsSingleUse(t *testing.T) {
	withSession(t, func(r *http.Request, sm *scs.SessionManager) {
		rememberConsentForm(r, sm, "challenge", "token")
		if got := consumeConsentForm(r, sm, "challenge"); got != "token" {
			t.Fatalf("first use should succeed, got %q", got)
		}
		if got := consumeConsentForm(r, sm, "challenge"); got != "" {
			t.Fatalf("replay must not return a token, got %q", got)
		}
	})
}

// Consuming one form must not disturb the others: a duplicated navigation
// should not invalidate the page the user is actually looking at.
func TestConsumingOneFormLeavesOthers(t *testing.T) {
	withSession(t, func(r *http.Request, sm *scs.SessionManager) {
		rememberConsentForm(r, sm, "a", "token-a")
		rememberConsentForm(r, sm, "b", "token-b")
		_ = consumeConsentForm(r, sm, "a")
		if got := consumeConsentForm(r, sm, "b"); got != "token-b" {
			t.Fatalf("unrelated form was disturbed, got %q", got)
		}
	})
}

// The bound is what the old single slot was protecting: a client reloading with
// fresh challenges must not grow the session without limit.
func TestOutstandingFormsAreBounded(t *testing.T) {
	withSession(t, func(r *http.Request, sm *scs.SessionManager) {
		for i := 0; i < consentFormsKept*3; i++ {
			rememberConsentForm(r, sm, string(rune('a'+i)), "token")
		}
		if got := len(loadConsentForms(r, sm)); got != consentFormsKept {
			t.Fatalf("expected at most %d outstanding forms, got %d", consentFormsKept, got)
		}
		// The oldest are the ones dropped, so the newest page still works.
		newest := string(rune('a' + consentFormsKept*3 - 1))
		if got := consumeConsentForm(r, sm, newest); got != "token" {
			t.Fatalf("the most recent form must survive eviction, got %q", got)
		}
	})
}

// Re-rendering the SAME challenge replaces its token rather than accumulating.
func TestRerenderingSameChallengeReplacesItsToken(t *testing.T) {
	withSession(t, func(r *http.Request, sm *scs.SessionManager) {
		rememberConsentForm(r, sm, "same", "old")
		rememberConsentForm(r, sm, "same", "new")
		if got := len(loadConsentForms(r, sm)); got != 1 {
			t.Fatalf("expected one entry for a re-rendered challenge, got %d", got)
		}
		if got := consumeConsentForm(r, sm, "same"); got != "new" {
			t.Fatalf("the newest render should win, got %q", got)
		}
	})
}

// An unknown challenge yields nothing, so a forged submission is refused.
func TestUnknownChallengeYieldsNoToken(t *testing.T) {
	withSession(t, func(r *http.Request, sm *scs.SessionManager) {
		rememberConsentForm(r, sm, "real", "token")
		if got := consumeConsentForm(r, sm, "forged"); got != "" {
			t.Fatalf("a forged challenge must not return a token, got %q", got)
		}
	})
}
