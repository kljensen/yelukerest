package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// One key for the whole file; generating RSA keys is the slow part of these
// tests and nothing here depends on the key being fresh.
var (
	testAppKeyOnce sync.Once
	testAppKey     *rsa.PrivateKey
)

func githubTestKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	testAppKeyOnce.Do(func() {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			panic(err)
		}
		testAppKey = key
	})
	return testAppKey
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// requireGitHubHeaders fails the request the way a reviewer would: every call
// must carry the pinned API version, the JSON media type, and a bearer token.
func requireGitHubHeaders(t *testing.T, r *http.Request, wantToken string) {
	t.Helper()
	if got := r.Header.Get("X-GitHub-Api-Version"); got != githubAPIVersion {
		t.Errorf("%s %s: X-GitHub-Api-Version = %q, want %q", r.Method, r.URL.Path, got, githubAPIVersion)
	}
	if got := r.Header.Get("Accept"); got != "application/vnd.github+json" {
		t.Errorf("%s %s: Accept = %q", r.Method, r.URL.Path, got)
	}
	if got := r.Header.Get("Authorization"); got != "Bearer "+wantToken {
		t.Errorf("%s %s: Authorization = %q, want bearer %q", r.Method, r.URL.Path, got, wantToken)
	}
}

// verifyAppJWT checks the JWT the token source presents to GitHub: RS256 over
// the header and claims, issuer equal to the App id, and a lifetime GitHub
// would accept.
func verifyAppJWT(t *testing.T, key *rsa.PrivateKey, authorization, wantAppID string, now time.Time) {
	t.Helper()
	token := strings.TrimPrefix(authorization, "Bearer ")
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("app JWT has %d parts", len(parts))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("decoding signature: %v", err)
	}
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], signature); err != nil {
		t.Fatalf("app JWT signature does not verify: %v", err)
	}
	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatalf("decoding claims: %v", err)
	}
	var claims struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
		Exp int64  `json:"exp"`
	}
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		t.Fatalf("claims: %v", err)
	}
	if claims.Iss != wantAppID {
		t.Errorf("iss = %q, want %q", claims.Iss, wantAppID)
	}
	if claims.Iat > now.Unix() {
		t.Errorf("iat %d is in the future (now %d)", claims.Iat, now.Unix())
	}
	if lifetime := claims.Exp - claims.Iat; lifetime <= 0 || lifetime > 600 {
		t.Errorf("JWT lifetime %ds is outside GitHub's (0, 600]", lifetime)
	}
}

// newTokenServer is a fake of POST /app/installations/{id}/access_tokens. It
// counts mints and hands out a distinguishable token each time.
func newTokenServer(t *testing.T, key *rsa.PrivateKey, appID string, clock *fakeClock, mintDelay time.Duration) (*httptest.Server, *int32) {
	t.Helper()
	var mints int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/app/installations/42/access_tokens" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		verifyAppJWT(t, key, r.Header.Get("Authorization"), appID, clock.Now())
		n := atomic.AddInt32(&mints, 1)
		time.Sleep(mintDelay)
		writeJSON(w, http.StatusCreated, map[string]any{
			"token":      fmt.Sprintf("ghs_minted_%d", n),
			"expires_at": clock.Now().Add(time.Hour).UTC().Format(time.RFC3339),
		})
	}))
	t.Cleanup(server.Close)
	return server, &mints
}

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func TestGitHubAppTokenSourceMintsCachesAndRefreshes(t *testing.T) {
	key := githubTestKey(t)
	clock := &fakeClock{now: time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)}
	server, mints := newTokenServer(t, key, "12345", clock, 0)

	source := newGitHubAppTokenSource(server.URL, "12345", "42", key)
	source.now = clock.Now

	first, err := source.Token(context.Background())
	if err != nil {
		t.Fatalf("first Token(): %v", err)
	}
	if first != "ghs_minted_1" {
		t.Fatalf("first token = %q", first)
	}
	// Well within the hour: served from the cache.
	clock.Advance(30 * time.Minute)
	if again, _ := source.Token(context.Background()); again != first {
		t.Fatalf("cached token = %q, want %q", again, first)
	}
	if got := atomic.LoadInt32(mints); got != 1 {
		t.Fatalf("mints after cached call = %d, want 1", got)
	}
	// Inside the five-minute margin before expiry: refreshed, even though
	// the old token is technically still valid for a few minutes.
	clock.Advance(26 * time.Minute)
	second, err := source.Token(context.Background())
	if err != nil {
		t.Fatalf("refresh Token(): %v", err)
	}
	if second != "ghs_minted_2" {
		t.Fatalf("refreshed token = %q, want ghs_minted_2", second)
	}
	if got := atomic.LoadInt32(mints); got != 2 {
		t.Fatalf("mints after refresh = %d, want 2", got)
	}
}

// Twenty callers arriving at once with an empty cache must produce one mint,
// not twenty; GitHub counts these against the App and each one is a round
// trip nobody needed.
func TestGitHubAppTokenSourceConcurrentCallersRefreshOnce(t *testing.T) {
	key := githubTestKey(t)
	clock := &fakeClock{now: time.Now()}
	server, mints := newTokenServer(t, key, "12345", clock, 50*time.Millisecond)

	source := newGitHubAppTokenSource(server.URL, "12345", "42", key)
	source.now = clock.Now

	var wg sync.WaitGroup
	tokens := make([]string, 20)
	for i := range tokens {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			token, err := source.Token(context.Background())
			if err != nil {
				t.Errorf("Token(): %v", err)
			}
			tokens[i] = token
		}(i)
	}
	wg.Wait()
	if got := atomic.LoadInt32(mints); got != 1 {
		t.Fatalf("mints = %d, want 1", got)
	}
	for i, token := range tokens {
		if token != "ghs_minted_1" {
			t.Fatalf("caller %d got %q", i, token)
		}
	}
}

// A refused mint is a classified error, is not cached, does not carry the
// App JWT (a credential in its own right) in its message, and is shared:
// callers waiting on the same refresh all get the one failure rather than
// each asking GitHub again.
func TestGitHubAppTokenSourceRefusedMintIsSharedByWaiters(t *testing.T) {
	key := githubTestKey(t)
	var mints int32
	var seenAuthorization atomic.Value
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&mints, 1)
		seenAuthorization.Store(r.Header.Get("Authorization"))
		time.Sleep(50 * time.Millisecond)
		w.Header().Set("X-GitHub-Request-Id", "ABCD:1234")
		writeJSON(w, http.StatusUnauthorized, map[string]string{"message": "A JSON web token could not be decoded"})
	}))
	defer server.Close()

	source := newGitHubAppTokenSource(server.URL, "12345", "42", key)
	var wg sync.WaitGroup
	errs := make([]error, 10)
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, errs[i] = source.Token(context.Background())
		}(i)
	}
	wg.Wait()
	if got := atomic.LoadInt32(&mints); got != 1 {
		t.Fatalf("mints = %d, want 1 shared failure", got)
	}
	jwt := strings.TrimPrefix(seenAuthorization.Load().(string), "Bearer ")
	for i, err := range errs {
		if githubErrorKindOf(err) != githubErrUnauthorized {
			t.Fatalf("caller %d: kind = %q, err = %v", i, githubErrorKindOf(err), err)
		}
		if !strings.Contains(err.Error(), "ABCD:1234") {
			t.Fatalf("error should carry the request id: %v", err)
		}
		if jwt == "" || strings.Contains(err.Error(), jwt) {
			t.Fatalf("error string leaks the app JWT: %v", err)
		}
	}
	if source.token != "" {
		t.Fatal("a refused mint must not leave a token in the cache")
	}
}

// A caller that gives up stops waiting; the refresh it was waiting on
// finishes for everyone else. And a caller that arrives already cancelled
// never starts a refresh at all.
func TestGitHubAppTokenSourceCancelledWaiter(t *testing.T) {
	key := githubTestKey(t)
	clock := &fakeClock{now: time.Now()}
	server, mints := newTokenServer(t, key, "12345", clock, 200*time.Millisecond)
	source := newGitHubAppTokenSource(server.URL, "12345", "42", key)
	source.now = clock.Now

	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := source.Token(cancelled)
	if githubErrorKindOf(err) != githubErrCancelled || !errors.Is(err, context.Canceled) {
		t.Fatalf("already-cancelled caller: err = %v", err)
	}
	if got := atomic.LoadInt32(mints); got != 0 {
		t.Fatalf("an already-cancelled caller started %d mints", got)
	}

	patient := make(chan error, 1)
	go func() {
		_, err := source.Token(context.Background())
		patient <- err
	}()
	impatient, cancelImpatient := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancelImpatient()
	started := time.Now()
	_, err = source.Token(impatient)
	if githubErrorKindOf(err) != githubErrTimeout || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("impatient caller: err = %v", err)
	}
	if waited := time.Since(started); waited > 150*time.Millisecond {
		t.Fatalf("impatient caller waited %s for a refresh it had abandoned", waited)
	}
	if err := <-patient; err != nil {
		t.Fatalf("patient caller: %v", err)
	}
	if got := atomic.LoadInt32(mints); got != 1 {
		t.Fatalf("mints = %d, want 1", got)
	}
}

// GitHub answering the token request with headers and then never finishing
// the body is a timeout, classified like any other transport failure.
func TestGitHubAppTokenSourceStalledBody(t *testing.T) {
	key := githubTestKey(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	source := newGitHubAppTokenSource(server.URL, "12345", "42", key)
	source.httpClient.Timeout = 50 * time.Millisecond

	_, err := source.Token(context.Background())
	if githubErrorKindOf(err) != githubErrTimeout {
		t.Fatalf("kind = %q, err = %v", githubErrorKindOf(err), err)
	}
}

// newFakeGitHub is one server that answers every method's happy path for the
// fixtures below, plus a few paths that return the interesting non-success
// answers. Each handler asserts the request shape.
func newFakeGitHub(t *testing.T, token string) (*httptest.Server, *int32) {
	t.Helper()
	var requests int32
	mux := http.NewServeMux()
	mux.HandleFunc("/users/octocat", func(w http.ResponseWriter, r *http.Request) {
		requireGitHubHeaders(t, r, token)
		writeJSON(w, http.StatusOK, map[string]any{"id": 583231, "login": "octocat"})
	})
	mux.HandleFunc("/users/nobody", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
	})
	mux.HandleFunc("/orgs/course/memberships/octocat", func(w http.ResponseWriter, r *http.Request) {
		requireGitHubHeaders(t, r, token)
		switch r.Method {
		case http.MethodGet:
			writeJSON(w, http.StatusOK, map[string]string{"state": "active", "role": "member"})
		case http.MethodPut:
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["role"] != "member" {
				t.Errorf("set org membership role = %q, want member", body["role"])
			}
			writeJSON(w, http.StatusOK, map[string]string{"state": "pending", "role": "member"})
		}
	})
	mux.HandleFunc("/orgs/course/memberships/nobody", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
	})
	mux.HandleFunc("/repos/course/hw1-starter/generate", func(w http.ResponseWriter, r *http.Request) {
		requireGitHubHeaders(t, r, token)
		if r.Method != http.MethodPost {
			t.Errorf("generate method = %s", r.Method)
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["owner"] != "course" || body["name"] != "hw1-octocat" || body["private"] != true {
			t.Errorf("generate body = %v", body)
		}
		writeJSON(w, http.StatusCreated, map[string]any{
			"id":             999,
			"full_name":      "course/hw1-octocat",
			"html_url":       "https://github.com/course/hw1-octocat",
			"default_branch": "main",
			"created_at":     "2026-09-19T12:00:00Z",
			"template_repository": map[string]any{
				"full_name": "course/hw1-starter",
			},
		})
	})
	mux.HandleFunc("/repos/course/hw1-octocat", func(w http.ResponseWriter, r *http.Request) {
		requireGitHubHeaders(t, r, token)
		writeJSON(w, http.StatusOK, map[string]any{
			"id":             999,
			"full_name":      "course/hw1-octocat",
			"html_url":       "https://github.com/course/hw1-octocat",
			"default_branch": "main",
			"created_at":     "2026-09-19T12:00:00Z",
		})
	})
	mux.HandleFunc("/repos/course/hw1-octocat/collaborators/octocat", func(w http.ResponseWriter, r *http.Request) {
		requireGitHubHeaders(t, r, token)
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if r.Method != http.MethodPut || body["permission"] != "push" {
			t.Errorf("collaborator request = %s %v", r.Method, body)
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/repos/course/hw1-octocat/collaborators/outsider", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusCreated, map[string]any{"id": 1, "invitee": map[string]string{"login": "outsider"}})
	})
	mux.HandleFunc("/repos/course/hw1-octocat/commits/HEAD", func(w http.ResponseWriter, r *http.Request) {
		requireGitHubHeaders(t, r, token)
		writeJSON(w, http.StatusOK, map[string]any{"sha": "0123abcd"})
	})
	mux.HandleFunc("/repos/course/hw1-empty/commits/HEAD", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusConflict, map[string]string{"message": "Git Repository is empty."})
	})
	mux.HandleFunc("/repos/course/hw1-missing/commits/HEAD", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
	})
	mux.HandleFunc("/orgs/course/teams/students/memberships/octocat", func(w http.ResponseWriter, r *http.Request) {
		requireGitHubHeaders(t, r, token)
		if r.Method != http.MethodPut {
			t.Errorf("team membership method = %s", r.Method)
		}
		writeJSON(w, http.StatusOK, map[string]string{"state": "active", "role": "member"})
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&requests, 1)
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(server.Close)
	return server, &requests
}

func TestGitHubClientMethods(t *testing.T) {
	const token = "ghp_static_test_token"
	server, _ := newFakeGitHub(t, token)
	client := newGitHubClient(server.URL, githubStaticTokenSource{token: token})
	ctx := context.Background()

	t.Run("GetUser", func(t *testing.T) {
		user, err := client.GetUser(ctx, "octocat")
		if err != nil {
			t.Fatal(err)
		}
		if user.ID != 583231 || user.Login != "octocat" {
			t.Fatalf("user = %+v", user)
		}
		if _, err := client.GetUser(ctx, "nobody"); githubErrorKindOf(err) != githubErrNotFound {
			t.Fatalf("missing user: kind = %q (%v)", githubErrorKindOf(err), err)
		}
	})

	t.Run("GetOrgMembership", func(t *testing.T) {
		state, err := client.GetOrgMembership(ctx, "course", "octocat")
		if err != nil || state != githubMembershipActive {
			t.Fatalf("member: state = %q, err = %v", state, err)
		}
		state, err = client.GetOrgMembership(ctx, "course", "nobody")
		if err != nil || state != githubMembershipNone {
			t.Fatalf("non-member: state = %q, err = %v", state, err)
		}
	})

	t.Run("GenerateFromTemplate", func(t *testing.T) {
		repo, err := client.GenerateFromTemplate(ctx, "course/hw1-starter", "course", "hw1-octocat", true)
		if err != nil {
			t.Fatal(err)
		}
		if repo.ID != 999 || repo.FullName != "course/hw1-octocat" || repo.HTMLURL != "https://github.com/course/hw1-octocat" {
			t.Fatalf("repo = %+v", repo)
		}
		if repo.TemplateFullName != "course/hw1-starter" || repo.CreatedAt.IsZero() {
			t.Fatalf("recovery fields missing: %+v", repo)
		}
		if _, err := client.GenerateFromTemplate(ctx, "not-a-full-name", "course", "x", true); githubErrorKindOf(err) != githubErrConflict {
			t.Fatalf("bad template name: %v", err)
		}
	})

	t.Run("AddCollaborator", func(t *testing.T) {
		result, err := client.AddCollaborator(ctx, "course", "hw1-octocat", "octocat", "push")
		if err != nil || result != githubCollaboratorGranted {
			t.Fatalf("204: result = %q, err = %v", result, err)
		}
		result, err = client.AddCollaborator(ctx, "course", "hw1-octocat", "outsider", "push")
		if err != nil || result != githubCollaboratorInvited {
			t.Fatalf("201: result = %q, err = %v", result, err)
		}
	})

	t.Run("GetRepo", func(t *testing.T) {
		repo, err := client.GetRepo(ctx, "course", "hw1-octocat")
		if err != nil || repo.ID != 999 || repo.DefaultBranch != "main" {
			t.Fatalf("repo = %+v, err = %v", repo, err)
		}
		if _, err := client.GetRepo(ctx, "course", "hw1-missing"); githubErrorKindOf(err) != githubErrNotFound {
			t.Fatalf("missing repo: %v", err)
		}
	})

	t.Run("GetDefaultBranchHead", func(t *testing.T) {
		sha, ready, err := client.GetDefaultBranchHead(ctx, "course", "hw1-octocat")
		if err != nil || !ready || sha != "0123abcd" {
			t.Fatalf("ready repo: sha = %q, ready = %v, err = %v", sha, ready, err)
		}
		// 409 is GitHub's "empty repository": the template is still being
		// copied in, so not ready and not an error.
		sha, ready, err = client.GetDefaultBranchHead(ctx, "course", "hw1-empty")
		if err != nil || ready || sha != "" {
			t.Fatalf("empty repo: sha = %q, ready = %v, err = %v", sha, ready, err)
		}
		// 404 is ambiguous (missing, or invisible to this credential) and
		// is handed to the caller as such rather than read as "copying".
		_, ready, err = client.GetDefaultBranchHead(ctx, "course", "hw1-missing")
		if ready || githubErrorKindOf(err) != githubErrNotFound {
			t.Fatalf("missing repo: ready = %v, err = %v", ready, err)
		}
	})

	t.Run("SetOrgMembership", func(t *testing.T) {
		state, err := client.SetOrgMembership(ctx, "course", "octocat")
		if err != nil || state != githubMembershipPending {
			t.Fatalf("state = %q, err = %v", state, err)
		}
	})

	t.Run("AddTeamMembership", func(t *testing.T) {
		state, err := client.AddTeamMembership(ctx, "course", "students", "octocat")
		if err != nil || state != githubMembershipActive {
			t.Fatalf("state = %q, err = %v", state, err)
		}
	})
}

func TestGitHubClientClassifiesRateLimits(t *testing.T) {
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name      string
		status    int
		headers   map[string]string
		body      map[string]string
		wantKind  githubErrorKind
		wantRetry time.Duration
	}{
		{
			name:      "429 with Retry-After",
			status:    http.StatusTooManyRequests,
			headers:   map[string]string{"Retry-After": "7"},
			wantKind:  githubErrRateLimited,
			wantRetry: 7 * time.Second,
		},
		{
			name:      "403 secondary limit with reset",
			status:    http.StatusForbidden,
			headers:   map[string]string{"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": strconv.FormatInt(now.Add(90*time.Second).Unix(), 10)},
			wantKind:  githubErrRateLimited,
			wantRetry: 90 * time.Second,
		},
		{
			name:      "403 with Retry-After only",
			status:    http.StatusForbidden,
			headers:   map[string]string{"Retry-After": "60"},
			wantKind:  githubErrRateLimited,
			wantRetry: 60 * time.Second,
		},
		{
			name:      "reset in the past still waits a moment",
			status:    http.StatusTooManyRequests,
			headers:   map[string]string{"X-RateLimit-Reset": strconv.FormatInt(now.Add(-time.Minute).Unix(), 10)},
			wantKind:  githubErrRateLimited,
			wantRetry: time.Second,
		},
		{
			name:      "403 secondary limit named in the body",
			status:    http.StatusForbidden,
			body:      map[string]string{"message": "You have exceeded a secondary rate limit. Please wait a few minutes before you try again.", "documentation_url": "https://docs.github.com/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits"},
			headers:   map[string]string{"X-RateLimit-Remaining": "4999"},
			wantKind:  githubErrRateLimited,
			wantRetry: time.Minute,
		},
		{
			name:     "plain 403 is unauthorized",
			status:   http.StatusForbidden,
			headers:  map[string]string{"X-RateLimit-Remaining": "4999"},
			wantKind: githubErrUnauthorized,
		},
		{
			// The accounting headers ride on every response; a reset
			// timestamp next to a healthy remaining count is not a limit.
			name:     "403 permission error with reset header is unauthorized",
			status:   http.StatusForbidden,
			headers:  map[string]string{"X-RateLimit-Remaining": "4321", "X-RateLimit-Reset": strconv.FormatInt(now.Add(30*time.Minute).Unix(), 10)},
			wantKind: githubErrUnauthorized,
		},
		{name: "401", status: http.StatusUnauthorized, wantKind: githubErrUnauthorized},
		{name: "422", status: http.StatusUnprocessableEntity, wantKind: githubErrConflict},
		{name: "409", status: http.StatusConflict, wantKind: githubErrConflict},
		{name: "502", status: http.StatusBadGateway, wantKind: githubErrServer},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				for k, v := range tc.headers {
					w.Header().Set(k, v)
				}
				w.Header().Set("X-GitHub-Request-Id", "REQ:1")
				body := tc.body
				if body == nil {
					body = map[string]string{"message": "whatever GitHub says"}
				}
				writeJSON(w, tc.status, body)
			}))
			defer server.Close()
			client := newGitHubClient(server.URL, githubStaticTokenSource{token: "t"})
			client.now = func() time.Time { return now }

			// A PUT, so the 5xx case is not retried and the count of what
			// the server saw is not part of this test.
			_, err := client.AddCollaborator(context.Background(), "o", "r", "u", "push")
			var ghErr *githubError
			if !errors.As(err, &ghErr) {
				t.Fatalf("err = %v, want *githubError", err)
			}
			if ghErr.Kind != tc.wantKind {
				t.Fatalf("kind = %q, want %q (%v)", ghErr.Kind, tc.wantKind, err)
			}
			if ghErr.RetryAfter != tc.wantRetry {
				t.Fatalf("RetryAfter = %s, want %s", ghErr.RetryAfter, tc.wantRetry)
			}
			if ghErr.Status != tc.status || ghErr.RequestID != "REQ:1" {
				t.Fatalf("status/request id = %d/%q", ghErr.Status, ghErr.RequestID)
			}
		})
	}
}

func TestGitHubClientClassifiesTimeouts(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(5 * time.Second):
		}
	}))
	defer server.Close()
	client := newGitHubClient(server.URL, githubStaticTokenSource{token: "t"})

	t.Run("caller deadline", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		defer cancel()
		_, err := client.GetUser(ctx, "octocat")
		if githubErrorKindOf(err) != githubErrTimeout {
			t.Fatalf("kind = %q (%v)", githubErrorKindOf(err), err)
		}
	})

	t.Run("client timeout", func(t *testing.T) {
		client.httpClient.Timeout = 50 * time.Millisecond
		defer func() { client.httpClient.Timeout = githubRequestTimeout }()
		_, err := client.GenerateFromTemplate(context.Background(), "o/t", "o", "n", true)
		if githubErrorKindOf(err) != githubErrTimeout {
			t.Fatalf("kind = %q (%v)", githubErrorKindOf(err), err)
		}
	})
}

// A GET is replayed once after a 5xx; a POST never is, because it may have
// already created the thing. The server here is deliberately hostile and
// echoes the bearer token back in its error message, which is the one way a
// credential could reach a log through this client; the Error() string must
// not carry it.
func TestGitHubClientRetriesOnlyGetsAndNeverLeaksTokens(t *testing.T) {
	const token = "ghs_do_not_log_me"
	var requests int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&requests, 1)
		if r.Method == http.MethodGet && n == 2 {
			writeJSON(w, http.StatusOK, map[string]any{"id": 1, "login": "octocat"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"message": "boom " + r.Header.Get("Authorization"),
		})
	}))
	defer server.Close()
	client := newGitHubClient(server.URL, githubStaticTokenSource{token: token})

	user, err := client.GetUser(context.Background(), "octocat")
	if err != nil || user.Login != "octocat" {
		t.Fatalf("GET after one 5xx: user = %+v, err = %v", user, err)
	}
	if got := atomic.LoadInt32(&requests); got != 2 {
		t.Fatalf("GET requests = %d, want 2 (one retry)", got)
	}

	atomic.StoreInt32(&requests, 0)
	_, err = client.GenerateFromTemplate(context.Background(), "o/t", "o", "n", true)
	if githubErrorKindOf(err) != githubErrServer {
		t.Fatalf("POST 5xx: kind = %q (%v)", githubErrorKindOf(err), err)
	}
	if got := atomic.LoadInt32(&requests); got != 1 {
		t.Fatalf("POST requests = %d, want 1 (no retry)", got)
	}
	marshalled, marshalErr := json.Marshal(err)
	if marshalErr != nil {
		t.Fatal(marshalErr)
	}
	for name, rendering := range map[string]string{
		"Error()": err.Error(),
		"%v":      fmt.Sprintf("%v", err),
		"%+v":     fmt.Sprintf("%+v", err),
		"json":    string(marshalled),
	} {
		if strings.Contains(rendering, token) || strings.Contains(rendering, "boom") {
			t.Fatalf("%s leaks the response body: %s", name, rendering)
		}
	}
	if !strings.Contains(err.Error(), "generate from template") || !strings.Contains(err.Error(), "500") {
		t.Fatalf("error should name the operation and status: %v", err)
	}
}

// A redirect is never followed: Go's default client would re-send the POST
// body to the new location, which is a replay. The server must see exactly
// one request and the caller an unexpected-status error.
func TestGitHubClientDoesNotFollowRedirects(t *testing.T) {
	var requests int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&requests, 1)
		w.Header().Set("Location", "/repos/o/t/generate")
		w.WriteHeader(http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	client := newGitHubClient(server.URL, githubStaticTokenSource{token: "t"})

	_, err := client.GenerateFromTemplate(context.Background(), "o/t", "o", "n", true)
	var ghErr *githubError
	if !errors.As(err, &ghErr) || ghErr.Kind != githubErrServer || ghErr.Status != http.StatusTemporaryRedirect {
		t.Fatalf("err = %v, want server_error with status 307", err)
	}
	if got := atomic.LoadInt32(&requests); got != 1 {
		t.Fatalf("requests = %d, want 1", got)
	}
}

// A caller's own context ending is reported as cancelled, and the cause is
// preserved so errors.Is still answers.
func TestGitHubClientPreservesContextErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()
	client := newGitHubClient(server.URL, githubStaticTokenSource{token: "t"})

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	_, err := client.GetUser(ctx, "octocat")
	if githubErrorKindOf(err) != githubErrCancelled || !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want cancelled wrapping context.Canceled", err)
	}

	ctx, cancel = context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err = client.GetUser(ctx, "octocat")
	if githubErrorKindOf(err) != githubErrTimeout || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want timeout wrapping context.DeadlineExceeded", err)
	}
}

func TestGitHubProvisionerFromEnv(t *testing.T) {
	key := githubTestKey(t)
	keyDir := t.TempDir()
	keyPath := filepath.Join(keyDir, "app.pem")
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	badKeyPath := filepath.Join(keyDir, "bad.pem")
	if err := os.WriteFile(badKeyPath, []byte("not a key"), 0o600); err != nil {
		t.Fatal(err)
	}
	appVars := map[string]string{
		"GITHUB_PROVISIONER_ORG":              "course",
		"GITHUB_PROVISIONER_APP_ID":           "12345",
		"GITHUB_PROVISIONER_INSTALLATION_ID":  "42",
		"GITHUB_PROVISIONER_PRIVATE_KEY_FILE": keyPath,
	}

	cases := []struct {
		name         string
		env          map[string]string
		wantEnabled  bool
		wantDisabled string // substring of the disabled reason
		wantErr      string // substring of the error
	}{
		{
			name:         "nothing set",
			env:          map[string]string{},
			wantDisabled: "GITHUB_PROVISIONER_ORG and a credential",
		},
		{
			name:         "org without credential",
			env:          map[string]string{"GITHUB_PROVISIONER_ORG": "course"},
			wantDisabled: "a credential",
		},
		{
			name:         "credential without org",
			env:          map[string]string{"GITHUB_PROVISIONER_TOKEN": "ghp_x"},
			wantDisabled: "GITHUB_PROVISIONER_ORG not set",
		},
		{
			name:        "static token",
			env:         map[string]string{"GITHUB_PROVISIONER_ORG": "course", "GITHUB_PROVISIONER_TOKEN": "ghp_x", "GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG": "students"},
			wantEnabled: true,
		},
		{
			name:        "github app",
			env:         appVars,
			wantEnabled: true,
		},
		{
			name:    "partial app config",
			env:     map[string]string{"GITHUB_PROVISIONER_ORG": "course", "GITHUB_PROVISIONER_APP_ID": "12345"},
			wantErr: "incomplete",
		},
		{
			name: "both credentials",
			env: func() map[string]string {
				m := map[string]string{"GITHUB_PROVISIONER_TOKEN": "ghp_x"}
				for k, v := range appVars {
					m[k] = v
				}
				return m
			}(),
			wantErr: "choose one",
		},
		{
			name: "unreadable key file",
			env: func() map[string]string {
				m := map[string]string{}
				for k, v := range appVars {
					m[k] = v
				}
				m["GITHUB_PROVISIONER_PRIVATE_KEY_FILE"] = filepath.Join(keyDir, "missing.pem")
				return m
			}(),
			wantErr: "reading GITHUB_PROVISIONER_PRIVATE_KEY_FILE",
		},
		{
			name: "unparseable key file",
			env: func() map[string]string {
				m := map[string]string{}
				for k, v := range appVars {
					m[k] = v
				}
				m["GITHUB_PROVISIONER_PRIVATE_KEY_FILE"] = badKeyPath
				return m
			}(),
			wantErr: "not a usable RSA private key",
		},
		{
			name:    "bad base url",
			env:     map[string]string{"GITHUB_PROVISIONER_ORG": "course", "GITHUB_PROVISIONER_TOKEN": "ghp_x", "GITHUB_PROVISIONER_API_BASE_URL": "api.github.com"},
			wantErr: "GITHUB_PROVISIONER_API_BASE_URL",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			getenv := func(name string) string { return tc.env[name] }
			provisioner, reason, err := githubProvisionerFromEnv(getenv, os.ReadFile)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want containing %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tc.wantEnabled {
				if provisioner == nil {
					t.Fatalf("provisioner is nil; reason = %q", reason)
				}
				if provisioner.org != "course" {
					t.Fatalf("org = %q", provisioner.org)
				}
				if provisioner.client.baseURL != githubDefaultBaseURL {
					t.Fatalf("baseURL = %q", provisioner.client.baseURL)
				}
				if provisioner.studentsTeamSlug != tc.env["GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG"] {
					t.Fatalf("studentsTeamSlug = %q", provisioner.studentsTeamSlug)
				}
				return
			}
			if provisioner != nil {
				t.Fatal("expected provisioning to be disabled")
			}
			if !strings.Contains(reason, tc.wantDisabled) {
				t.Fatalf("reason = %q, want containing %q", reason, tc.wantDisabled)
			}
		})
	}
}

// The App token source built from the environment must actually present a
// JWT signed with the configured key, which is the end-to-end check that the
// PEM parsing and the signing agree.
func TestGitHubProvisionerFromEnvAppSourceMints(t *testing.T) {
	key := githubTestKey(t)
	clock := &fakeClock{now: time.Now()}
	server, mints := newTokenServer(t, key, "12345", clock, 0)
	keyPath := filepath.Join(t.TempDir(), "app.pem")
	pkcs8, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}), 0o600); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{
		"GITHUB_PROVISIONER_ORG":              "course",
		"GITHUB_PROVISIONER_API_BASE_URL":     server.URL,
		"GITHUB_PROVISIONER_APP_ID":           "12345",
		"GITHUB_PROVISIONER_INSTALLATION_ID":  "42",
		"GITHUB_PROVISIONER_PRIVATE_KEY_FILE": keyPath,
	}
	provisioner, _, err := githubProvisionerFromEnv(func(name string) string { return env[name] }, os.ReadFile)
	if err != nil {
		t.Fatal(err)
	}
	token, err := provisioner.client.tokens.Token(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if token != "ghs_minted_1" || atomic.LoadInt32(mints) != 1 {
		t.Fatalf("token = %q, mints = %d", token, atomic.LoadInt32(mints))
	}
}
