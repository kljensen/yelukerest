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
	"reflect"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexedwards/scs/v2/memstore"
)

// ---------------------------------------------------------------------
// Fake Hydra admin API
// ---------------------------------------------------------------------

type hydraAdminCall struct {
	Method string
	Path   string
	Query  url.Values
	Body   []byte
}

// fakeHydraAdmin stands in for Hydra's admin API. Every handler records
// what it was asked so tests can assert on the exact accept payloads.
type fakeHydraAdmin struct {
	server *httptest.Server

	loginRequest   hydraLoginRequest
	consentRequest hydraConsentRequest

	// status overrides let a test simulate an expired challenge or an
	// unhealthy Hydra. Zero means 200.
	loginLookupStatus   int
	consentLookupStatus int
	acceptStatus        int

	redirectTo string
	calls      []hydraAdminCall
}

func newFakeHydraAdmin(t *testing.T) *fakeHydraAdmin {
	t.Helper()
	fake := &fakeHydraAdmin{
		redirectTo: "https://localhost/oauth2/auth?client_id=canary&resume=1",
		loginRequest: hydraLoginRequest{
			Challenge:      "login-challenge-value",
			RequestedScope: []string{"openid", "offline_access"},
			Client:         hydraClientInfo{ClientID: "client-abc", RedirectURIs: []string{"https://claude.ai/api/mcp/auth_callback"}},
		},
		consentRequest: hydraConsentRequest{
			Challenge:      "consent-challenge-value",
			Subject:        "abc123",
			RequestedScope: []string{"openid", "offline_access", "course:read", "submissions:write"},
			Client: hydraClientInfo{
				ClientID:     "client-abc",
				ClientName:   "Canary Client",
				RedirectURIs: []string{"https://claude.ai/api/mcp/auth_callback"},
				Audience:     []string{"https://localhost/mcp"},
			},
		},
	}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.serve))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeHydraAdmin) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.calls = append(f.calls, hydraAdminCall{
		Method: r.Method,
		Path:   r.URL.Path,
		Query:  r.URL.Query(),
		Body:   body,
	})
	w.Header().Set("Content-Type", "application/json")

	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/admin/oauth2/auth/requests/login":
		if f.loginLookupStatus != 0 {
			w.WriteHeader(f.loginLookupStatus)
			_, _ = io.WriteString(w, `{"error":"not found"}`)
			return
		}
		_ = json.NewEncoder(w).Encode(f.loginRequest)
	case r.Method == http.MethodGet && r.URL.Path == "/admin/oauth2/auth/requests/consent":
		if f.consentLookupStatus != 0 {
			w.WriteHeader(f.consentLookupStatus)
			_, _ = io.WriteString(w, `{"error":"not found"}`)
			return
		}
		_ = json.NewEncoder(w).Encode(f.consentRequest)
	case r.Method == http.MethodPut && strings.HasSuffix(r.URL.Path, "/accept"),
		r.Method == http.MethodPut && strings.HasSuffix(r.URL.Path, "/reject"):
		if f.acceptStatus != 0 {
			w.WriteHeader(f.acceptStatus)
			_, _ = io.WriteString(w, `{"error":"boom"}`)
			return
		}
		_ = json.NewEncoder(w).Encode(hydraRedirect{RedirectTo: f.redirectTo})
	case r.Method == http.MethodPatch && strings.HasPrefix(r.URL.Path, "/admin/clients/"):
		_ = json.NewEncoder(w).Encode(f.consentRequest.Client)
	default:
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"error":"unexpected admin call"}`)
	}
}

// callsTo returns the recorded calls for one method/path pair.
func (f *fakeHydraAdmin) callsTo(method string, path string) []hydraAdminCall {
	var matched []hydraAdminCall
	for _, call := range f.calls {
		if call.Method == method && call.Path == path {
			matched = append(matched, call)
		}
	}
	return matched
}

func (f *fakeHydraAdmin) lastCallTo(t *testing.T, method string, path string) hydraAdminCall {
	t.Helper()
	matched := f.callsTo(method, path)
	if len(matched) == 0 {
		t.Fatalf("no %s %s call was made; calls: %+v", method, path, f.calls)
	}
	return matched[len(matched)-1]
}

func decodeCallBody(t *testing.T, call hydraAdminCall) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(call.Body, &payload); err != nil {
		t.Fatalf("call body is not a JSON object: %v (%s)", err, call.Body)
	}
	return payload
}

// ---------------------------------------------------------------------
// Test harness: the real handlers behind the real session manager
// ---------------------------------------------------------------------

const (
	testLoginChallenge   = "login-challenge-value"
	testConsentChallenge = "consent-challenge-value"
)

type oauthTestOptions struct {
	rateLimit int
	mutate    func(*oauthFlowConfig)
}

type oauthTestStack struct {
	server *httptest.Server
	client *http.Client
	hydra  *fakeHydraAdmin
}

func newOAuthTestStack(t *testing.T, fake *fakeHydraAdmin, options oauthTestOptions) *oauthTestStack {
	t.Helper()
	if options.rateLimit == 0 {
		options.rateLimit = 1000
	}

	sessionManager := newSessionManager(true, memstore.New())
	config := oauthFlowConfig{
		Admin:        newHydraAdminClient(fake.server.URL, fake.server.Client()),
		MCPAudience:  "https://localhost/mcp",
		CASLoginPath: "/auth/login",
		FetchUser: func(netID string) (*UserJWTInfo, error, int) {
			return &UserJWTInfo{ID: 42, NetID: netID, Role: "student"}, nil, http.StatusOK
		},
	}
	if options.mutate != nil {
		options.mutate(&config)
	}

	limiter := newRateLimiter(options.rateLimit, time.Minute)
	mux := http.NewServeMux()
	mux.Handle(oauthLoginPath, rateLimitMiddleware(limiter, getOAuthLoginHandler(config, sessionManager)))
	mux.Handle(oauthConsentPath, rateLimitMiddleware(limiter, getOAuthConsentHandler(config, sessionManager)))
	mux.Handle(oauthStylesheetPath, getOAuthStylesheetHandler())
	// Stands in for the CAS validate handler, which is the only thing
	// that ever writes a netid into the session.
	mux.HandleFunc("/test/seed", func(w http.ResponseWriter, r *http.Request) {
		sessionManager.Put(r.Context(), "netid", r.URL.Query().Get("netid"))
		w.WriteHeader(http.StatusNoContent)
	})

	server := httptest.NewServer(sessionManager.LoadAndSave(mux))
	t.Cleanup(server.Close)

	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatalf("cookiejar: %v", err)
	}
	client := &http.Client{
		Jar: jar,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &oauthTestStack{server: server, client: client, hydra: fake}
}

func (s *oauthTestStack) signIn(t *testing.T, netID string) {
	t.Helper()
	response, err := s.client.Get(s.server.URL + "/test/seed?netid=" + url.QueryEscape(netID))
	if err != nil {
		t.Fatalf("seeding the session failed: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("seed status = %d", response.StatusCode)
	}
}

func (s *oauthTestStack) get(t *testing.T, path string) (*http.Response, string) {
	t.Helper()
	response, err := s.client.Get(s.server.URL + path)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	return response, string(body)
}

func (s *oauthTestStack) postForm(t *testing.T, path string, form url.Values) (*http.Response, string) {
	t.Helper()
	response, err := s.client.PostForm(s.server.URL+path, form)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	return response, string(body)
}

var csrfFieldPattern = regexp.MustCompile(`name="csrf_token" value="([0-9a-f]+)"`)

// renderConsentForm signs in, fetches the consent page, and returns the
// form values a browser would submit with everything pre-checked left
// as-is.
func (s *oauthTestStack) renderConsentForm(t *testing.T) (string, string) {
	t.Helper()
	response, body := s.get(t, oauthConsentPath+"?consent_challenge="+testConsentChallenge)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("consent GET status = %d, body = %s", response.StatusCode, body)
	}
	matches := csrfFieldPattern.FindStringSubmatch(body)
	if len(matches) != 2 {
		t.Fatalf("no csrf_token field in the consent page:\n%s", body)
	}
	return matches[1], body
}

func assertNoStore(t *testing.T, response *http.Response) {
	t.Helper()
	if got := response.Header.Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
	if got := response.Header.Get("X-Frame-Options"); got != "DENY" {
		t.Fatalf("X-Frame-Options = %q, want DENY", got)
	}
}

// ---------------------------------------------------------------------
// Login handler
// ---------------------------------------------------------------------

func TestOAuthLoginRedirectsToCASWithoutSession(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})

	response, _ := stack.get(t, oauthLoginPath+"?login_challenge="+testLoginChallenge)
	if response.StatusCode != http.StatusFound {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusFound)
	}
	assertNoStore(t, response)

	location := response.Header.Get("Location")
	target, err := url.Parse(location)
	if err != nil {
		t.Fatalf("Location %q is not a URL: %v", location, err)
	}
	if target.IsAbs() || target.Host != "" {
		t.Fatalf("CAS redirect left this origin: %q", location)
	}
	if target.Path != "/auth/login" {
		t.Fatalf("CAS redirect path = %q, want /auth/login", target.Path)
	}

	// The return target must be an internal path and must carry the
	// challenge so the user lands back on this exact request.
	next := target.Query().Get("next")
	if next != safeRedirectPath(next) {
		t.Fatalf("next %q is not an internal path", next)
	}
	nextURL, err := url.Parse(next)
	if err != nil {
		t.Fatalf("next %q is not a URL: %v", next, err)
	}
	if nextURL.IsAbs() || nextURL.Host != "" {
		t.Fatalf("next %q is an open redirect", next)
	}
	if nextURL.Path != oauthLoginPath {
		t.Fatalf("next path = %q, want %q", nextURL.Path, oauthLoginPath)
	}
	if got := nextURL.Query().Get("login_challenge"); got != testLoginChallenge {
		t.Fatalf("next login_challenge = %q", got)
	}

	if calls := fake.callsTo(http.MethodPut, "/admin/oauth2/auth/requests/login/accept"); len(calls) != 0 {
		t.Fatalf("login was accepted without a session: %+v", calls)
	}
}

// An attacker-supplied absolute `next` must not survive into the CAS
// bounce: the handler rebuilds the return target from its own constants.
func TestOAuthLoginIgnoresCallerSuppliedNext(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})

	response, _ := stack.get(t, oauthLoginPath+"?login_challenge="+testLoginChallenge+
		"&next="+url.QueryEscape("https://evil.example.com/steal"))

	location := response.Header.Get("Location")
	if strings.Contains(location, "evil.example.com") {
		t.Fatalf("attacker-supplied next reached the redirect: %q", location)
	}
}

func TestOAuthLoginAcceptsSessionSubject(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")

	// The query carries a hostile subject; it must be ignored.
	response, _ := stack.get(t, oauthLoginPath+"?login_challenge="+testLoginChallenge+"&subject=faculty1")
	if response.StatusCode != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusSeeOther)
	}
	if got := response.Header.Get("Location"); got != fake.redirectTo {
		t.Fatalf("Location = %q, want %q", got, fake.redirectTo)
	}
	assertNoStore(t, response)

	call := fake.lastCallTo(t, http.MethodPut, "/admin/oauth2/auth/requests/login/accept")
	if got := call.Query.Get("login_challenge"); got != testLoginChallenge {
		t.Fatalf("accept login_challenge = %q", got)
	}
	payload := decodeCallBody(t, call)
	if payload["subject"] != "abc123" {
		t.Fatalf("accepted subject = %v, want abc123", payload["subject"])
	}
	if payload["remember"] != false {
		t.Fatalf("remember = %v, want false", payload["remember"])
	}
}

func TestOAuthLoginSkipAcceptsHydraSubject(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	fake.loginRequest.Skip = true
	fake.loginRequest.Subject = "def456"
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})

	// No session at all: skip means Hydra already authenticated them.
	response, _ := stack.get(t, oauthLoginPath+"?login_challenge="+testLoginChallenge)
	if response.StatusCode != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusSeeOther)
	}
	payload := decodeCallBody(t, fake.lastCallTo(t, http.MethodPut, "/admin/oauth2/auth/requests/login/accept"))
	if payload["subject"] != "def456" {
		t.Fatalf("accepted subject = %v, want def456", payload["subject"])
	}
}

func TestOAuthChallengeValidation(t *testing.T) {
	tests := []struct {
		name  string
		query string
	}{
		{name: "missing", query: ""},
		{name: "empty", query: "?login_challenge="},
		{name: "spaces", query: "?login_challenge=" + url.QueryEscape("bad challenge")},
		{name: "path traversal", query: "?login_challenge=" + url.QueryEscape("../../admin/clients")},
		{name: "angle brackets", query: "?login_challenge=" + url.QueryEscape("<script>")},
		{name: "too long", query: "?login_challenge=" + strings.Repeat("a", oauthChallengeMaxLen+1)},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakeHydraAdmin(t)
			stack := newOAuthTestStack(t, fake, oauthTestOptions{})
			response, _ := stack.get(t, oauthLoginPath+tt.query)
			if response.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusBadRequest)
			}
			if len(fake.calls) != 0 {
				t.Fatalf("a malformed challenge reached hydra: %+v", fake.calls)
			}
		})
	}
}

// Hydra with an in-memory DSN encodes the whole authorization request
// into the challenge: over a kilobyte of base64url with "==" padding.
// The validator must not reject that shape.
func TestOAuthAcceptsLongPaddedChallenges(t *testing.T) {
	longChallenge := strings.Repeat("aB9-_", 240) + "=="
	if len(longChallenge) < 1168 {
		t.Fatalf("test challenge is shorter than the measured live one (%d)", len(longChallenge))
	}

	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")

	response, body := stack.get(t, oauthLoginPath+"?login_challenge="+url.QueryEscape(longChallenge))
	if response.StatusCode != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d: %s", response.StatusCode, http.StatusSeeOther, body)
	}
	call := fake.lastCallTo(t, http.MethodGet, "/admin/oauth2/auth/requests/login")
	if got := call.Query.Get("login_challenge"); got != longChallenge {
		t.Fatalf("the challenge was mangled before reaching hydra")
	}
}

func TestOAuthLoginMapsAdminFailures(t *testing.T) {
	tests := []struct {
		name       string
		status     int
		wantStatus int
	}{
		{name: "expired challenge", status: http.StatusNotFound, wantStatus: http.StatusBadRequest},
		{name: "gone challenge", status: http.StatusGone, wantStatus: http.StatusBadRequest},
		{name: "hydra unwell", status: http.StatusInternalServerError, wantStatus: http.StatusBadGateway},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakeHydraAdmin(t)
			fake.loginLookupStatus = tt.status
			stack := newOAuthTestStack(t, fake, oauthTestOptions{})
			response, body := stack.get(t, oauthLoginPath+"?login_challenge="+testLoginChallenge)
			if response.StatusCode != tt.wantStatus {
				t.Fatalf("status = %d, want %d", response.StatusCode, tt.wantStatus)
			}
			if strings.Contains(body, "boom") || strings.Contains(body, "not found") {
				t.Fatalf("upstream error text leaked to the browser: %q", body)
			}
		})
	}
}

func TestOAuthLoginRejectsNonGET(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	response, _ := stack.postForm(t, oauthLoginPath+"?login_challenge="+testLoginChallenge, url.Values{})
	if response.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusMethodNotAllowed)
	}
}

// ---------------------------------------------------------------------
// Consent page
// ---------------------------------------------------------------------

func TestOAuthConsentFormRendersVerifiedIdentityAndScopes(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")

	response, body := stack.get(t, oauthConsentPath+"?consent_challenge="+testConsentChallenge)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", response.StatusCode, body)
	}
	assertNoStore(t, response)
	if contentType := response.Header.Get("Content-Type"); !strings.HasPrefix(contentType, "text/html") {
		t.Fatalf("Content-Type = %q", contentType)
	}

	// Verified identity: the registered redirect origin and client id.
	for _, want := range []string{"https://claude.ai", "client-abc", "abc123"} {
		if !strings.Contains(body, want) {
			t.Fatalf("consent page is missing %q:\n%s", want, body)
		}
	}
	// The full redirect path is reduced to an origin so a long URL
	// cannot push the meaningful part off-screen.
	if strings.Contains(body, "auth_callback") {
		t.Fatalf("consent page shows the full redirect URI rather than its origin")
	}
	// The self-reported name is shown but labeled.
	if !strings.Contains(body, "self-reported") {
		t.Fatalf("consent page does not label client_name as self-reported")
	}

	// Every requested scope appears; write scopes start unchecked.
	for _, scope := range fake.consentRequest.RequestedScope {
		if !strings.Contains(body, `value="`+scope+`"`) {
			t.Fatalf("scope %q is missing from the form:\n%s", scope, body)
		}
	}
	if !strings.Contains(body, `value="course:read" checked`) {
		t.Fatalf("read scope course:read is not checked by default")
	}
	if !strings.Contains(body, `value="openid" checked`) {
		t.Fatalf("openid is not checked by default")
	}
	if strings.Contains(body, `value="submissions:write" checked`) {
		t.Fatalf("write scope submissions:write must start unchecked")
	}

	// The policy note's data categories are named.
	for _, want := range []string{"grades", "submissions", "assignment"} {
		if !strings.Contains(strings.ToLower(body), want) {
			t.Fatalf("consent page does not name the %q data category", want)
		}
	}

	// JS-free: the CSP forbids inline scripts anyway, so the page must
	// not need them.
	if strings.Contains(strings.ToLower(body), "<script") || strings.Contains(strings.ToLower(body), "onclick=") {
		t.Fatalf("consent page contains script:\n%s", body)
	}
	assertFormActionReachesClient(t, response, fake.consentRequest.Client.RedirectURIs)
}

// assertFormActionReachesClient checks the property that actually matters
// about form-action here: submitting this form has to be able to END UP at the
// client's registered redirect URI.
//
// The assertion this replaced demanded form-action 'self' exactly, which reads
// as the safe choice and is the bug. Safari applies form-action to every hop of
// a redirect chain, and consent 303s through Hydra to the client's origin, so
// 'self' alone makes Safari abandon the navigation after the authorization code
// has already been issued. Nothing in an HTTP-level test can see that -- no Go
// client, and no fetch() in the OAuth suite, implements CSP -- which is exactly
// why the header itself has to carry the assertion.
func assertFormActionReachesClient(t *testing.T, response *http.Response, redirectURIs []string) {
	t.Helper()
	csp := response.Header.Get("Content-Security-Policy")
	var formAction string
	for _, directive := range strings.Split(csp, ";") {
		directive = strings.TrimSpace(directive)
		if rest, ok := strings.CutPrefix(directive, "form-action "); ok {
			formAction = rest
		}
	}
	if formAction == "" {
		t.Fatalf("no form-action directive in CSP %q", csp)
	}
	sources := strings.Fields(formAction)
	if !slices.Contains(sources, "'self'") {
		t.Fatalf("form-action %q does not allow 'self'; the form posts here first", formAction)
	}
	for _, want := range cspFormTargetsFor(redirectURIs) {
		if !slices.Contains(sources, want) {
			t.Fatalf("form-action %q cannot reach the client's redirect origin %q; "+
				"Safari will silently abandon the consent redirect", formAction, want)
		}
	}
}

func TestOAuthConsentFormEscapesHostileClientStrings(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	fake.consentRequest.Client.ClientName = `"><script>alert(1)</script>`
	fake.consentRequest.Client.RedirectURIs = []string{`https://evil.example/"><img src=x onerror=alert(1)>`}
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")

	_, body := stack.get(t, oauthConsentPath+"?consent_challenge="+testConsentChallenge)
	if strings.Contains(body, "<script>alert(1)</script>") {
		t.Fatalf("client_name was not escaped:\n%s", body)
	}
	if strings.Contains(body, "onerror=") {
		t.Fatalf("redirect URI was not escaped:\n%s", body)
	}
	if !strings.Contains(body, "&lt;script&gt;") && !strings.Contains(body, "&#34;&gt;&lt;script&gt;") {
		t.Fatalf("expected escaped client_name in the page:\n%s", body)
	}
}

func TestOAuthConsentFormRequiresSession(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})

	response, _ := stack.get(t, oauthConsentPath+"?consent_challenge="+testConsentChallenge)
	if response.StatusCode != http.StatusFound {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusFound)
	}
	location := response.Header.Get("Location")
	if !strings.HasPrefix(location, "/auth/login?") {
		t.Fatalf("Location = %q, want a CAS bounce", location)
	}
	next, err := url.Parse(mustQueryValue(t, location, "next"))
	if err != nil || next.IsAbs() || next.Host != "" {
		t.Fatalf("next %q is not an internal path", next)
	}
}

func mustQueryValue(t *testing.T, rawURL string, name string) string {
	t.Helper()
	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("parsing %q: %v", rawURL, err)
	}
	return parsed.Query().Get(name)
}

func TestOAuthConsentRefusesSubjectMismatch(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	fake.consentRequest.Subject = "someone-else"
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")

	response, _ := stack.get(t, oauthConsentPath+"?consent_challenge="+testConsentChallenge)
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusForbidden)
	}
}

// ---------------------------------------------------------------------
// Consent decision
// ---------------------------------------------------------------------

func TestOAuthConsentAcceptSendsServerDerivedPayload(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")
	token, _ := stack.renderConsentForm(t)

	response, _ := stack.postForm(t, oauthConsentPath, url.Values{
		"csrf_token":        {token},
		"consent_challenge": {testConsentChallenge},
		"action":            {"allow"},
		"grant_scope":       {"openid", "offline_access", "course:read"},
	})
	if response.StatusCode != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusSeeOther)
	}
	if got := response.Header.Get("Location"); got != fake.redirectTo {
		t.Fatalf("Location = %q, want %q", got, fake.redirectTo)
	}

	call := fake.lastCallTo(t, http.MethodPut, "/admin/oauth2/auth/requests/consent/accept")
	if got := call.Query.Get("consent_challenge"); got != testConsentChallenge {
		t.Fatalf("accept consent_challenge = %q", got)
	}
	payload := decodeCallBody(t, call)

	wantScopes := []any{"openid", "offline_access", "course:read"}
	if !reflect.DeepEqual(payload["grant_scope"], wantScopes) {
		t.Fatalf("grant_scope = %v, want %v", payload["grant_scope"], wantScopes)
	}
	wantAudience := []any{"https://localhost/mcp"}
	if !reflect.DeepEqual(payload["grant_access_token_audience"], wantAudience) {
		t.Fatalf("grant_access_token_audience = %v, want %v", payload["grant_access_token_audience"], wantAudience)
	}
	if payload["remember"] != false {
		t.Fatalf("remember = %v, want false", payload["remember"])
	}

	session, ok := payload["session"].(map[string]any)
	if !ok {
		t.Fatalf("session is missing: %v", payload)
	}
	claims, ok := session["access_token"].(map[string]any)
	if !ok {
		t.Fatalf("session.access_token is missing: %v", session)
	}
	if claims["netid"] != "abc123" {
		t.Fatalf("netid claim = %v", claims["netid"])
	}
	if claims["user_id"] != float64(42) {
		t.Fatalf("user_id claim = %v", claims["user_id"])
	}
	if claims["role"] != "student" {
		t.Fatalf("role claim = %v", claims["role"])
	}
	if claims["scopes"] != "openid offline_access course:read" {
		t.Fatalf("scopes claim = %v", claims["scopes"])
	}
}

// The form is decoration: the subject, client, and the set of grantable
// scopes all come from the re-fetched consent request.
func TestOAuthConsentIgnoresTamperedFields(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")
	token, _ := stack.renderConsentForm(t)

	response, _ := stack.postForm(t, oauthConsentPath, url.Values{
		"csrf_token":        {token},
		"consent_challenge": {testConsentChallenge},
		"action":            {"allow"},
		// Two scopes Hydra never requested, plus one it did.
		"grant_scope": {"course:read", "admin:everything", "grades:write"},
		// Hostile identity fields.
		"subject":  {"faculty1"},
		"netid":    {"faculty1"},
		"user_id":  {"1"},
		"role":     {"faculty"},
		"audience": {"https://evil.example/mcp"},
	})
	if response.StatusCode != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusSeeOther)
	}

	payload := decodeCallBody(t, fake.lastCallTo(t, http.MethodPut, "/admin/oauth2/auth/requests/consent/accept"))
	if !reflect.DeepEqual(payload["grant_scope"], []any{"course:read"}) {
		t.Fatalf("grant_scope = %v, want only the requested-and-approved scope", payload["grant_scope"])
	}
	if !reflect.DeepEqual(payload["grant_access_token_audience"], []any{"https://localhost/mcp"}) {
		t.Fatalf("audience = %v", payload["grant_access_token_audience"])
	}
	claims := payload["session"].(map[string]any)["access_token"].(map[string]any)
	if claims["netid"] != "abc123" || claims["role"] != "student" || claims["user_id"] != float64(42) {
		t.Fatalf("identity claims came from the form: %v", claims)
	}
}

func TestOAuthConsentCSRF(t *testing.T) {
	tests := []struct {
		name  string
		token func(issued string) string
	}{
		{name: "missing token", token: func(string) string { return "" }},
		{name: "wrong token", token: func(string) string { return strings.Repeat("0", 64) }},
		{name: "truncated token", token: func(issued string) string { return issued[:len(issued)-1] }},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakeHydraAdmin(t)
			stack := newOAuthTestStack(t, fake, oauthTestOptions{})
			stack.signIn(t, "abc123")
			issued, _ := stack.renderConsentForm(t)

			response, _ := stack.postForm(t, oauthConsentPath, url.Values{
				"csrf_token":        {tt.token(issued)},
				"consent_challenge": {testConsentChallenge},
				"action":            {"allow"},
				"grant_scope":       {"course:read"},
			})
			if response.StatusCode != http.StatusForbidden {
				t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusForbidden)
			}
			if calls := fake.callsTo(http.MethodPut, "/admin/oauth2/auth/requests/consent/accept"); len(calls) != 0 {
				t.Fatalf("consent was accepted despite a bad CSRF token: %+v", calls)
			}
		})
	}
}

// The token is single-use: a replayed submission (back button, a
// duplicated tab, a captured request) cannot grant a second time.
func TestOAuthConsentCSRFTokenIsSingleUse(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")
	token, _ := stack.renderConsentForm(t)

	form := url.Values{
		"csrf_token":        {token},
		"consent_challenge": {testConsentChallenge},
		"action":            {"allow"},
		"grant_scope":       {"course:read"},
	}
	if response, _ := stack.postForm(t, oauthConsentPath, form); response.StatusCode != http.StatusSeeOther {
		t.Fatalf("first submission status = %d", response.StatusCode)
	}
	if response, _ := stack.postForm(t, oauthConsentPath, form); response.StatusCode != http.StatusForbidden {
		t.Fatalf("replayed submission status = %d, want %d", response.StatusCode, http.StatusForbidden)
	}
	if calls := fake.callsTo(http.MethodPut, "/admin/oauth2/auth/requests/consent/accept"); len(calls) != 1 {
		t.Fatalf("accept was called %d times, want 1", len(calls))
	}
}

// A token issued for one challenge cannot approve another.
func TestOAuthConsentCSRFTokenIsBoundToTheChallenge(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")
	token, _ := stack.renderConsentForm(t)

	response, _ := stack.postForm(t, oauthConsentPath, url.Values{
		"csrf_token":        {token},
		"consent_challenge": {"a-different-challenge"},
		"action":            {"allow"},
		"grant_scope":       {"course:read"},
	})
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusForbidden)
	}
}

// A token issued to one browser session cannot be used from another.
func TestOAuthConsentCSRFTokenIsBoundToTheSession(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")
	token, _ := stack.renderConsentForm(t)

	// A second browser with its own session and no issued token.
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatalf("cookiejar: %v", err)
	}
	other := &oauthTestStack{
		server: stack.server,
		hydra:  fake,
		client: &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}},
	}
	other.signIn(t, "abc123")

	response, _ := other.postForm(t, oauthConsentPath, url.Values{
		"csrf_token":        {token},
		"consent_challenge": {testConsentChallenge},
		"action":            {"allow"},
		"grant_scope":       {"course:read"},
	})
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusForbidden)
	}
}

func TestOAuthConsentDeny(t *testing.T) {
	tests := []struct {
		name   string
		action string
	}{
		{name: "explicit deny", action: "deny"},
		{name: "unknown action fails closed", action: "maybe"},
		{name: "absent action fails closed", action: ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakeHydraAdmin(t)
			stack := newOAuthTestStack(t, fake, oauthTestOptions{})
			stack.signIn(t, "abc123")
			token, _ := stack.renderConsentForm(t)

			response, _ := stack.postForm(t, oauthConsentPath, url.Values{
				"csrf_token":        {token},
				"consent_challenge": {testConsentChallenge},
				"action":            {tt.action},
				"grant_scope":       {"course:read"},
			})
			if response.StatusCode != http.StatusSeeOther {
				t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusSeeOther)
			}
			if calls := fake.callsTo(http.MethodPut, "/admin/oauth2/auth/requests/consent/accept"); len(calls) != 0 {
				t.Fatalf("a denial accepted consent: %+v", calls)
			}
			payload := decodeCallBody(t, fake.lastCallTo(t, http.MethodPut, "/admin/oauth2/auth/requests/consent/reject"))
			if payload["error"] != "access_denied" {
				t.Fatalf("reject error = %v, want access_denied", payload["error"])
			}
		})
	}
}

func TestOAuthConsentEnsuresClientAudienceAllowlist(t *testing.T) {
	tests := []struct {
		name      string
		allowlist []string
		wantPatch bool
	}{
		{name: "already allowlisted", allowlist: []string{"https://localhost/mcp"}, wantPatch: false},
		{name: "empty allowlist is repaired", allowlist: nil, wantPatch: true},
		{name: "other entries are preserved", allowlist: []string{"https://other.example/api"}, wantPatch: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakeHydraAdmin(t)
			fake.consentRequest.Client.Audience = tt.allowlist
			stack := newOAuthTestStack(t, fake, oauthTestOptions{})
			stack.signIn(t, "abc123")
			token, _ := stack.renderConsentForm(t)

			response, _ := stack.postForm(t, oauthConsentPath, url.Values{
				"csrf_token":        {token},
				"consent_challenge": {testConsentChallenge},
				"action":            {"allow"},
				"grant_scope":       {"course:read"},
			})
			if response.StatusCode != http.StatusSeeOther {
				t.Fatalf("status = %d", response.StatusCode)
			}

			patches := fake.callsTo(http.MethodPatch, "/admin/clients/client-abc")
			if !tt.wantPatch {
				if len(patches) != 0 {
					t.Fatalf("client was patched needlessly: %+v", patches)
				}
				return
			}
			if len(patches) != 1 {
				t.Fatalf("client patch count = %d, want 1", len(patches))
			}
			var operations []map[string]any
			if err := json.Unmarshal(patches[0].Body, &operations); err != nil {
				t.Fatalf("patch body is not a JSON patch: %v (%s)", err, patches[0].Body)
			}
			if len(operations) != 1 || operations[0]["path"] != "/audience" {
				t.Fatalf("unexpected patch: %v", operations)
			}
			values, ok := operations[0]["value"].([]any)
			if !ok {
				t.Fatalf("patch value is not an array: %v", operations[0]["value"])
			}
			var found bool
			for _, item := range values {
				if item == "https://localhost/mcp" {
					found = true
				}
			}
			if !found {
				t.Fatalf("patch does not add the MCP audience: %v", values)
			}
			for _, existing := range tt.allowlist {
				var kept bool
				for _, item := range values {
					if item == existing {
						kept = true
					}
				}
				if !kept {
					t.Fatalf("patch dropped the existing allowlist entry %q: %v", existing, values)
				}
			}
		})
	}
}

func TestOAuthConsentRefusesUnenrolledUser(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{
		mutate: func(config *oauthFlowConfig) {
			config.FetchUser = func(string) (*UserJWTInfo, error, int) {
				return nil, io.EOF, http.StatusForbidden
			}
		},
	})
	stack.signIn(t, "abc123")
	token, _ := stack.renderConsentForm(t)

	response, _ := stack.postForm(t, oauthConsentPath, url.Values{
		"csrf_token":        {token},
		"consent_challenge": {testConsentChallenge},
		"action":            {"allow"},
		"grant_scope":       {"course:read"},
	})
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusForbidden)
	}
	if calls := fake.callsTo(http.MethodPut, "/admin/oauth2/auth/requests/consent/accept"); len(calls) != 0 {
		t.Fatalf("consent was accepted for an unenrolled user: %+v", calls)
	}
}

// ---------------------------------------------------------------------
// Cross-cutting: rate limiting, logging hygiene, stylesheet
// ---------------------------------------------------------------------

func TestOAuthHandlersAreRateLimited(t *testing.T) {
	for _, path := range []string{oauthLoginPath + "?login_challenge=" + testLoginChallenge, oauthConsentPath + "?consent_challenge=" + testConsentChallenge} {
		t.Run(path, func(t *testing.T) {
			fake := newFakeHydraAdmin(t)
			stack := newOAuthTestStack(t, fake, oauthTestOptions{rateLimit: 2})
			for i := 0; i < 2; i++ {
				if response, _ := stack.get(t, path); response.StatusCode == http.StatusTooManyRequests {
					t.Fatalf("request %d was rate limited too early", i)
				}
			}
			response, _ := stack.get(t, path)
			if response.StatusCode != http.StatusTooManyRequests {
				t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusTooManyRequests)
			}
		})
	}
}

// Challenges are bearer-ish: whoever holds one can drive the flow. They
// must never land in a log line, and neither must Hydra's redirect_to
// (it carries the login/consent verifier).
func TestOAuthHandlersDoNotLogSecrets(t *testing.T) {
	var logs bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(previous) })

	fake := newFakeHydraAdmin(t)
	fake.redirectTo = "https://localhost/oauth2/auth?login_verifier=super-secret-verifier"
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")

	stack.get(t, oauthLoginPath+"?login_challenge="+testLoginChallenge)
	token, _ := stack.renderConsentForm(t)
	stack.postForm(t, oauthConsentPath, url.Values{
		"csrf_token":        {token},
		"consent_challenge": {testConsentChallenge},
		"action":            {"allow"},
		"grant_scope":       {"course:read"},
	})
	// Also exercise the error paths, which are the easy place to leak.
	fake.consentLookupStatus = http.StatusNotFound
	stack.get(t, oauthConsentPath+"?consent_challenge="+testConsentChallenge)

	for _, secret := range []string{testLoginChallenge, testConsentChallenge, token, "super-secret-verifier", "login_verifier"} {
		if strings.Contains(logs.String(), secret) {
			t.Fatalf("log output contains the secret %q:\n%s", secret, logs.String())
		}
	}
}

func TestOAuthStylesheetIsServedSameOrigin(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	response, body := stack.get(t, oauthStylesheetPath)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", response.StatusCode)
	}
	if got := response.Header.Get("Content-Type"); !strings.HasPrefix(got, "text/css") {
		t.Fatalf("Content-Type = %q", got)
	}
	if !strings.Contains(body, "main.consent") {
		t.Fatalf("stylesheet body = %q", body)
	}
}

// ---------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------

func TestIsWriteScope(t *testing.T) {
	tests := []struct {
		scope string
		want  bool
	}{
		{scope: "openid", want: false},
		{scope: "offline_access", want: false},
		{scope: "course:read", want: false},
		{scope: "grades:read", want: false},
		{scope: "submissions:read", want: false},
		{scope: "submissions:write", want: true},
		{scope: "SUBMISSIONS:WRITE", want: true},
		{scope: "admin", want: true},
		{scope: "grades:delete", want: true},
		{scope: "team:manage", want: true},
	}
	for _, tt := range tests {
		t.Run(tt.scope, func(t *testing.T) {
			if got := isWriteScope(tt.scope); got != tt.want {
				t.Fatalf("isWriteScope(%q) = %v, want %v", tt.scope, got, tt.want)
			}
		})
	}
}

func TestIntersectScopes(t *testing.T) {
	tests := []struct {
		name      string
		requested []string
		approved  []string
		want      []string
	}{
		{
			name:      "approval is a subset",
			requested: []string{"openid", "course:read", "submissions:write"},
			approved:  []string{"course:read"},
			want:      []string{"course:read"},
		},
		{
			name:      "unrequested approvals are dropped",
			requested: []string{"openid"},
			approved:  []string{"openid", "admin:everything"},
			want:      []string{"openid"},
		},
		{
			name:      "order follows the request, not the form",
			requested: []string{"openid", "offline_access", "course:read"},
			approved:  []string{"course:read", "openid", "offline_access"},
			want:      []string{"openid", "offline_access", "course:read"},
		},
		{
			name:      "duplicates collapse",
			requested: []string{"openid", "openid"},
			approved:  []string{"openid", "openid"},
			want:      []string{"openid"},
		},
		{
			name:      "nothing approved grants nothing",
			requested: []string{"openid", "course:read"},
			approved:  nil,
			want:      []string{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := intersectScopes(tt.requested, tt.approved)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("intersectScopes = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestRedirectOriginsFor(t *testing.T) {
	tests := []struct {
		name string
		uris []string
		want []string
	}{
		{
			name: "paths are reduced to origins",
			uris: []string{"https://claude.ai/api/mcp/auth_callback"},
			want: []string{"https://claude.ai"},
		},
		{
			name: "duplicate origins collapse",
			uris: []string{"https://claude.ai/a", "https://claude.ai/b"},
			want: []string{"https://claude.ai"},
		},
		{
			name: "loopback ports are preserved",
			uris: []string{"http://127.0.0.1:33418/callback", "http://localhost:33418/callback"},
			want: []string{"http://127.0.0.1:33418", "http://localhost:33418"},
		},
		{
			name: "hostless custom schemes are shown whole",
			uris: []string{"myapp:/oauth/callback"},
			want: []string{"myapp:/oauth/callback"},
		},
		{
			name: "blanks are dropped",
			uris: []string{"", "  "},
			want: []string{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := redirectOriginsFor(tt.uris)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("redirectOriginsFor = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestBuildConsentScopeViews(t *testing.T) {
	views := buildConsentScopeViews([]string{"openid", "openid", "", "submissions:write", "unknown:scope"})
	if len(views) != 3 {
		t.Fatalf("views = %+v, want 3", views)
	}
	if views[0].Name != "openid" || !views[0].Checked || views[0].Write {
		t.Fatalf("openid view = %+v", views[0])
	}
	if views[1].Name != "submissions:write" || views[1].Checked || !views[1].Write {
		t.Fatalf("submissions:write view = %+v", views[1])
	}
	if views[2].Description == "" {
		t.Fatalf("unknown scope has no description: %+v", views[2])
	}
}

// A successful-but-malformed consent response with no subject must fail
// closed: Hydra binds the token to the challenge's own subject, so
// accepting would mint this session's claims for another identity.
func TestOAuthConsentRefusesEmptySubject(t *testing.T) {
	fake := newFakeHydraAdmin(t)
	fake.consentRequest.Subject = ""
	stack := newOAuthTestStack(t, fake, oauthTestOptions{})
	stack.signIn(t, "abc123")

	response, _ := stack.get(t, oauthConsentPath+"?consent_challenge="+testConsentChallenge)
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusForbidden)
	}
}

// Registration is open, so a redirect_uri is attacker-supplied and lands in a
// response header. A value that could close the form-action directive and open
// another would turn an open DCR endpoint into CSP control for the whole page.
func TestCSPFormTargetsForRejectsHostileRedirectURIs(t *testing.T) {
	tests := []struct {
		name string
		uris []string
		want []string
	}{
		{
			name: "ordinary https redirect reduces to an origin",
			uris: []string{"https://claude.ai/api/mcp/auth_callback"},
			want: []string{"https://claude.ai"},
		},
		{
			name: "port is part of the origin",
			uris: []string{"http://127.0.0.1:8765/callback"},
			want: []string{"http://127.0.0.1:8765"},
		},
		{
			name: "native custom scheme keeps only the scheme",
			uris: []string{"myapp:/callback"},
			want: []string{"myapp:"},
		},
		{
			name: "duplicate origins collapse",
			uris: []string{"https://claude.ai/a", "https://claude.ai/b"},
			want: []string{"https://claude.ai"},
		},
		{
			// A semicolon would end form-action and start a new directive.
			name: "a semicolon in the host is dropped, not emitted",
			uris: []string{"https://evil.example;default-src *"},
			want: []string{},
		},
		{
			name: "whitespace injection is dropped",
			uris: []string{"https://evil.example unsafe-inline"},
			want: []string{},
		},
		{
			name: "a relative URI has no scheme and is skipped",
			uris: []string{"/callback"},
			want: []string{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := cspFormTargetsFor(tt.uris)
			if len(got) != len(tt.want) {
				t.Fatalf("cspFormTargetsFor(%q) = %q, want %q", tt.uris, got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Fatalf("cspFormTargetsFor(%q) = %q, want %q", tt.uris, got, tt.want)
				}
			}
		})
	}
}

// The header must never contain a newline or a stray directive separator no
// matter what was registered.
func TestConsentCSPCannotBeInjectedThrough(t *testing.T) {
	recorder := httptest.NewRecorder()
	setOAuthPageHeaders(recorder, cspFormTargetsFor([]string{
		"https://evil.example;script-src *",
		"https://good.example/cb",
	})...)
	csp := recorder.Header().Get("Content-Security-Policy")
	if strings.Contains(csp, "script-src") {
		t.Fatalf("a registered redirect URI injected a directive: %q", csp)
	}
	if !strings.Contains(csp, "https://good.example") {
		t.Fatalf("the legitimate origin was dropped: %q", csp)
	}
}
