package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexedwards/scs/v2"
	"github.com/alexedwards/scs/v2/memstore"
)

// The join routes against three fakes: the fake PostgREST from
// provision_test.go, a GitHub that serves the token exchange and the
// membership endpoints and records which credential each request carried,
// and a session store that keeps every byte it was ever asked to commit, so
// a test can prove the student's token was never in it.

const (
	joinTestStudentToken = "gho_student-token-must-never-persist"
	joinTestClientID     = "Iv1.joinapp"
	joinTestClientSecret = "join-app-secret-do-not-leak"
	joinTestCode         = "authorization-code-1"
)

// ---------------------------------------------------------------------------
// Fake GitHub for the join flow
// ---------------------------------------------------------------------------

// joinGitHubCall is one request the fake saw: enough to assert the order of
// operations and which credential each carried.
type joinGitHubCall struct {
	method string
	path   string
	bearer string
}

type fakeJoinGitHub struct {
	t      *testing.T
	server *httptest.Server

	mu    sync.Mutex
	calls []joinGitHubCall
	// account is who the student token belongs to.
	account githubUser
	// memberships is login → state in the organization; absent is none.
	memberships map[string]string
	// tokenStatus, when set, is the token endpoint's HTTP status instead
	// of 200; tokenError, when set, is the OAuth error in its JSON body.
	tokenStatus int
	tokenError  string
	// expectedChallenge is the code_challenge the test saw in the
	// authorization URL; the exchange's code_verifier must hash to it.
	expectedChallenge string
	// verifiers is every code_verifier the token endpoint received.
	verifiers []string
	// acceptStatus, when set, is answered by the accept instead of 200;
	// acceptLands says whether a 202 actually activated the membership.
	acceptStatus int
	acceptLands  bool
	// courseToken is the credential the organization endpoints accept.
	courseToken string
	// exchanges is what the token endpoint received, for the assertions on
	// the exchange itself.
	exchanges []url.Values
}

func newFakeJoinGitHub(t *testing.T) *fakeJoinGitHub {
	t.Helper()
	g := &fakeJoinGitHub{
		t:           t,
		account:     githubUser{ID: 103, Login: "carol-gh"},
		memberships: map[string]string{},
		courseToken: provisioningTestToken,
	}
	bearerOf := func(r *http.Request) string {
		return strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	}
	record := func(r *http.Request) {
		g.calls = append(g.calls, joinGitHubCall{method: r.Method, path: r.URL.Path, bearer: bearerOf(r)})
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /login/oauth/access_token", func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		defer g.mu.Unlock()
		record(r)
		if got := r.Header.Get("Accept"); got != "application/json" {
			g.t.Errorf("token exchange Accept = %q", got)
		}
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		g.exchanges = append(g.exchanges, form)
		g.verifiers = append(g.verifiers, form.Get("code_verifier"))
		if g.tokenError != "" {
			status := g.tokenStatus
			if status == 0 {
				status = http.StatusOK
			}
			writeJSON(w, status, map[string]string{"error": g.tokenError, "error_description": "The code passed is incorrect or expired."})
			return
		}
		if g.tokenStatus != 0 {
			w.WriteHeader(g.tokenStatus)
			return
		}
		if form.Get("client_id") != joinTestClientID || form.Get("client_secret") != joinTestClientSecret {
			writeJSON(w, http.StatusOK, map[string]string{"error": "incorrect_client_credentials"})
			return
		}
		if form.Get("code") != joinTestCode || pkceChallenge(form.Get("code_verifier")) != g.expectedChallenge {
			g.t.Errorf("exchange code %q / verifier for challenge %q do not match", form.Get("code"), g.expectedChallenge)
			writeJSON(w, http.StatusOK, map[string]string{"error": "bad_verification_code"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"access_token": joinTestStudentToken, "token_type": "bearer", "scope": ""})
	})
	student := func(name string, handler http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			g.mu.Lock()
			defer g.mu.Unlock()
			record(r)
			if bearerOf(r) != joinTestStudentToken {
				g.t.Errorf("%s: carried %q, want the student token", name, bearerOf(r))
				writeJSON(w, http.StatusUnauthorized, map[string]string{"message": "Bad credentials"})
				return
			}
			handler(w, r)
		}
	}
	course := func(name string, handler http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			g.mu.Lock()
			defer g.mu.Unlock()
			record(r)
			if bearerOf(r) != g.courseToken {
				if bearerOf(r) == joinTestStudentToken {
					g.t.Errorf("%s: carried the student token, want the course credential", name)
				}
				writeJSON(w, http.StatusUnauthorized, map[string]string{"message": "Bad credentials"})
				return
			}
			handler(w, r)
		}
	}
	mux.HandleFunc("GET /user", student("get user", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"id": g.account.ID, "login": g.account.Login})
	}))
	mux.HandleFunc("PATCH /user/memberships/orgs/{org}", student("accept", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["state"] != "active" {
			g.t.Errorf("accept body = %v", body)
		}
		if g.memberships[g.account.Login] != "pending" {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		switch g.acceptStatus {
		case 0:
			g.memberships[g.account.Login] = "active"
			writeJSON(w, http.StatusOK, map[string]string{"state": "active", "role": "member"})
		case http.StatusAccepted:
			// Queued: no body, and the membership changes only if the
			// test says the queue drained.
			if g.acceptLands {
				g.memberships[g.account.Login] = "active"
			}
			w.WriteHeader(http.StatusAccepted)
		default:
			writeJSON(w, g.acceptStatus, map[string]string{"message": "scripted"})
		}
	}))
	mux.HandleFunc("GET /orgs/{org}/memberships/{login}", course("get membership", func(w http.ResponseWriter, r *http.Request) {
		state, ok := g.memberships[r.PathValue("login")]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"state": state, "role": "member"})
	}))
	mux.HandleFunc("PUT /orgs/{org}/memberships/{login}", course("invite", func(w http.ResponseWriter, r *http.Request) {
		login := r.PathValue("login")
		if g.memberships[login] != "active" {
			g.memberships[login] = "pending"
		}
		writeJSON(w, http.StatusOK, map[string]string{"state": g.memberships[login], "role": "member"})
	}))
	mux.HandleFunc("PUT /orgs/{org}/teams/{team}/memberships/{login}", course("team add", func(w http.ResponseWriter, r *http.Request) {
		state := "pending"
		if g.memberships[r.PathValue("login")] == "active" {
			state = "active"
		}
		writeJSON(w, http.StatusOK, map[string]string{"state": state, "role": "member"})
	}))
	g.server = httptest.NewServer(mux)
	t.Cleanup(g.server.Close)
	return g
}

func (g *fakeJoinGitHub) recorded() []joinGitHubCall {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]joinGitHubCall(nil), g.calls...)
}

// paths lists the calls as "METHOD path", for comparing against the order
// a test expects.
func (g *fakeJoinGitHub) paths() []string {
	var out []string
	for _, call := range g.recorded() {
		out = append(out, call.method+" "+call.path)
	}
	return out
}

// ---------------------------------------------------------------------------
// A session store that remembers everything it was given
// ---------------------------------------------------------------------------

type recordingSessionStore struct {
	scs.Store
	mu      sync.Mutex
	written [][]byte
}

func (s *recordingSessionStore) Commit(token string, b []byte, expiry time.Time) error {
	s.mu.Lock()
	s.written = append(s.written, append([]byte(nil), b...))
	s.mu.Unlock()
	return s.Store.Commit(token, b, expiry)
}

func (s *recordingSessionStore) everHeld(needle string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range s.written {
		if bytes.Contains(b, []byte(needle)) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// The stack
// ---------------------------------------------------------------------------

type joinStack struct {
	t        *testing.T
	clock    *fakeClock
	db       *fakePostgREST
	github   *fakeJoinGitHub
	store    *recordingSessionStore
	sessions *scs.SessionManager
	handler  *githubJoinHandler
	server   *httptest.Server
	logs     *bytes.Buffer

	clientsMu sync.Mutex
	clients   map[string]*http.Client
}

// newJoinStack mounts the join routes and the provisioning routes over the
// same provisioner, with join configured. carol (user 3) is the student who
// joins: enrolled, no GitHub account linked, not in the organization.
func newJoinStack(t *testing.T) *joinStack {
	t.Helper()
	clock := &fakeClock{now: time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)}
	db := newFakePostgREST(t, clock)
	db.assignments["hw1"] = fakeAssignment{template: "course/hw1-starter"}
	db.users[1] = &provisioningUser{ID: 1, NetID: "alice", Role: "student", TeamNickname: "alpha", GitHubLogin: "alice", GitHubUserID: 101}
	db.users[3] = &provisioningUser{ID: 3, NetID: "carol", Role: "student"}

	github := newFakeJoinGitHub(t)
	store := &recordingSessionStore{Store: memstore.New()}
	sessions := newSessionManager(true, store)
	provisioner := &githubProvisioner{
		client:           newGitHubClient(github.server.URL, githubStaticTokenSource{token: provisioningTestToken}),
		org:              "course",
		studentsTeamSlug: "students",
		join: &githubJoinApp{
			clientID:     joinTestClientID,
			clientSecret: joinTestClientSecret,
			authorizeURL: "https://github.example/login/oauth/authorize",
			tokenURL:     github.server.URL + "/login/oauth/access_token",
			apiBaseURL:   github.server.URL,
		},
	}
	handler := newGitHubJoinHandler(provisioner, db.config, sessions)
	handler.now = clock.Now

	mux := http.NewServeMux()
	mux.HandleFunc("GET "+githubJoinLandingPath, handler.serveLanding)
	mux.HandleFunc("GET "+githubJoinScriptPath, handler.serveScript)
	mux.HandleFunc("POST "+githubJoinStartPath, handler.serveStart)
	mux.HandleFunc("GET "+githubJoinCallbackPath, handler.serveCallback)
	mux.HandleFunc("/test/seed", func(w http.ResponseWriter, r *http.Request) {
		sessions.Put(r.Context(), "netid", r.URL.Query().Get("netid"))
		w.WriteHeader(http.StatusNoContent)
	})
	server := httptest.NewServer(sessions.LoadAndSave(mux))
	t.Cleanup(server.Close)

	logs := &bytes.Buffer{}
	previous := log.Writer()
	log.SetOutput(logs)
	t.Cleanup(func() { log.SetOutput(previous) })

	return &joinStack{t: t, clock: clock, db: db, github: github, store: store, sessions: sessions, handler: handler, server: server, logs: logs, clients: map[string]*http.Client{}}
}

func (s *joinStack) clientFor(netID string) *http.Client {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	if client, ok := s.clients[netID]; ok {
		return client
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		s.t.Fatalf("cookiejar: %v", err)
	}
	client := &http.Client{
		Jar: jar,
		// Redirects are the callback's answer; they are inspected, not followed.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	if netID != "" {
		response, err := client.Get(s.server.URL + "/test/seed?netid=" + url.QueryEscape(netID))
		if err != nil {
			s.t.Fatalf("seeding the session: %v", err)
		}
		response.Body.Close()
	}
	s.clients[netID] = client
	return client
}

type joinResponse struct {
	status   int
	location string
	body     string
}

// do sends one request and checks that neither the student token nor the
// client secret is in the reply.
func (s *joinStack) do(req *http.Request, netID string) joinResponse {
	s.t.Helper()
	response, err := s.clientFor(netID).Do(req)
	if err != nil {
		s.t.Fatalf("%s %s: %v", req.Method, req.URL.Path, err)
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(response.Body)
	body := string(raw)
	for _, secret := range s.secrets() {
		if strings.Contains(body, secret) || strings.Contains(response.Header.Get("Location"), secret) {
			s.t.Fatalf("%s %s: reply carries a secret: %s", req.Method, req.URL.Path, body)
		}
	}
	if got := response.Header.Get("Cache-Control"); got != "no-store" && response.StatusCode != http.StatusNotFound && response.StatusCode != http.StatusMethodNotAllowed {
		s.t.Errorf("%s %s: Cache-Control = %q, want no-store", req.Method, req.URL.Path, got)
	}
	return joinResponse{status: response.StatusCode, location: response.Header.Get("Location"), body: body}
}

// secrets is everything that must never appear in a reply or a log line:
// the student token, the client secret, the authorization code, and every
// PKCE verifier the token endpoint has received so far.
func (s *joinStack) secrets() []string {
	s.github.mu.Lock()
	defer s.github.mu.Unlock()
	out := []string{joinTestStudentToken, joinTestClientSecret, joinTestCode}
	for _, verifier := range s.github.verifiers {
		if verifier != "" {
			out = append(out, verifier)
		}
	}
	return out
}

// start posts to the start route as the netid and returns the parsed
// authorization URL.
func (s *joinStack) start(netID string, slug string) (joinResponse, *url.URL) {
	s.t.Helper()
	req, _ := http.NewRequest(http.MethodPost, s.server.URL+githubJoinStartPath, strings.NewReader(`{"assignment_slug":"`+slug+`"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	reply := s.do(req, netID)
	if reply.status != http.StatusOK {
		return reply, nil
	}
	var decoded struct {
		AuthorizationURL string `json:"authorization_url"`
	}
	if err := json.Unmarshal([]byte(reply.body), &decoded); err != nil {
		s.t.Fatalf("start body is not JSON: %s", reply.body)
	}
	parsed, err := url.Parse(decoded.AuthorizationURL)
	if err != nil {
		s.t.Fatalf("authorization_url %q: %v", decoded.AuthorizationURL, err)
	}
	return reply, parsed
}

// callback simulates GitHub sending the browser back with the given query.
func (s *joinStack) callback(netID string, query url.Values) joinResponse {
	s.t.Helper()
	req, _ := http.NewRequest(http.MethodGet, s.server.URL+githubJoinCallbackPath+"?"+query.Encode(), nil)
	return s.do(req, netID)
}

// startAndCallback runs the round trip for the netid with the state GitHub
// would echo back, plus the given extra query.
func (s *joinStack) startAndCallback(netID string, slug string, extra url.Values) joinResponse {
	s.t.Helper()
	reply, authorization := s.start(netID, slug)
	if authorization == nil {
		s.t.Fatalf("start = %d %s", reply.status, reply.body)
	}
	s.github.mu.Lock()
	s.github.expectedChallenge = authorization.Query().Get("code_challenge")
	s.github.mu.Unlock()
	query := url.Values{"state": {authorization.Query().Get("state")}}
	if extra == nil {
		query.Set("code", joinTestCode)
	}
	for k, v := range extra {
		query[k] = v
	}
	return s.callback(netID, query)
}

func (r joinResponse) expectRedirect(t *testing.T, slug string, marker string) {
	t.Helper()
	want := "/#/assignments/" + slug + "?github_join=" + url.QueryEscape(marker)
	if r.status != http.StatusSeeOther || r.location != want {
		t.Fatalf("got %d Location %q (%s), want 303 to %q", r.status, r.location, strings.TrimSpace(r.body), want)
	}
}

func (r joinResponse) expectStatus(t *testing.T, status int) {
	t.Helper()
	if r.status != status {
		t.Fatalf("got %d (%s), want %d", r.status, strings.TrimSpace(r.body), status)
	}
	if r.location != "" {
		t.Fatalf("got a redirect to %q, want none", r.location)
	}
}

// assertNothingLeaked is the invariant every test ends with: the student's
// token is not in the session store, not in a log line, and not in any
// reply (do checks replies as they arrive).
func (s *joinStack) assertNothingLeaked() {
	s.t.Helper()
	if s.store.everHeld(joinTestStudentToken) {
		s.t.Fatalf("the student token was written to the session store")
	}
	if s.store.everHeld(joinTestClientSecret) {
		s.t.Fatalf("the client secret was written to the session store")
	}
	for _, secret := range s.secrets() {
		if strings.Contains(s.logs.String(), secret) {
			s.t.Fatalf("a log line carries %q:\n%s", secret, s.logs.String())
		}
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestJoinStartBuildsTheAuthorizationRequest(t *testing.T) {
	s := newJoinStack(t)
	_, authorization := s.start("carol", "hw1")
	if authorization == nil {
		t.Fatal("start failed")
	}
	if got := authorization.Scheme + "://" + authorization.Host + authorization.Path; got != "https://github.example/login/oauth/authorize" {
		t.Fatalf("authorization URL = %q", got)
	}
	query := authorization.Query()
	if got := query.Get("client_id"); got != joinTestClientID {
		t.Fatalf("client_id = %q", got)
	}
	if got := query.Get("redirect_uri"); got != s.server.URL+githubJoinCallbackPath {
		t.Fatalf("redirect_uri = %q, want %q", got, s.server.URL+githubJoinCallbackPath)
	}
	if _, present := query["scope"]; present {
		t.Fatalf("a GitHub App authorization must not request scopes: %s", authorization)
	}
	state := query.Get("state")
	if len(state) < 40 || strings.ContainsAny(state, "+/=") {
		t.Fatalf("state = %q, want 32 random bytes as base64url", state)
	}
	if got := query.Get("code_challenge_method"); got != "S256" {
		t.Fatalf("code_challenge_method = %q", got)
	}
	if challenge := query.Get("code_challenge"); len(challenge) != 43 || strings.ContainsAny(challenge, "+/=") {
		t.Fatalf("code_challenge = %q, want a base64url SHA-256", challenge)
	}
	// Two starts never share a state or a challenge.
	_, again := s.start("carol", "hw1")
	if again.Query().Get("state") == state || again.Query().Get("code_challenge") == query.Get("code_challenge") {
		t.Fatal("state or code_challenge repeated across starts")
	}
	if strings.Contains(authorization.String(), joinTestClientSecret) {
		t.Fatal("the client secret is in the authorization URL")
	}
	// The redirect_uri honours the scheme and host the proxy forwarded.
	req, _ := http.NewRequest(http.MethodPost, s.server.URL+githubJoinStartPath, strings.NewReader(`{"assignment_slug":"hw1"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	req.Header.Set("X-Forwarded-Proto", "https")
	req.Header.Set("X-Forwarded-Host", "course.example")
	reply := s.do(req, "carol")
	if !strings.Contains(reply.body, url.QueryEscape("https://course.example"+githubJoinCallbackPath)) {
		t.Fatalf("forwarded redirect_uri missing from %s", reply.body)
	}
	s.assertNothingLeaked()
}

func TestJoinStartRefusals(t *testing.T) {
	s := newJoinStack(t)
	post := func(netID string, body string, headers map[string]string) joinResponse {
		req, _ := http.NewRequest(http.MethodPost, s.server.URL+githubJoinStartPath, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Sec-Fetch-Site", "same-origin")
		for k, v := range headers {
			if v == "" {
				req.Header.Del(k)
			} else {
				req.Header.Set(k, v)
			}
		}
		return s.do(req, netID)
	}
	post("", `{"assignment_slug":"hw1"}`, nil).expectStatus(t, http.StatusUnauthorized)
	post("carol", `{"assignment_slug":"hw1"}`, map[string]string{"Sec-Fetch-Site": "cross-site"}).expectStatus(t, http.StatusForbidden)
	post("carol", `{"assignment_slug":"hw1"}`, map[string]string{"Sec-Fetch-Site": ""}).expectStatus(t, http.StatusForbidden)
	post("carol", `{"assignment_slug":"../etc"}`, nil).expectStatus(t, http.StatusBadRequest)
	post("carol", `{"assignment_slug":"HW1"}`, nil).expectStatus(t, http.StatusBadRequest)
	post("carol", `not json`, nil).expectStatus(t, http.StatusBadRequest)
	post("stranger", `{"assignment_slug":"hw1"}`, nil).expectStatus(t, http.StatusForbidden)
	// Refused starts leave no state behind for a callback to find.
	s.callback("carol", url.Values{"state": {"anything"}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)
	if got := len(s.github.recorded()); got != 0 {
		t.Fatalf("GitHub was called %d times", got)
	}
	// Other methods on start are refused by the mux.
	req, _ := http.NewRequest(http.MethodGet, s.server.URL+githubJoinStartPath, nil)
	s.do(req, "carol").expectStatus(t, http.StatusMethodNotAllowed)
}

func TestJoinStartIsRateLimitedPerStudent(t *testing.T) {
	s := newJoinStack(t)
	for i := 0; i < githubJoinStartsPerMinute; i++ {
		if reply, _ := s.start("carol", "hw1"); reply.status != http.StatusOK {
			t.Fatalf("start %d = %d", i, reply.status)
		}
	}
	reply, _ := s.start("carol", "hw1")
	reply.expectStatus(t, http.StatusTooManyRequests)
	if reply, _ := s.start("alice", "hw1"); reply.status != http.StatusOK {
		t.Fatalf("another student is limited too: %d", reply.status)
	}
}

func TestJoinNewMemberIsInvitedAcceptsAndIsAddedToTheTeam(t *testing.T) {
	s := newJoinStack(t)
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "ok")

	want := []string{
		"POST /login/oauth/access_token",
		"GET /user",
		"GET /orgs/course/memberships/carol-gh",
		"PUT /orgs/course/memberships/carol-gh",
		"PATCH /user/memberships/orgs/course",
		"PUT /orgs/course/teams/students/memberships/carol-gh",
	}
	if got := s.github.paths(); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("GitHub calls:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// Credential per call: the course credential invites and adds to the
	// team; the student's token identifies and accepts. (The fake also
	// refuses the wrong one, so this is belt and braces.)
	for _, call := range s.github.recorded() {
		switch call.path {
		case "/user", "/user/memberships/orgs/course":
			if call.bearer != joinTestStudentToken {
				t.Fatalf("%s %s carried %q, want the student token", call.method, call.path, call.bearer)
			}
		case "/login/oauth/access_token":
			if call.bearer != "" {
				t.Fatalf("token exchange carried a bearer %q", call.bearer)
			}
		default:
			if call.bearer != provisioningTestToken {
				t.Fatalf("%s %s carried %q, want the course credential", call.method, call.path, call.bearer)
			}
		}
	}
	// The exchange repeated the redirect_uri the authorization named and
	// presented the verifier behind its code_challenge (the fake refuses
	// any other; this is the explicit form of that).
	exchange := s.github.exchanges[0]
	if exchange.Get("redirect_uri") != s.server.URL+githubJoinCallbackPath {
		t.Fatalf("exchange redirect_uri = %q", exchange.Get("redirect_uri"))
	}
	if verifier := exchange.Get("code_verifier"); len(verifier) < 43 || pkceChallenge(verifier) != s.github.expectedChallenge {
		t.Fatalf("code_verifier %q does not hash to the code_challenge %q", verifier, s.github.expectedChallenge)
	}
	if s.github.memberships["carol-gh"] != "active" {
		t.Fatalf("membership = %q, want active", s.github.memberships["carol-gh"])
	}
	// The verified identity persists; the token does not.
	if carol := s.db.users[3]; carol.GitHubUserID != 103 || carol.GitHubLogin != "carol-gh" || !s.db.verified[3] {
		t.Fatalf("carol = %+v verified=%v", carol, s.db.verified[3])
	}
	// The store did see the pending state, so its silence about the token
	// means something.
	if !s.store.everHeld(sessionKeyGitHubJoin) {
		t.Fatal("the recording store never saw the pending join")
	}
	s.assertNothingLeaked()
}

func TestJoinExistingMemberOnlyGetsTheTeamAdd(t *testing.T) {
	s := newJoinStack(t)
	s.github.memberships["carol-gh"] = "active"
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "ok")
	want := []string{
		"POST /login/oauth/access_token",
		"GET /user",
		"GET /orgs/course/memberships/carol-gh",
		"PUT /orgs/course/teams/students/memberships/carol-gh",
	}
	if got := s.github.paths(); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("GitHub calls:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	s.assertNothingLeaked()
}

// A student who was invited earlier (by hand, or by a run that failed after
// the invitation) is not invited again: the pending membership is accepted.
func TestJoinPendingInvitationIsAcceptedWithoutReinviting(t *testing.T) {
	s := newJoinStack(t)
	s.github.memberships["carol-gh"] = "pending"
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "ok")
	for _, call := range s.github.paths() {
		if call == "PUT /orgs/course/memberships/carol-gh" {
			t.Fatalf("re-invited a pending member: %v", s.github.paths())
		}
	}
	if !strings.Contains(strings.Join(s.github.paths(), "\n"), "PATCH /user/memberships/orgs/course") {
		t.Fatalf("did not accept: %v", s.github.paths())
	}
}

// GitHub may answer the accept with 202 and no body. The membership is
// then re-read with the course credential: active means done; still
// pending is reported so the student clicks again rather than being told
// they are in.
func TestJoinQueuedAcceptIsConfirmedByRereading(t *testing.T) {
	s := newJoinStack(t)
	s.github.acceptStatus = http.StatusAccepted
	s.github.acceptLands = true
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "ok")
	want := []string{
		"POST /login/oauth/access_token",
		"GET /user",
		"GET /orgs/course/memberships/carol-gh",
		"PUT /orgs/course/memberships/carol-gh",
		"PATCH /user/memberships/orgs/course",
		"GET /orgs/course/memberships/carol-gh",
		"PUT /orgs/course/teams/students/memberships/carol-gh",
	}
	if got := s.github.paths(); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("GitHub calls:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	s = newJoinStack(t)
	s.github.acceptStatus = http.StatusAccepted
	s.github.acceptLands = false
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:membership_not_active")
	for _, call := range s.github.paths() {
		if strings.Contains(call, "/teams/") {
			t.Fatalf("added to the team while still pending: %v", s.github.paths())
		}
	}
	if carol := s.db.users[3]; carol.GitHubUserID != 103 || !s.db.verified[3] {
		t.Fatalf("identity not kept: %+v", carol)
	}
	s.assertNothingLeaked()
}

func TestJoinWithoutAStudentsTeam(t *testing.T) {
	s := newJoinStack(t)
	s.handler.course.studentsTeamSlug = ""
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "ok")
	for _, call := range s.github.paths() {
		if strings.Contains(call, "/teams/") {
			t.Fatalf("team add without a team configured: %v", s.github.paths())
		}
	}
}

func TestJoinCallbackRefusesWhatThisSessionDidNotStart(t *testing.T) {
	s := newJoinStack(t)

	// Nothing started.
	s.callback("carol", url.Values{"state": {"x"}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)

	// Mismatched state: refused, and the pending join is left for the
	// real callback, so a stray hit cannot cancel an authorization in
	// progress.
	_, authorization := s.start("carol", "hw1")
	state := authorization.Query().Get("state")
	s.github.expectedChallenge = authorization.Query().Get("code_challenge")
	s.callback("carol", url.Values{"state": {"not-the-state"}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)
	s.callback("carol", url.Values{"state": {""}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)
	s.callback("carol", url.Values{"state": {state}, "code": {joinTestCode}}).expectRedirect(t, "hw1", "ok")
	s.github.memberships = map[string]string{}
	_, authorization = s.start("carol", "hw1")
	state = authorization.Query().Get("state")

	// Another session's state, with a valid session of its own.
	s.callback("alice", url.Values{"state": {state}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)
	// No session at all.
	s.callback("", url.Values{"state": {state}, "code": {joinTestCode}}).expectStatus(t, http.StatusUnauthorized)

	// Expired.
	s.clock.Advance(githubJoinStateLifetime + time.Second)
	s.callback("carol", url.Values{"state": {state}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)

	// Replay: a state that was used once, whatever the outcome.
	_, authorization = s.start("carol", "hw1")
	state = authorization.Query().Get("state")
	s.github.expectedChallenge = authorization.Query().Get("code_challenge")
	s.callback("carol", url.Values{"state": {state}, "code": {joinTestCode}}).expectRedirect(t, "hw1", "ok")
	s.callback("carol", url.Values{"state": {state}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)

	// Exactly the two matching callbacks reached GitHub.
	if got := len(s.github.exchanges); got != 2 {
		t.Fatalf("token exchanges = %d, want 2", got)
	}
	s.assertNothingLeaked()
}

func TestJoinDenialRedirectsWithoutCallingGitHub(t *testing.T) {
	s := newJoinStack(t)
	s.startAndCallback("carol", "hw1", url.Values{"error": {"access_denied"}, "error_description": {"The user has denied your application access."}}).
		expectRedirect(t, "hw1", "denied")
	s.startAndCallback("carol", "hw1", url.Values{"error": {"application_suspended"}}).
		expectRedirect(t, "hw1", "error:authorization_failed")
	// A callback with neither a code nor an error.
	s.startAndCallback("carol", "hw1", url.Values{}).expectRedirect(t, "hw1", "error:authorization_failed")
	if got := len(s.github.recorded()); got != 0 {
		t.Fatalf("GitHub was called %d times", got)
	}
	if s.db.users[3].GitHubUserID != 0 {
		t.Fatal("an identity was linked on a denial")
	}
	// A denial is a used state too.
	s.callback("carol", url.Values{"state": {"stale"}, "code": {joinTestCode}}).expectStatus(t, http.StatusBadRequest)
}

func TestJoinIdentityTakenStopsBeforeMembership(t *testing.T) {
	s := newJoinStack(t)
	// alice already holds account 103.
	s.db.users[1].GitHubUserID = 103
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:github_identity_taken")
	want := []string{"POST /login/oauth/access_token", "GET /user"}
	if got := s.github.paths(); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("GitHub calls: %v, want %v", got, want)
	}
	if s.db.users[3].GitHubUserID != 0 {
		t.Fatal("carol was linked to alice's account")
	}
	s.assertNothingLeaked()
}

func TestJoinIdentityLockedAfterProvisioning(t *testing.T) {
	s := newJoinStack(t)
	// carol has a repository under account 999; the App says she is 103.
	s.db.users[3].GitHubUserID = 999
	s.db.users[3].GitHubLogin = "old-carol"
	s.db.seedRepository(fakeRepositoryRow{AssignmentSlug: "hw1", UserID: 3, Provider: "github", ProviderRepoID: 5, ProviderFullName: "course/hw1-old-carol"})
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:github_identity_locked")
	if got := len(s.github.paths()); got != 2 {
		t.Fatalf("GitHub calls after a locked identity: %v", s.github.paths())
	}
	if s.db.users[3].GitHubUserID != 999 {
		t.Fatal("the locked identity was changed")
	}

	// The same account again is not a change: the login is refreshed and
	// the identity becomes verified.
	s.github.account = githubUser{ID: 999, Login: "renamed-carol"}
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "ok")
	if carol := s.db.users[3]; carol.GitHubUserID != 999 || carol.GitHubLogin != "renamed-carol" || !s.db.verified[3] {
		t.Fatalf("carol = %+v verified=%v", carol, s.db.verified[3])
	}
}

func TestJoinTokenExchangeFailures(t *testing.T) {
	s := newJoinStack(t)
	s.github.tokenStatus = http.StatusBadGateway
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:github_unavailable")

	s.github.tokenStatus = 0
	s.github.tokenError = "bad_verification_code"
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:authorization_failed")

	// The OAuth error is read whatever the status carries it.
	s.github.tokenStatus = http.StatusBadRequest
	s.github.tokenError = "bad_verification_code"
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:authorization_failed")

	s.github.tokenStatus = 0
	s.github.tokenError = ""
	s.handler.app.clientSecret = "rotated-away"
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:join_app_misconfigured")
	if !strings.Contains(s.logs.String(), "ERROR GitHub refused the join App's client id or secret") {
		t.Fatalf("operator error not logged:\n%s", s.logs.String())
	}
	s.handler.app.clientSecret = joinTestClientSecret

	s.github.tokenStatus = http.StatusTooManyRequests
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:github_rate_limited")
	s.github.tokenStatus = 0

	// Nothing past the exchange was attempted, and nothing was linked.
	for _, call := range s.github.paths() {
		if call != "POST /login/oauth/access_token" {
			t.Fatalf("called %s after a failed exchange", call)
		}
	}
	if s.db.users[3].GitHubUserID != 0 {
		t.Fatal("an identity was linked without a token")
	}
	s.assertNothingLeaked()
}

// The identity is linked before the membership steps, so a membership
// failure leaves a verified identity behind and the retry does not
// re-invite.
func TestJoinMembershipFailureKeepsTheIdentityAndIsRetryable(t *testing.T) {
	s := newJoinStack(t)
	s.github.acceptStatus = http.StatusBadGateway
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:github_unavailable")
	if carol := s.db.users[3]; carol.GitHubUserID != 103 || !s.db.verified[3] {
		t.Fatalf("identity not kept: %+v", carol)
	}
	if s.github.memberships["carol-gh"] != "pending" {
		t.Fatalf("membership = %q after the failed accept", s.github.memberships["carol-gh"])
	}

	s.github.acceptStatus = 0
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "ok")
	invites := 0
	for _, call := range s.github.paths() {
		if call == "PUT /orgs/course/memberships/carol-gh" {
			invites++
		}
	}
	if invites != 1 {
		t.Fatalf("invited %d times across the two runs, want 1", invites)
	}
	s.assertNothingLeaked()
}

func TestJoinCourseCredentialRejected(t *testing.T) {
	s := newJoinStack(t)
	// The installation was removed, or the App lost the members permission.
	s.github.courseToken = "rotated-away"
	s.startAndCallback("carol", "hw1", nil).expectRedirect(t, "hw1", "error:github_credential_rejected")
	if !strings.Contains(s.logs.String(), "ERROR GitHub refused the course credential") {
		t.Fatalf("operator error not logged:\n%s", s.logs.String())
	}
}

func TestJoinLandingPage(t *testing.T) {
	s := newJoinStack(t)
	get := func(netID string, path string) joinResponse {
		req, _ := http.NewRequest(http.MethodGet, s.server.URL+path, nil)
		return s.do(req, netID)
	}
	reply := get("carol", githubJoinURL("hw1"))
	if reply.status != http.StatusOK {
		t.Fatalf("landing = %d %s", reply.status, reply.body)
	}
	for _, want := range []string{`action="` + githubJoinStartPath + `"`, `value="hw1"`, `<script src="` + githubJoinScriptPath + `">`, "<noscript>"} {
		if !strings.Contains(reply.body, want) {
			t.Fatalf("landing page lacks %q:\n%s", want, reply.body)
		}
	}
	// The slug is escaped on the page and refused when malformed.
	get("carol", githubJoinLandingPath+"?assignment_slug=%3Cscript%3E").expectStatus(t, http.StatusBadRequest)
	get("carol", githubJoinLandingPath).expectStatus(t, http.StatusBadRequest)

	// A visitor without a session is sent through login and back here.
	reply = get("", githubJoinURL("hw1"))
	if reply.status != http.StatusFound || reply.location != githubJoinLoginPath+"?next="+url.QueryEscape(githubJoinURL("hw1")) {
		t.Fatalf("signed-out landing = %d %q", reply.status, reply.location)
	}

	script := get("carol", githubJoinScriptPath)
	if script.status != http.StatusOK || !strings.Contains(script.body, "fetch(form.action") || !strings.Contains(script.body, "authorization_url") {
		t.Fatalf("script = %d %s", script.status, script.body)
	}
}

// The provisioning POST names the landing page when the caller's own
// membership is the blocker and the join App is configured; a teammate's
// blocker stays a conflict, and without the join App the field stays null.
func TestJoinURLInProvisioningReplies(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.memberships["alice"] = "pending"
	if reply := s.post("alice", "hw1"); reply.hasJoinURL {
		t.Fatalf("join_url set without the join App: %s", reply.body)
	}

	s.handler.github.join = &githubJoinApp{clientID: "x", clientSecret: "y"}
	reply := s.post("alice", "hw1")
	if reply.status != http.StatusOK || reply.state != repositoryStateNeedsOrgJoin {
		t.Fatalf("got %d %q", reply.status, reply.state)
	}
	var decoded struct {
		JoinURL string `json:"join_url"`
	}
	_ = json.Unmarshal([]byte(reply.body), &decoded)
	if decoded.JoinURL != "/auth/github/join?assignment_slug=hw1" {
		t.Fatalf("join_url = %q", decoded.JoinURL)
	}
	// bob's membership blocks the team, and alice is not offered bob's join.
	s.github.memberships["alice"] = "active"
	s.github.memberships["bob"] = "pending"
	s.post("alice", "proj").expectError(t, http.StatusConflict, "team_prerequisites_incomplete", true)
}

func TestJoinRoutesAbsentWhenDisabled(t *testing.T) {
	sessions := newSessionManager(true, memstore.New())
	for _, provisioner := range []*githubProvisioner{nil, {org: "course"}} {
		mux := http.NewServeMux()
		registerGitHubJoinRoutes(mux, provisioner, FetchJWTConfig{}, sessions)
		for _, path := range []string{githubJoinLandingPath, githubJoinStartPath, githubJoinCallbackPath, githubJoinScriptPath} {
			recorder := httptest.NewRecorder()
			mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
			if recorder.Code != http.StatusNotFound {
				t.Fatalf("%s with join disabled = %d, want 404", path, recorder.Code)
			}
		}
	}
}

func TestGitHubJoinAppFromEnv(t *testing.T) {
	provisioner := &githubProvisioner{client: newGitHubClient("https://ghe.example/api/v3", githubStaticTokenSource{token: "t"}), org: "course"}
	env := func(values map[string]string) func(string) string {
		return func(name string) string { return values[name] }
	}
	both := map[string]string{"GITHUB_JOIN_APP_CLIENT_ID": " id ", "GITHUB_JOIN_APP_CLIENT_SECRET": "secret"}
	withURLs := func(authorize, token, api string) map[string]string {
		return map[string]string{
			"GITHUB_JOIN_APP_CLIENT_ID":     "id",
			"GITHUB_JOIN_APP_CLIENT_SECRET": "secret",
			"GITHUB_JOIN_APP_AUTHORIZE_URL": authorize,
			"GITHUB_JOIN_APP_TOKEN_URL":     token,
			"GITHUB_JOIN_APP_API_BASE_URL":  api,
		}
	}

	app, reason, err := githubJoinAppFromEnv(env(nil), nil, false)
	if app != nil || reason != "" || err != nil {
		t.Fatalf("nothing set, no provisioner: %v %q %v", app, reason, err)
	}
	app, reason, err = githubJoinAppFromEnv(env(nil), provisioner, false)
	if app != nil || !strings.Contains(reason, "GitHub join disabled") || err != nil {
		t.Fatalf("nothing set: %v %q %v", app, reason, err)
	}
	for _, partial := range []map[string]string{
		{"GITHUB_JOIN_APP_CLIENT_ID": "id"},
		{"GITHUB_JOIN_APP_CLIENT_SECRET": "secret"},
	} {
		if _, _, err := githubJoinAppFromEnv(env(partial), provisioner, false); err == nil || !strings.Contains(err.Error(), "incomplete") {
			t.Fatalf("partial %v: err = %v", partial, err)
		}
	}
	if _, _, err := githubJoinAppFromEnv(env(both), nil, false); err == nil || !strings.Contains(err.Error(), "provisioning is disabled") {
		t.Fatalf("both without a provisioner: err = %v", err)
	}

	app, reason, err = githubJoinAppFromEnv(env(both), provisioner, false)
	if err != nil || app == nil || reason != "" {
		t.Fatalf("both: %v %q %v", app, reason, err)
	}
	if app.clientID != "id" || app.clientSecret != "secret" {
		t.Fatalf("app = %+v", app)
	}
	if app.authorizeURL != githubDefaultAuthorizeURL || app.tokenURL != githubDefaultTokenURL || app.apiBaseURL != "https://ghe.example/api/v3" {
		t.Fatalf("defaults: %+v", app)
	}

	// Overrides: https anywhere; http only on a local host, or in development.
	app, _, err = githubJoinAppFromEnv(env(withURLs("https://ghe.example/login/oauth/authorize", "https://ghe.example/login/oauth/access_token/", "https://ghe.example/api/v3")), provisioner, false)
	if err != nil || app.authorizeURL != "https://ghe.example/login/oauth/authorize" || app.tokenURL != "https://ghe.example/login/oauth/access_token" || app.apiBaseURL != "https://ghe.example/api/v3" {
		t.Fatalf("https overrides: %+v %v", app, err)
	}
	for _, host := range []string{"127.0.0.1:9", "localhost:9", "[::1]:9", "host.docker.internal:9"} {
		if _, _, err := githubJoinAppFromEnv(env(withURLs("http://"+host+"/authorize", "http://"+host+"/token", "http://"+host+"/api")), provisioner, false); err != nil {
			t.Fatalf("http on %s: %v", host, err)
		}
	}
	for _, values := range []map[string]string{
		withURLs("http://github.example/authorize", "https://github.example/token", "https://github.example/api"),
		withURLs("https://github.example/authorize", "http://github.example/token", "https://github.example/api"),
		withURLs("https://github.example/authorize", "https://github.example/token", "http://github.example/api"),
	} {
		if _, _, err := githubJoinAppFromEnv(env(values), provisioner, false); err == nil || !strings.Contains(err.Error(), "must be https") {
			t.Fatalf("plain http to a remote host was accepted: %v", err)
		}
		if _, _, err := githubJoinAppFromEnv(env(values), provisioner, true); err != nil {
			t.Fatalf("plain http refused in development: %v", err)
		}
	}
	// The provisioner's own base URL is checked too when it is the default.
	httpProvisioner := &githubProvisioner{client: newGitHubClient("http://github.example/api", githubStaticTokenSource{token: "t"}), org: "course"}
	if _, _, err := githubJoinAppFromEnv(env(both), httpProvisioner, false); err == nil || !strings.Contains(err.Error(), "must be https") {
		t.Fatalf("http provisioner base accepted: %v", err)
	}
	if _, _, err := githubJoinAppFromEnv(env(withURLs("https://x.example/a", "ftp://x.example/t", "https://x.example/api")), provisioner, true); err == nil {
		t.Fatal("a non-http token URL was accepted")
	}
}
