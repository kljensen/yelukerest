package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestBearerToken(t *testing.T) {
	cases := []struct {
		name   string
		header string
		want   string
	}{
		{"absent", "", ""},
		{"bearer", "Bearer yk_deadbeef_" + strings.Repeat("a", 64), "yk_deadbeef_" + strings.Repeat("a", 64)},
		// Clients and the assistants writing them are careless about case.
		{"lowercase scheme", "bearer abc", "abc"},
		{"surrounding space", "Bearer   abc  ", "abc"},
		// A different scheme is not a bearer token; accepting it would let a
		// caller smuggle Basic credentials into this path.
		{"basic rejected", "Basic abc", ""},
		{"scheme only", "Bearer ", ""},
		{"no scheme", "yk_deadbeef_abc", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/auth/token", nil)
			if tc.header != "" {
				r.Header.Set("Authorization", tc.header)
			}
			if got := bearerToken(r); got != tc.want {
				t.Fatalf("bearerToken() = %q, want %q", got, tc.want)
			}
		})
	}
}

func makeJWTWithExp(exp int64) string {
	payload, _ := json.Marshal(map[string]int64{"exp": exp})
	return "aGVhZGVy." + base64.RawURLEncoding.EncodeToString(payload) + ".c2ln"
}

func TestExpiresInFromJWT(t *testing.T) {
	now := time.Unix(1_000_000, 0)

	if got := expiresInFromJWT(makeJWTWithExp(1_003_600), now); got != 3600 {
		t.Fatalf("expected 3600 seconds remaining, got %d", got)
	}

	// An already-expired token must report 0, never a negative number: a client
	// scheduling a refresh on a negative interval would spin.
	if got := expiresInFromJWT(makeJWTWithExp(999_000), now); got != 0 {
		t.Fatalf("expected 0 for an expired token, got %d", got)
	}

	// Anything unparseable reports 0, which the client should read as
	// "refresh when you see a 401" rather than as an error.
	for _, bad := range []string{"", "not.a.jwt", "onlyonepart", "a.b", "a.!!!.c"} {
		if got := expiresInFromJWT(bad, now); got != 0 {
			t.Fatalf("expected 0 for malformed token %q, got %d", bad, got)
		}
	}
}

// A missing or malformed credential must be refused before anything reaches
// PostgREST, and must say so as a credential problem.
func TestExchangeHandlerRejectsMissingCredential(t *testing.T) {
	handler := exchangeAPITokenHandler(FetchJWTConfig{PostgrestHost: "127.0.0.1", PostgrestPort: "1"})

	r := httptest.NewRequest(http.MethodPost, "/auth/token", nil)
	w := httptest.NewRecorder()
	handler(w, r)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without a credential, got %d", w.Code)
	}
	if got := w.Header().Get("WWW-Authenticate"); !strings.Contains(got, "Bearer") {
		t.Fatalf("expected a Bearer challenge, got %q", got)
	}
	// The response must not be cached: it is a credential exchange.
	if got := w.Header().Get("Cache-Control"); !strings.Contains(got, "no-store") {
		t.Fatalf("expected no-store, got %q", got)
	}
}

func TestExchangeHandlerRejectsNonPost(t *testing.T) {
	handler := exchangeAPITokenHandler(FetchJWTConfig{PostgrestHost: "127.0.0.1", PostgrestPort: "1"})
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		r := httptest.NewRequest(method, "/auth/token", nil)
		r.Header.Set("Authorization", "Bearer yk_deadbeef_"+strings.Repeat("a", 64))
		w := httptest.NewRecorder()
		handler(w, r)
		if w.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s: expected 405, got %d", method, w.Code)
		}
	}
}

// Every refusal from the RPC has to reach the caller as an indistinguishable
// 401. If a revoked token produced a different status from an unknown one, the
// endpoint would be an oracle for which prefixes exist.
func TestExchangeRefusalsAreIndistinguishable(t *testing.T) {
	for _, status := range []int{http.StatusNotFound, http.StatusNotAcceptable} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			fmt.Fprint(w, `{"message":"no rows"}`)
		}))
		host, port := splitHostPortForTest(t, srv.URL)
		_, err, got := exchangeAPIToken("yk_deadbeef_"+strings.Repeat("a", 64),
			FetchJWTConfig{PostgrestHost: host, PostgrestPort: port, AuthappJWT: "x"})
		srv.Close()
		if err == nil {
			t.Fatalf("postgrest %d: expected an error", status)
		}
		if got != http.StatusUnauthorized {
			t.Fatalf("postgrest %d: expected 401 out, got %d", status, got)
		}
	}
}

// An empty jwt in an otherwise-200 response must not be handed to the caller as
// a successful exchange.
func TestExchangeRejectsEmptyJWT(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"jwt":"","user_id":1,"netid":"abc123","role":"student","scopes":[]}`)
	}))
	defer srv.Close()
	host, port := splitHostPortForTest(t, srv.URL)
	_, err, status := exchangeAPIToken("yk_deadbeef_"+strings.Repeat("a", 64),
		FetchJWTConfig{PostgrestHost: host, PostgrestPort: port, AuthappJWT: "x"})
	if err == nil || status != http.StatusUnauthorized {
		t.Fatalf("expected 401 for an empty jwt, got status %d err %v", status, err)
	}
}

// The service credential, not the presented token, is what authenticates to
// PostgREST -- and the presented token must travel in the body, never in the
// URL, where it would land in access logs.
func TestExchangeSendsServiceCredentialAndKeepsTokenOutOfURL(t *testing.T) {
	const presented = "yk_deadbeef_" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	var sawAuth, sawURL string
	var sawBody map[string]string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth = r.Header.Get("Authorization")
		sawURL = r.URL.String()
		_ = json.NewDecoder(r.Body).Decode(&sawBody)
		fmt.Fprintf(w, `{"jwt":%q,"user_id":1,"netid":"abc123","role":"student","scopes":["course:read"]}`,
			makeJWTWithExp(time.Now().Unix()+3600))
	}))
	defer srv.Close()

	host, port := splitHostPortForTest(t, srv.URL)
	result, err, _ := exchangeAPIToken(presented,
		FetchJWTConfig{PostgrestHost: host, PostgrestPort: port, AuthappJWT: "service-jwt"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sawAuth != "Bearer service-jwt" {
		t.Fatalf("expected the authapp service credential, got %q", sawAuth)
	}
	if strings.Contains(sawURL, presented) {
		t.Fatalf("the presented token must not appear in the URL: %q", sawURL)
	}
	if sawBody["p_token"] != presented {
		t.Fatalf("expected the token in the request body, got %q", sawBody["p_token"])
	}
	if len(result.Scopes) != 1 || result.Scopes[0] != "course:read" {
		t.Fatalf("scopes not carried through: %v", result.Scopes)
	}
}

func splitHostPortForTest(t *testing.T, rawURL string) (string, string) {
	t.Helper()
	trimmed := strings.TrimPrefix(rawURL, "http://")
	idx := strings.LastIndex(trimmed, ":")
	if idx < 0 {
		t.Fatalf("cannot split %q", rawURL)
	}
	return trimmed[:idx], trimmed[idx+1:]
}

// The exchange limit must be per token, not per IP: a whole class behind campus
// NAT shares one address, so an IP bucket would let one student's retry loop
// lock out everyone else.
func TestAPITokenRateLimitKeyIsPerToken(t *testing.T) {
	withToken := func(tok string) *http.Request {
		r := httptest.NewRequest(http.MethodPost, "/auth/token", nil)
		r.RemoteAddr = "203.0.113.7:12345"
		if tok != "" {
			r.Header.Set("Authorization", "Bearer "+tok)
		}
		return r
	}

	a := apiTokenRateLimitKey(withToken("yk_2be8b799_" + strings.Repeat("a", 64)))
	b := apiTokenRateLimitKey(withToken("yk_ffffffff_" + strings.Repeat("b", 64)))
	if a == b {
		t.Fatalf("two different tokens from one IP must not share a bucket: %q", a)
	}
	if !strings.HasPrefix(a, "tok:") {
		t.Fatalf("expected a token-keyed bucket, got %q", a)
	}

	// The same token always lands in the same bucket, whatever the secret half
	// looks like -- otherwise the limit would be trivially evaded.
	same := apiTokenRateLimitKey(withToken("yk_2be8b799_" + strings.Repeat("c", 64)))
	if same != a {
		t.Fatalf("the same token prefix must share a bucket: %q vs %q", a, same)
	}

	// Callers with no usable token fall back to the IP bucket, so someone
	// cycling malformed credentials cannot get a fresh bucket each attempt.
	none := apiTokenRateLimitKey(withToken(""))
	if !strings.HasPrefix(none, "ip:") {
		t.Fatalf("expected an IP-keyed fallback, got %q", none)
	}
	if garbage := apiTokenRateLimitKey(withToken("not-a-token")); !strings.HasPrefix(garbage, "ip:") {
		t.Fatalf("expected malformed credentials to fall back to the IP bucket, got %q", garbage)
	}
}
