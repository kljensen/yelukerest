package main

// Student-authorized organization joining (ADR 0006, issue #399).
//
//	GET  /auth/github/join?next=…          landing page; its script POSTs to start
//	GET  /auth/github/join.js              that script
//	POST /auth/github/join/start           {"next"} → {"authorization_url"}
//	GET  /auth/github/callback?code&state  where GitHub sends the student back
//
// Provisioning (provision.go) stops at needs_org_join for a student who is
// not an active member of the course organization. This is the way through:
// the student authorizes a second, org-owned GitHub App with their own
// account, GitHub hands authapp a token for that account, and authapp uses
// it for exactly two things -- learning which account it is (GET /user) and
// accepting the organization invitation the course credential just created
// (PATCH /user/memberships/orgs/{org}), which only the invitee can do. The
// invitation and the students-team add are made with the course credential.
// The two credentials never cross: each is a separate githubClient.
//
// The student's token lives in one local variable of the callback handler
// and nowhere else. It is not put in the session, not written to the
// database, not logged, and not returned; when the handler returns it is
// gone, on every path. The verified identity (numeric id, login, timestamp)
// is what persists, through api.set_user_github_identity.
//
// The state parameter is the CSRF guard for the round trip through GitHub.
// It is minted at start, stored in the student's own session with where to
// return to afterwards, and consumed by the callback: it therefore cannot
// be replayed, cannot be used from another session, and cannot be used
// after ten minutes. A PKCE verifier is minted with it and sent on the
// exchange, so a code intercepted on the way back is worthless without the
// session. Everything the callback then does is for the session's own
// user; nothing about who or where comes from the callback's query string.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/alexedwards/scs/v2"
)

const (
	githubJoinLandingPath  = "/auth/github/join"
	githubJoinScriptPath   = "/auth/github/join.js"
	githubJoinStartPath    = "/auth/github/join/start"
	githubJoinCallbackPath = "/auth/github/callback"
	// githubJoinLoginPath is where a signed-out visitor to the landing page
	// is sent; it is main's loginPath, restated here as a constant.
	githubJoinLoginPath = "/auth/login"

	githubDefaultAuthorizeURL = "https://github.com/login/oauth/authorize"
	githubDefaultTokenURL     = "https://github.com/login/oauth/access_token"

	// githubJoinStateLifetime is how long a minted state is honoured. The
	// student is on GitHub's authorize screen for a few seconds; ten minutes
	// is generous and matches what GitHub gives an authorization code.
	githubJoinStateLifetime = 10 * time.Minute
	// githubJoinStartsPerMinute is the per-student admission limit on
	// start. Each start replaces the previous state, so a loop here gains
	// nothing; the limit keeps it from costing anything either.
	githubJoinStartsPerMinute = 10
	githubJoinMaxBodyBytes    = 4 * 1024
	// sessionKeyGitHubJoin holds the one outstanding join, as JSON. One slot:
	// a second start replaces the first, and the first's authorize screen
	// then leads to a mismatch. That is the right end for two tabs.
	sessionKeyGitHubJoin = "github_join"
)

// githubJoinNext is where the callback sends the student afterwards: the
// repositories page by default, or the `next` the landing page was opened
// with. It is the one caller-supplied value that reaches a redirect, so it
// is checked here, at the landing page and at start, and never taken from
// the callback's query. Allowed: a path on this origin under the
// repositories page, or a client route (`/#/…`, the assignment page that
// offered the join). Anything else -- another origin, a protocol-relative
// URL, a path elsewhere on this site, control characters -- is refused,
// and the caller is told rather than quietly sent to the default, because
// a link built wrong should be noticed.
func githubJoinNext(raw string) (string, bool) {
	if raw == "" {
		return repositoriesPagePath, true
	}
	if len(raw) > 512 || strings.ContainsAny(raw, "\\ \t\r\n") || !githubJoinNextPattern.MatchString(raw) {
		return "", false
	}
	if strings.HasPrefix(raw, "/#/") {
		return raw, true
	}
	rest := strings.TrimPrefix(raw, repositoriesPagePath)
	if rest == raw || (rest != "" && rest[0] != '?' && rest[0] != '/' && rest[0] != '#') {
		return "", false
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.IsAbs() || parsed.Host != "" || strings.HasPrefix(parsed.Path, "//") {
		return "", false
	}
	return raw, true
}

// githubJoinNextPattern is the printable-ASCII shape a next must have,
// starting with a slash. The characters a redirect target can legitimately
// carry are all in it; a backslash and every control character are not.
var githubJoinNextPattern = regexp.MustCompile(`^/[A-Za-z0-9._~!$&'()*+,;=:@%/?#-]*$`)

// githubJoinApp is the join App's configuration. It is a plain OAuth client
// (id and secret) from authapp's point of view: no installation id, no
// private key, no installation token. The App is still installed on the
// course organization (docs/github-join.md): a user token can act on an
// organization only where its App is installed, within the installation's
// permissions. The authorization request names no scopes.
type githubJoinApp struct {
	clientID     string
	clientSecret string
	authorizeURL string
	tokenURL     string
	apiBaseURL   string
}

// githubJoinAppFromEnv reads the join configuration. Like the provisioner's,
// it returns (nil, reason, nil) when the feature is simply off and an error
// when the configuration is half done, because one of two variables set
// means someone meant to enable it. It also refuses both variables without
// a provisioner: the join is a step of provisioning and the invitation and
// team add need the provisioner's credential. The three URLs must be https
// outside development, because the client secret travels to the token URL
// and the student's token comes back from it; a loopback or
// host.docker.internal host is allowed in plain http for a local double.
func githubJoinAppFromEnv(getenv func(string) string, provisioner *githubProvisioner, isDevelopment bool) (*githubJoinApp, string, error) {
	trimmed := func(name string) string { return strings.TrimSpace(getenv(name)) }
	clientID := trimmed("GITHUB_JOIN_APP_CLIENT_ID")
	clientSecret := trimmed("GITHUB_JOIN_APP_CLIENT_SECRET")
	if clientID == "" && clientSecret == "" {
		if provisioner == nil {
			return nil, "", nil
		}
		return nil, "GitHub join disabled: GITHUB_JOIN_APP_CLIENT_ID and GITHUB_JOIN_APP_CLIENT_SECRET not set; students must be invited to the organization by hand", nil
	}
	if clientID == "" || clientSecret == "" {
		return nil, "", errors.New("GitHub join configuration is incomplete: set both GITHUB_JOIN_APP_CLIENT_ID and GITHUB_JOIN_APP_CLIENT_SECRET, or neither")
	}
	if provisioner == nil {
		return nil, "", errors.New("GITHUB_JOIN_APP_CLIENT_ID and GITHUB_JOIN_APP_CLIENT_SECRET are set but GitHub provisioning is disabled; the join flow needs the provisioner's organization and credential")
	}

	app := &githubJoinApp{
		clientID:     clientID,
		clientSecret: clientSecret,
		authorizeURL: githubDefaultAuthorizeURL,
		tokenURL:     githubDefaultTokenURL,
		apiBaseURL:   provisioner.client.baseURL,
	}
	urls := map[string]*string{
		"GITHUB_JOIN_APP_AUTHORIZE_URL": &app.authorizeURL,
		"GITHUB_JOIN_APP_TOKEN_URL":     &app.tokenURL,
		"GITHUB_JOIN_APP_API_BASE_URL":  &app.apiBaseURL,
	}
	for name, target := range urls {
		if value := trimmed(name); value != "" {
			*target = strings.TrimRight(value, "/")
		}
		parsed, err := url.Parse(*target)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return nil, "", fmt.Errorf("%s %q is not an http(s) URL", name, *target)
		}
		if parsed.Scheme == "http" && !isDevelopment && !isLocalHost(parsed.Hostname()) {
			return nil, "", fmt.Errorf("%s %q must be https outside development (the client secret and the student's token travel over it)", name, *target)
		}
	}
	return app, "", nil
}

// isLocalHost reports whether the host is this machine or the Docker host,
// where a plain-http test double is the only thing that could be listening.
func isLocalHost(host string) bool {
	if strings.EqualFold(host, "localhost") || strings.EqualFold(host, "host.docker.internal") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// githubJoinPending is the outstanding join, as stored in the session
// between start and callback. RedirectURI is kept because GitHub requires
// the token exchange to repeat exactly what the authorization request said.
type githubJoinPending struct {
	State        string    `json:"state"`
	CodeVerifier string    `json:"code_verifier"`
	UserID       int       `json:"user_id"`
	NetID        string    `json:"netid"`
	Next         string    `json:"next"`
	RedirectURI  string    `json:"redirect_uri"`
	CreatedAt    time.Time `json:"created_at"`
}

type githubJoinHandler struct {
	app      *githubJoinApp
	course   *githubProvisioner
	db       FetchJWTConfig
	sessions *scs.SessionManager
	limiter  *rateLimiter
	now      func() time.Time
	// httpClient is for the token exchange, which goes to github.com rather
	// than the API host and is not a githubClient call. No redirects, as
	// that client: a redirect on a POST carrying the client secret is not
	// something to follow.
	httpClient *http.Client
}

func newGitHubJoinHandler(course *githubProvisioner, db FetchJWTConfig, sessions *scs.SessionManager) *githubJoinHandler {
	return &githubJoinHandler{
		app:        course.join,
		course:     course,
		db:         db,
		sessions:   sessions,
		limiter:    newRateLimiter(githubJoinStartsPerMinute, time.Minute),
		now:        time.Now,
		httpClient: newGitHubHTTPClient(),
	}
}

// registerGitHubJoinRoutes adds the four routes when the join App is
// configured and nothing otherwise, as registerProvisioningRoutes does.
func registerGitHubJoinRoutes(mux *http.ServeMux, course *githubProvisioner, db FetchJWTConfig, sessions *scs.SessionManager) {
	if course == nil || course.join == nil {
		return
	}
	h := newGitHubJoinHandler(course, db, sessions)
	mux.HandleFunc("GET "+githubJoinLandingPath, h.serveLanding)
	mux.HandleFunc("GET "+githubJoinScriptPath, h.serveScript)
	mux.HandleFunc("POST "+githubJoinStartPath, h.serveStart)
	mux.HandleFunc("GET "+githubJoinCallbackPath, h.serveCallback)
}

// githubJoinURL is what provisioning puts in join_url: the landing page,
// on this origin, returning to next afterwards.
func githubJoinURL(next string) string {
	return githubJoinLandingPath + "?" + url.Values{"next": {next}}.Encode()
}

// ---------------------------------------------------------------------------
// Landing page and its script
// ---------------------------------------------------------------------------

// setLandingPageHeaders is setOAuthPageHeaders' counterpart for the
// landing page here and the repositories page (repositoriespage.go), which
// need a same-origin script, a same-origin fetch, and the same-origin
// stylesheet and nothing else. Caddy's site-wide CSP also applies to these
// paths and allows all three; the two are enforced as their intersection.
func setLandingPageHeaders(w http.ResponseWriter) {
	setNoStoreHeaders(w)
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
}

// githubJoinLandingTemplate is deliberately plain: an explanation and a
// button. The script does the POST on the click (so the same-origin check
// on start holds, and so a cross-site link to this page starts nothing by
// itself) and follows the authorization URL; the form is what the script
// attaches to, and what a student without JavaScript sees, with the
// noscript note. It is an external script because Caddy's CSP forbids
// inline ones.
var githubJoinLandingTemplate = template.Must(template.New("join").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Join the course organization on GitHub</title>
</head>
<body>
<main>
<h1>Join the course organization on GitHub</h1>
<p>Continue to GitHub to authorize the course's app. Authorizing it confirms which GitHub account is yours and accepts your invitation to the course organization; it grants the course no access to your repositories.</p>
<form id="join" method="POST" action="{{.StartPath}}">
<input type="hidden" name="next" value="{{.Next}}">
<button type="submit">Continue to GitHub</button>
</form>
<p id="status"><noscript>This page needs JavaScript to continue.</noscript></p>
<script src="{{.ScriptPath}}"></script>
</main>
</body>
</html>
`))

// githubJoinScript posts the form as JSON when it is submitted -- only
// then, never on load -- and follows the answer. The button is disabled
// while the request is in flight and re-enabled after a failure so the
// student can try again.
const githubJoinScript = `(function () {
  var form = document.getElementById("join");
  var button = form.querySelector("button");
  var status = document.getElementById("status");
  form.addEventListener("submit", function (event) {
    event.preventDefault();
    if (button.disabled) { return; }
    button.disabled = true;
    status.textContent = "Contacting the course site…";
    fetch(form.action, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({ next: form.elements.next.value })
    }).then(function (response) {
      return response.json().then(function (body) { return { ok: response.ok, body: body }; });
    }).then(function (result) {
      if (!result.ok || !result.body || !result.body.authorization_url) {
        var code = result.body && result.body.error && result.body.error.code;
        status.textContent = "Could not start the GitHub authorization" + (code ? " (" + code + ")" : "") + ". Use the button to try again.";
        button.disabled = false;
        return;
      }
      window.location.assign(result.body.authorization_url);
    }).catch(function () {
      status.textContent = "Could not reach the course site. Use the button to try again.";
      button.disabled = false;
    });
  });
})();
`

func (h *githubJoinHandler) serveLanding(w http.ResponseWriter, r *http.Request) {
	setLandingPageHeaders(w)
	next, ok := githubJoinNext(r.URL.Query().Get("next"))
	if !ok {
		http.Error(w, "Malformed next: it must be a path on this site under /auth/repositories or /#/", http.StatusBadRequest)
		return
	}
	if h.sessions.GetString(r.Context(), "netid") == "" {
		// Sent through CAS and back here. The return target is rebuilt
		// from constants plus the validated next.
		returnTo := safeRedirectPath(githubJoinURL(next))
		http.Redirect(w, r, githubJoinLoginPath+"?"+url.Values{"next": {returnTo}}.Encode(), http.StatusFound)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	view := struct{ Next, StartPath, ScriptPath string }{Next: next, StartPath: githubJoinStartPath, ScriptPath: githubJoinScriptPath}
	if err := githubJoinLandingTemplate.Execute(w, view); err != nil {
		log.Printf("github join: rendering the landing page: %v", err)
	}
}

func (h *githubJoinHandler) serveScript(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w)
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = io.WriteString(w, githubJoinScript)
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

// writeJoinJSON answers the start route. Errors use the provisioning
// envelope so the page's script, and any later Elm caller, read one shape.
func writeJoinJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("github join: writing response: %v", err)
	}
}

func writeJoinError(w http.ResponseWriter, status int, code string) {
	writeJoinJSON(w, status, map[string]any{"error": map[string]any{"code": code, "retryable": status >= 500 || status == http.StatusTooManyRequests}})
}

func (h *githubJoinHandler) serveStart(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w)
	netID := h.sessions.GetString(r.Context(), "netid")
	if netID == "" {
		writeJoinError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	if !isSameOriginRequest(r) {
		writeJoinError(w, http.StatusForbidden, "cross_site_request")
		return
	}
	if !h.limiter.Allow("netid:"+netID, h.now()) {
		writeJoinError(w, http.StatusTooManyRequests, "too_many_requests")
		return
	}
	var body struct {
		Next string `json:"next"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, githubJoinMaxBodyBytes)).Decode(&body); err != nil {
		writeJoinError(w, http.StatusBadRequest, "invalid_next")
		return
	}
	next, ok := githubJoinNext(body.Next)
	if !ok {
		writeJoinError(w, http.StatusBadRequest, "invalid_next")
		return
	}

	user, found, err := selectUserByNetID(r.Context(), h.db, netID)
	if err != nil {
		log.Printf("github join: looking up %s: %v", netID, err)
		writeJoinError(w, http.StatusBadGateway, "platform_unavailable")
		return
	}
	if !found {
		writeJoinError(w, http.StatusForbidden, "not_enrolled")
		return
	}
	// Students only: the join links an identity and adds the account to
	// the students team, neither of which is for staff. The callback
	// checks again, because a role can change while the authorize screen
	// is open.
	if user.Role != "student" {
		writeJoinError(w, http.StatusForbidden, "not_a_student")
		return
	}

	state, err := newGitHubJoinSecret()
	if err != nil {
		log.Printf("github join: minting state: %v", err)
		writeJoinError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	// PKCE (RFC 7636): the verifier stays in the session, its S256 hash
	// goes to GitHub with the authorization, and the exchange presents the
	// verifier. A code stolen from the callback URL cannot be redeemed by
	// anyone who does not also hold this session.
	codeVerifier, err := newGitHubJoinSecret()
	if err != nil {
		log.Printf("github join: minting the PKCE verifier: %v", err)
		writeJoinError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	redirectURI := (&url.URL{Scheme: getRequestScheme(r), Host: getRequestHost(r), Path: githubJoinCallbackPath}).String()
	pending, err := json.Marshal(githubJoinPending{
		State:        state,
		CodeVerifier: codeVerifier,
		UserID:       user.ID,
		NetID:        netID,
		Next:         next,
		RedirectURI:  redirectURI,
		CreatedAt:    h.now(),
	})
	if err != nil {
		log.Printf("github join: encoding state: %v", err)
		writeJoinError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	h.sessions.Put(r.Context(), sessionKeyGitHubJoin, string(pending))

	// No scope parameter: a GitHub App's user token carries the App's
	// permissions, and asking for OAuth scopes here would be refused or,
	// worse, honoured.
	authorization := url.Values{
		"client_id":             {h.app.clientID},
		"redirect_uri":          {redirectURI},
		"state":                 {state},
		"code_challenge":        {pkceChallenge(codeVerifier)},
		"code_challenge_method": {"S256"},
	}
	writeJoinJSON(w, http.StatusOK, map[string]string{"authorization_url": h.app.authorizeURL + "?" + authorization.Encode()})
}

// newGitHubJoinSecret mints 32 random bytes as base64url, which serves both
// as the state and as a PKCE verifier (43 characters of the RFC 7636
// unreserved set).
func newGitHubJoinSecret() (string, error) {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

// pkceChallenge is the S256 code challenge for a verifier.
func pkceChallenge(verifier string) string {
	digest := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}

// selectUserByNetID reads the caller's row as the service. Not found is a
// state (the netid has a session but no enrollment), not an error.
func selectUserByNetID(ctx context.Context, config FetchJWTConfig, netID string) (provisioningUser, bool, error) {
	query := url.Values{}
	query.Set("netid", "eq."+netID)
	query.Set("select", provisioningUserColumns)
	var users []provisioningUser
	if err := postgrestSelect(ctx, config, config.AuthappJWT, "users", query, &users); err != nil {
		return provisioningUser{}, false, err
	}
	if len(users) != 1 {
		return provisioningUser{}, false, nil
	}
	return users[0], true, nil
}

// ---------------------------------------------------------------------------
// Callback
// ---------------------------------------------------------------------------

// The markers the callback redirects with, as `github_join=<marker>` in the
// query of the page the student returns to. docs/github-join.md lists them.
const (
	joinMarkerOK     = "ok"
	joinMarkerDenied = "denied"
	// joinErrAuthorizationFailed: GitHub reported an error other than a
	// denial, sent no code, or refused the code (expired or already used).
	// Starting again is the remedy.
	joinErrAuthorizationFailed = "authorization_failed"
	// joinErrAppMisconfigured: GitHub refused the join App's own client id
	// or secret. An operator problem, logged as one.
	joinErrAppMisconfigured  = "join_app_misconfigured"
	joinErrGitHubUnavailable = "github_unavailable"
	joinErrGitHubRateLimited = "github_rate_limited"
	// joinErrCredentialRejected: GitHub refused the COURSE credential. An
	// operator problem, logged as one.
	joinErrCredentialRejected  = "github_credential_rejected"
	joinErrIdentityTaken       = "github_identity_taken"
	joinErrIdentityLocked      = "github_identity_locked"
	joinErrPlatformUnavailable = "platform_unavailable"
	// joinErrMembershipNotActive: every call succeeded and GitHub still
	// does not report the student as an active member (or team member).
	// Trying again is safe; the invitation, if any, is still there.
	joinErrMembershipNotActive = "membership_not_active"
)

// redirectToNext sends the browser back to where the join was started
// from, with the marker. next came from the pending state, which start
// validated with githubJoinNext, so this can only ever land on this
// origin. For a page the marker goes in the URL's query; for a client
// route (`/#/…`) it goes in the fragment's own query, which is where the
// Elm client reads it.
func redirectToNext(w http.ResponseWriter, r *http.Request, next string, marker string) {
	http.Redirect(w, r, joinReturnURL(next, marker), http.StatusSeeOther)
}

func joinReturnURL(next string, marker string) string {
	encoded := url.Values{"github_join": {marker}}.Encode()
	if strings.HasPrefix(next, "/#/") {
		separator := "?"
		if strings.Contains(next, "?") {
			separator = "&"
		}
		return next + separator + encoded
	}
	target, err := url.Parse(next)
	if err != nil {
		return repositoriesPagePath + "?" + encoded
	}
	query := target.Query()
	query.Set("github_join", marker)
	target.RawQuery = query.Encode()
	return target.String()
}

// takePending checks the session's outstanding join against this callback
// and consumes it only when the state matches. It answers the request
// itself when the check fails, with a 400 and no redirect, because a
// callback that does not match anything this session started is not one
// to act on in any way -- and it is not one to act on the pending join
// either: a stray or forged callback must not cancel the authorization the
// student is in the middle of. Anything that can never match (nothing
// pending, another user's, expired) is cleared.
func (h *githubJoinHandler) takePending(w http.ResponseWriter, r *http.Request, netID string) (githubJoinPending, bool) {
	raw := h.sessions.GetString(r.Context(), sessionKeyGitHubJoin)
	if raw == "" {
		http.Error(w, "No GitHub authorization is in progress for this session. Start again from the repositories page.", http.StatusBadRequest)
		return githubJoinPending{}, false
	}
	var pending githubJoinPending
	if err := json.Unmarshal([]byte(raw), &pending); err != nil || pending.State == "" || pending.CodeVerifier == "" || pending.NetID != netID {
		h.sessions.Remove(r.Context(), sessionKeyGitHubJoin)
		http.Error(w, "This GitHub authorization does not belong to this session. Start again from the repositories page.", http.StatusBadRequest)
		return githubJoinPending{}, false
	}
	state := r.URL.Query().Get("state")
	if subtle.ConstantTimeCompare([]byte(state), []byte(pending.State)) != 1 {
		http.Error(w, "This GitHub authorization does not match the one this session started. Return to the GitHub tab you were sent to, or start again from the repositories page.", http.StatusBadRequest)
		return githubJoinPending{}, false
	}
	h.sessions.Remove(r.Context(), sessionKeyGitHubJoin)
	if h.now().Sub(pending.CreatedAt) > githubJoinStateLifetime {
		http.Error(w, "This GitHub authorization has expired. Start again from the repositories page.", http.StatusBadRequest)
		return githubJoinPending{}, false
	}
	return pending, true
}

func (h *githubJoinHandler) serveCallback(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w)
	ctx := r.Context()
	netID := h.sessions.GetString(ctx, "netid")
	if netID == "" {
		http.Error(w, "Sign in to the course site, then start again from the repositories page.", http.StatusUnauthorized)
		return
	}
	pending, ok := h.takePending(w, r, netID)
	if !ok {
		return
	}
	next := pending.Next

	// The role is re-read now, not trusted from start: a student whose
	// role changed while they were on GitHub's screen is refused before
	// the code is redeemed, so nothing is linked and no membership call
	// is made for them.
	user, found, err := selectUserByNetID(ctx, h.db, netID)
	if err != nil {
		log.Printf("github join: looking up %s at the callback: %v", netID, err)
		redirectToNext(w, r, next, "error:"+joinErrPlatformUnavailable)
		return
	}
	if !found || user.ID != pending.UserID || user.Role != "student" {
		log.Printf("github join: refusing the callback for %s: not a student, or not the user the state was minted for", netID)
		http.Error(w, "The GitHub join is for students of this course.", http.StatusForbidden)
		return
	}

	query := r.URL.Query()
	if reported := query.Get("error"); reported != "" {
		if reported == "access_denied" {
			log.Printf("github join: %s declined the authorization", netID)
			redirectToNext(w, r, next, joinMarkerDenied)
			return
		}
		// error_description is GitHub's text, not logged: it is not ours
		// and the error code says enough.
		log.Printf("github join: GitHub reported %q for %s", reported, netID)
		redirectToNext(w, r, next, "error:"+joinErrAuthorizationFailed)
		return
	}
	code := query.Get("code")
	if code == "" {
		redirectToNext(w, r, next, "error:"+joinErrAuthorizationFailed)
		return
	}

	// The student's token. This variable is its whole life.
	studentToken, marker := h.exchangeCode(ctx, code, pending)
	if marker != "" {
		redirectToNext(w, r, next, "error:"+marker)
		return
	}
	student := newGitHubClient(h.app.apiBaseURL, githubStaticTokenSource{token: studentToken})

	account, err := student.GetAuthenticatedUser(ctx)
	if err != nil {
		redirectToNext(w, r, next, "error:"+h.githubMarker("student", err))
		return
	}
	if account.ID == 0 || account.Login == "" {
		log.Printf("github join: GET /user for %s answered without an id or login", netID)
		redirectToNext(w, r, next, "error:"+joinErrGitHubUnavailable)
		return
	}

	// Identity first, membership second: a student whose account cannot be
	// linked must not be added to the organization under it, and one whose
	// account is linked keeps that even if the membership step fails and is
	// retried.
	if marker := h.linkIdentity(ctx, pending.UserID, netID, account); marker != "" {
		redirectToNext(w, r, next, "error:"+marker)
		return
	}
	if marker := h.joinOrganization(ctx, netID, student, account.Login); marker != "" {
		redirectToNext(w, r, next, "error:"+marker)
		return
	}
	redirectToNext(w, r, next, joinMarkerOK)
}

// exchangeCode redeems the authorization code for the student's token.
// It returns the token, or the marker to redirect with. GitHub reports
// OAuth refusals as a JSON body with an error code, sometimes with a 200
// and sometimes not, so the body is read for that code whatever the
// status; the code is all that is logged, because the body may carry the
// token. Nothing from the request (code, verifier, secret) is logged.
func (h *githubJoinHandler) exchangeCode(ctx context.Context, code string, pending githubJoinPending) (string, string) {
	form := url.Values{
		"client_id":     {h.app.clientID},
		"client_secret": {h.app.clientSecret},
		"code":          {code},
		"redirect_uri":  {pending.RedirectURI},
		"code_verifier": {pending.CodeVerifier},
	}
	ctx, cancel := context.WithTimeout(ctx, githubRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.app.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		log.Printf("github join: building the token request: %v", err)
		return "", joinErrGitHubUnavailable
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := h.httpClient.Do(req)
	if err != nil {
		log.Printf("github join: token exchange: %v", classifyGitHubTransportError("exchange code", err))
		return "", joinErrGitHubUnavailable
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, githubMaxResponseBody))
	if err != nil {
		log.Printf("github join: token exchange: reading the reply: %v", classifyGitHubTransportError("exchange code", err))
		return "", joinErrGitHubUnavailable
	}
	var reply struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	_ = json.Unmarshal(body, &reply)
	switch reply.Error {
	case "":
	case "incorrect_client_credentials":
		log.Printf("github join: ERROR GitHub refused the join App's client id or secret (%s, status %d)", reply.Error, resp.StatusCode)
		return "", joinErrAppMisconfigured
	default:
		// bad_verification_code (expired, already used, or not ours),
		// redirect_uri_mismatch, and the rest: the student starts again,
		// and the code says which it was.
		log.Printf("github join: token exchange refused the code (%s, status %d)", reply.Error, resp.StatusCode)
		return "", joinErrAuthorizationFailed
	}
	switch {
	case resp.StatusCode == http.StatusOK:
	case resp.StatusCode == http.StatusTooManyRequests:
		log.Printf("github join: token exchange rate limited (status %d)", resp.StatusCode)
		return "", joinErrGitHubRateLimited
	default:
		log.Printf("github join: token exchange answered %d", resp.StatusCode)
		return "", joinErrGitHubUnavailable
	}
	if reply.AccessToken == "" {
		log.Printf("github join: token exchange answered 200 without a token")
		return "", joinErrGitHubUnavailable
	}
	return reply.AccessToken, ""
}

// linkIdentity records the verified account through the service RPC and
// maps its refusals. The same account already linked is fine, verified or
// not; another user's account, or a change away from an account that has
// repositories, is refused by the RPC and reported by name.
func (h *githubJoinHandler) linkIdentity(ctx context.Context, userID int, netID string, account githubUser) string {
	err := postgrestRPC(ctx, h.db, "set_user_github_identity", map[string]any{
		"p_user_id":        userID,
		"p_github_user_id": account.ID,
		"p_github_login":   account.Login,
		"p_verified":       true,
	}, nil)
	switch code := postgrestRaised(err); code {
	case "":
		if err != nil {
			log.Printf("github join: linking %s to GitHub account %d: %v", netID, account.ID, err)
			return joinErrPlatformUnavailable
		}
	case "github_identity_taken":
		log.Printf("github join: GitHub account %d (%s) is linked to someone other than %s", account.ID, account.Login, netID)
		return joinErrIdentityTaken
	case "github_identity_locked":
		log.Printf("github join: %s has repositories under another GitHub account; refused relinking to %d (%s)", netID, account.ID, account.Login)
		return joinErrIdentityLocked
	default:
		log.Printf("github join: linking %s to GitHub account %d: %v", netID, account.ID, err)
		return joinErrPlatformUnavailable
	}
	log.Printf("github join: %s verified as GitHub account %d (%s)", netID, account.ID, account.Login)
	return ""
}

// joinOrganization takes the account from wherever it stands to active
// member of the organization and of the students team. Course credential
// for reading, inviting, and the team add; the student's for accepting.
// Every step is idempotent, so a retry after a partial failure picks up
// where this left off without a second invitation.
func (h *githubJoinHandler) joinOrganization(ctx context.Context, netID string, student *githubClient, login string) string {
	org := h.course.org
	membership, err := h.course.client.GetOrgMembership(ctx, org, login)
	if err != nil {
		return h.githubMarker("course", err)
	}
	if membership == githubMembershipNone {
		membership, err = h.course.client.SetOrgMembership(ctx, org, login)
		if err != nil {
			return h.githubMarker("course", err)
		}
		log.Printf("github join: invited %s (%s) to %s", login, netID, org)
	}
	if membership == githubMembershipPending {
		var confirmed bool
		membership, confirmed, err = student.AcceptOrgMembership(ctx, org)
		if err != nil {
			return h.githubMarker("student", err)
		}
		if !confirmed {
			// 202: queued. Ask, with the course credential, whether it has
			// landed; if not yet, the student clicks again in a moment and
			// the pending membership is accepted or found active then.
			membership, err = h.course.client.GetOrgMembership(ctx, org, login)
			if err != nil {
				return h.githubMarker("course", err)
			}
		}
		log.Printf("github join: %s (%s) accepted membership of %s (now %s)", login, netID, org, membership)
	}
	if membership != githubMembershipActive {
		log.Printf("github join: %s (%s) is %q in %s after the join steps", login, netID, membership, org)
		return joinErrMembershipNotActive
	}
	if h.course.studentsTeamSlug == "" {
		return ""
	}
	teamMembership, err := h.course.client.AddTeamMembership(ctx, org, h.course.studentsTeamSlug, login)
	if err != nil {
		return h.githubMarker("course", err)
	}
	if teamMembership != githubMembershipActive {
		log.Printf("github join: %s (%s) is %q on team %s after the add", login, netID, teamMembership, h.course.studentsTeamSlug)
		return joinErrMembershipNotActive
	}
	return ""
}

// githubMarker maps a client error to a marker. credential says whose
// token the failed call carried, because a refusal means different things
// for the two: the course credential being refused is an operator problem,
// the student's is an authorization to do over.
func (h *githubJoinHandler) githubMarker(credential string, err error) string {
	var ghErr *githubError
	if !errors.As(err, &ghErr) {
		log.Printf("github join: unexpected error from the GitHub client: %v", err)
		return joinErrGitHubUnavailable
	}
	switch ghErr.Kind {
	case githubErrRateLimited:
		log.Printf("github join: %v", ghErr)
		return joinErrGitHubRateLimited
	case githubErrUnauthorized:
		if credential == "course" {
			log.Printf("github join: ERROR GitHub refused the course credential: %v", ghErr)
			return joinErrCredentialRejected
		}
		log.Printf("github join: GitHub refused the student's token: %v", ghErr)
		return joinErrAuthorizationFailed
	default:
		log.Printf("github join: %v", ghErr)
		return joinErrGitHubUnavailable
	}
}
