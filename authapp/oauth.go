package main

// Hydra delegated login and consent handlers (issue #273).
//
// Ory Hydra owns clients, codes, and tokens but delegates the two
// human-facing steps of the authorization-code flow to us:
// hydra.yml sets urls.login=https://$FQDN/auth/oauth/login and
// urls.consent=https://$FQDN/auth/oauth/consent, so the handlers below
// MUST stay at those paths. Hydra sends the browser there with an
// opaque challenge; we resolve the challenge against Hydra's admin API
// (never trusting anything the browser carries), decide, and PUT an
// accept/reject back, then follow the redirect_to Hydra hands us.
//
// Design rules, all of them load-bearing:
//
//   - Identity comes from the scs/CAS session, never from a form field
//     or query parameter. The subject we accept a login with is the
//     session's netid; the consent subject is cross-checked against it.
//   - Scopes, client identity, and audience come from a fresh admin-API
//     fetch on every request, including the consent POST. Hidden fields
//     are decoration: tampering with them changes nothing that matters.
//   - The consent page is JS-free (Caddy's CSP forbids inline scripts,
//     and headless E2E tests are easier without them) and rendered with
//     html/template so every client-supplied string is escaped.
//   - The displayed client identity leads with the REGISTERED redirect
//     URI origins and client_id. client_name is attacker-chosen at DCR
//     time, so it is shown only as self-reported.
//   - grant_access_token_audience is always the canonical MCP resource
//     URL, and the client's audience allowlist is repaired in place when
//     it is missing it. Per the issue #271 spike, Hydra re-validates the
//     granted audience against that allowlist at REFRESH time: without
//     this, the first token works and every refresh fails with
//     "Requested audience ... has not been whitelisted".
//   - Nothing sensitive is logged: no challenges, no redirect_to values
//     (they carry Hydra's verifier), no codes, no tokens. Client ids and
//     upstream status codes are the most we record.
//
// The admin API is reachable only inside the compose network. It is
// configured with HYDRA_ADMIN_URL (default http://hydra:4445); operators
// who run Hydra elsewhere override that variable. It must never be
// exposed publicly or proxied by Caddy.

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/alexedwards/scs/v2"
)

const (
	oauthLoginPath             = "/auth/oauth/login"
	oauthConsentPath           = "/auth/oauth/consent"
	oauthStylesheetPath        = "/auth/oauth/consent.css"
	hydraAdminMaxResponseBytes = 1 << 20
	oauthConsentMaxBodyBytes   = 64 * 1024
	// sessionKeyConsentForms holds the outstanding consent form tokens,
	// keyed by challenge, as a JSON list bounded to consentFormsKept.
	//
	// This was a single slot, so rendering a consent page invalidated the
	// previous form. That is fine when exactly one page is ever open, and
	// wrong in practice: Safari opened /oauth2/auth twice in the same second
	// during a Claude Desktop connect, the second render overwrote the first
	// token, and clicking Allow produced "this form has expired" on a page the
	// user had just been shown.
	//
	// The bound is what the single slot was protecting: a client cannot grow
	// the session without limit by reloading with fresh challenges, because
	// only the newest few are kept. Each entry is still single-use, so a
	// replayed submission cannot re-grant.
	sessionKeyConsentForms = "oauth_consent_forms"
	// Enough for a browser that duplicates a navigation or the user opening a
	// second tab; small enough that the session cannot be grown meaningfully.
	consentFormsKept = 4
)

// oauthChallengePattern bounds what we will forward to Hydra as a
// challenge; anything else is a probe and is refused before a request
// leaves this process.
//
// The bounds are generous on purpose. Hydra's challenge is not always a
// short opaque id: with an in-memory DSN (the dev stack) it encodes the
// whole authorization request, and a measured login_challenge ran to
// 1168 characters of base64url plus "==" padding. The cap below is well
// clear of that while still refusing something absurd. The charset is
// base64url plus "=" padding: no "/" (so a challenge can never look
// like a path), and no "+" (which a query decoder turns into a space).
const oauthChallengeMaxLen = 8192

var oauthChallengePattern = regexp.MustCompile(`^[A-Za-z0-9._~=-]+$`)

// oauthScopeDescriptions renders a scope in plain language. Unknown
// scopes (a client may request anything) fall back to the raw name,
// escaped by html/template like everything else.
var oauthScopeDescriptions = map[string]string{
	"openid":            "Confirm your NetID and course role to this application.",
	"offline_access":    "Stay connected without signing in again (refresh tokens, up to 30 days).",
	"profile":           "See your name and NetID.",
	"email":             "See your course email address.",
	"course:read":       "Read course materials: meetings, assignment descriptions, and quizzes.",
	"grades:read":       "Read your grades, quiz scores, and grade distributions.",
	"submissions:read":  "Read your own submissions and those your team shares with you.",
	"submissions:write": "Create and change submissions on your behalf, and on your team's.",
}

// oauthWriteScopeMarkers identify scopes that let a client change course
// data. They are never checked by default (ADR 0001 default-deny for
// writes, and the FERPA policy note).
var oauthWriteScopeMarkers = []string{"write", "create", "update", "delete", "admin", "manage"}

// oauthDataCategories is the plain-language list of what an approval can
// expose, required by the policy note in docs/adr/0001-mcp-and-oauth.md.
// It describes the ceiling of the MCP surface, not just the scopes on
// screen, because the point is to tell a student what leaves the course
// app.
var oauthDataCategories = []string{
	"Course materials — meeting schedule, assignment descriptions, and quiz metadata.",
	"Your submitted work — your own submissions and any your team shares with you.",
	"Your grades — assignment and quiz scores, instructor feedback, and grade distributions.",
	"Your directory information — name, NetID, course role, and team.",
}

// ---------------------------------------------------------------------
// Hydra admin API client
// ---------------------------------------------------------------------

// hydraAdminError carries the upstream status so handlers can tell an
// expired challenge (Hydra answers 404/410) from an outage. The message
// deliberately contains no challenge value.
type hydraAdminError struct {
	Operation string
	Status    int
}

func (e *hydraAdminError) Error() string {
	return fmt.Sprintf("hydra admin %s returned status %d", e.Operation, e.Status)
}

// gone reports whether the failure means "this challenge is no longer
// usable" rather than "Hydra is unwell".
func (e *hydraAdminError) gone() bool {
	return e.Status == http.StatusNotFound || e.Status == http.StatusGone || e.Status == http.StatusConflict
}

type hydraAdminClient struct {
	baseURL string
	client  *http.Client
}

func newHydraAdminClient(baseURL string, client *http.Client) *hydraAdminClient {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &hydraAdminClient{baseURL: strings.TrimRight(baseURL, "/"), client: client}
}

func (h *hydraAdminClient) request(ctx context.Context, method string, path string, query url.Values, body any, out any) error {
	endpoint := h.baseURL + path
	if len(query) > 0 {
		endpoint += "?" + query.Encode()
	}

	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encoding hydra admin %s request: %w", path, err)
		}
		reader = bytes.NewReader(encoded)
	}

	request, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return fmt.Errorf("building hydra admin %s request: %w", path, err)
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := h.client.Do(request)
	if err != nil {
		return fmt.Errorf("hydra admin %s unreachable: %w", path, err)
	}
	defer response.Body.Close()

	payload, err := io.ReadAll(io.LimitReader(response.Body, hydraAdminMaxResponseBytes))
	if err != nil {
		return fmt.Errorf("reading hydra admin %s response: %w", path, err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		// The body may echo the challenge back, so it is never logged
		// or wrapped into the error.
		return &hydraAdminError{Operation: path, Status: response.StatusCode}
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(payload, out); err != nil {
		return fmt.Errorf("parsing hydra admin %s response: %w", path, err)
	}
	return nil
}

// hydraClientInfo is the subset of Hydra's OAuth2 client we need. Every
// string in it is client-controlled and must be escaped on output.
type hydraClientInfo struct {
	ClientID     string   `json:"client_id"`
	ClientName   string   `json:"client_name"`
	ClientURI    string   `json:"client_uri"`
	RedirectURIs []string `json:"redirect_uris"`
	Audience     []string `json:"audience"`
}

type hydraLoginRequest struct {
	Challenge         string          `json:"challenge"`
	Skip              bool            `json:"skip"`
	Subject           string          `json:"subject"`
	RequestedScope    []string        `json:"requested_scope"`
	RequestedAudience []string        `json:"requested_access_token_audience"`
	Client            hydraClientInfo `json:"client"`
}

type hydraConsentRequest struct {
	Challenge         string          `json:"challenge"`
	Skip              bool            `json:"skip"`
	Subject           string          `json:"subject"`
	RequestedScope    []string        `json:"requested_scope"`
	RequestedAudience []string        `json:"requested_access_token_audience"`
	Client            hydraClientInfo `json:"client"`
}

type hydraRedirect struct {
	RedirectTo string `json:"redirect_to"`
}

type hydraLoginAccept struct {
	Subject     string `json:"subject"`
	Remember    bool   `json:"remember"`
	RememberFor int    `json:"remember_for"`
}

type hydraConsentSession struct {
	AccessToken map[string]any `json:"access_token,omitempty"`
	IDToken     map[string]any `json:"id_token,omitempty"`
}

type hydraConsentAccept struct {
	GrantScope               []string            `json:"grant_scope"`
	GrantAccessTokenAudience []string            `json:"grant_access_token_audience"`
	Remember                 bool                `json:"remember"`
	RememberFor              int                 `json:"remember_for"`
	Session                  hydraConsentSession `json:"session"`
}

type hydraReject struct {
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

func (h *hydraAdminClient) getLoginRequest(ctx context.Context, challenge string) (*hydraLoginRequest, error) {
	var result hydraLoginRequest
	query := url.Values{"login_challenge": {challenge}}
	if err := h.request(ctx, http.MethodGet, "/admin/oauth2/auth/requests/login", query, nil, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func (h *hydraAdminClient) acceptLogin(ctx context.Context, challenge string, subject string) (string, error) {
	var result hydraRedirect
	query := url.Values{"login_challenge": {challenge}}
	body := hydraLoginAccept{Subject: subject, Remember: false, RememberFor: 0}
	if err := h.request(ctx, http.MethodPut, "/admin/oauth2/auth/requests/login/accept", query, body, &result); err != nil {
		return "", err
	}
	return result.RedirectTo, nil
}

func (h *hydraAdminClient) getConsentRequest(ctx context.Context, challenge string) (*hydraConsentRequest, error) {
	var result hydraConsentRequest
	query := url.Values{"consent_challenge": {challenge}}
	if err := h.request(ctx, http.MethodGet, "/admin/oauth2/auth/requests/consent", query, nil, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func (h *hydraAdminClient) acceptConsent(ctx context.Context, challenge string, body hydraConsentAccept) (string, error) {
	var result hydraRedirect
	query := url.Values{"consent_challenge": {challenge}}
	if err := h.request(ctx, http.MethodPut, "/admin/oauth2/auth/requests/consent/accept", query, body, &result); err != nil {
		return "", err
	}
	return result.RedirectTo, nil
}

func (h *hydraAdminClient) rejectConsent(ctx context.Context, challenge string, reason hydraReject) (string, error) {
	var result hydraRedirect
	query := url.Values{"consent_challenge": {challenge}}
	if err := h.request(ctx, http.MethodPut, "/admin/oauth2/auth/requests/consent/reject", query, reason, &result); err != nil {
		return "", err
	}
	return result.RedirectTo, nil
}

// ensureClientAudience adds the canonical MCP resource to the client's
// audience allowlist when it is missing. The DCR proxy injects it at
// registration (authapp/register.go), so this only fires for clients
// registered before that landed or registered outside the proxy — but
// without it those clients' refreshes fail (issue #271 spike, finding
// 2b). A JSON Patch replace is used because Hydra always materializes
// the field, as an empty array when unset.
func (h *hydraAdminClient) ensureClientAudience(ctx context.Context, client hydraClientInfo, audience string) error {
	if audience == "" || client.ClientID == "" {
		return nil
	}
	if slices.Contains(client.Audience, audience) {
		return nil
	}
	updated := append(append([]string{}, client.Audience...), audience)
	patch := []map[string]any{{"op": "replace", "path": "/audience", "value": updated}}
	path := "/admin/clients/" + url.PathEscape(client.ClientID)
	return h.request(ctx, http.MethodPatch, path, nil, patch, nil)
}

// ---------------------------------------------------------------------
// Handler configuration
// ---------------------------------------------------------------------

type oauthFlowConfig struct {
	// Admin talks to Hydra's admin API (HYDRA_ADMIN_URL).
	Admin *hydraAdminClient
	// MCPAudience is the canonical MCP resource URL granted as the
	// access-token audience. Empty disables audience granting, which
	// leaves tokens mcpapp will refuse — a misconfiguration, logged at
	// startup by main().
	MCPAudience string
	// CASLoginPath is authapp's own CAS entry point (/auth/login). The
	// OAuth login handler bounces unauthenticated users through it with
	// an internal-only `next`.
	CASLoginPath string
	// FetchUser resolves a netid to the course-database user whose id
	// and role become access-token claims. Defaults to fetchUserInfo.
	FetchUser func(netID string) (*UserJWTInfo, error, int)
}

func newOAuthFlowConfig(adminURL string, mcpAudience string, casLoginPath string, jwtConfig FetchJWTConfig) oauthFlowConfig {
	return oauthFlowConfig{
		Admin:        newHydraAdminClient(adminURL, nil),
		MCPAudience:  mcpAudience,
		CASLoginPath: casLoginPath,
		FetchUser: func(netID string) (*UserJWTInfo, error, int) {
			return fetchUserInfo(netID, jwtConfig)
		},
	}
}

// setOAuthPageHeaders applies the no-store and framing protections to
// every OAuth handler response. Caddy sets equivalents for /auth/*;
// authapp repeats them so the protections do not depend on the proxy.
func setOAuthPageHeaders(w http.ResponseWriter) {
	setNoStoreHeaders(w)
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	// A stricter CSP than the site-wide one: the consent page needs a
	// same-origin stylesheet and its own form target, nothing else.
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
}

// challengeFrom pulls and validates a challenge parameter. The value is
// never echoed into an error message or a log line.
func challengeFrom(values url.Values, name string) (string, bool) {
	challenge := strings.TrimSpace(values.Get(name))
	if challenge == "" || len(challenge) > oauthChallengeMaxLen || !oauthChallengePattern.MatchString(challenge) {
		return "", false
	}
	return challenge, true
}

// oauthError writes a terse error page. Bodies never contain challenge
// values, upstream error text, or anything else a client supplied.
func oauthError(w http.ResponseWriter, status int, message string) {
	setOAuthPageHeaders(w)
	http.Error(w, message, status)
}

// ---------------------------------------------------------------------
// Login handler
// ---------------------------------------------------------------------

// getOAuthLoginHandler serves GET /auth/oauth/login, the URL Hydra
// redirects browsers to at the start of an authorization request.
func getOAuthLoginHandler(config oauthFlowConfig, sessionManager *scs.SessionManager) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			oauthError(w, http.StatusMethodNotAllowed, "Method Not Allowed")
			return
		}
		setOAuthPageHeaders(w)

		challenge, ok := challengeFrom(r.URL.Query(), "login_challenge")
		if !ok {
			oauthError(w, http.StatusBadRequest, "Missing or malformed login_challenge")
			return
		}

		loginRequest, err := config.Admin.getLoginRequest(r.Context(), challenge)
		if err != nil {
			writeHydraAdminError(w, "login challenge lookup", err)
			return
		}

		// skip=true means Hydra already holds an authenticated session
		// for this subject; re-prompting would be noise. The subject
		// must be echoed back unchanged — Hydra rejects a different
		// one — so there is no place here for user input.
		if loginRequest.Skip {
			redirectTo, err := config.Admin.acceptLogin(r.Context(), challenge, loginRequest.Subject)
			if err != nil {
				writeHydraAdminError(w, "login accept (skip)", err)
				return
			}
			redirectToHydra(w, r, redirectTo)
			return
		}

		netID := sessionManager.GetString(r.Context(), "netid")
		if netID == "" {
			// Bounce through CAS and come back to this exact URL. The
			// return target is rebuilt from our own constants plus the
			// validated challenge and then re-checked by
			// safeRedirectPath, so it can never leave this origin.
			returnTo := safeRedirectPath(oauthLoginPath + "?" + url.Values{"login_challenge": {challenge}}.Encode())
			casURL := config.CASLoginPath + "?" + url.Values{"next": {returnTo}}.Encode()
			http.Redirect(w, r, casURL, http.StatusFound)
			return
		}

		redirectTo, err := config.Admin.acceptLogin(r.Context(), challenge, netID)
		if err != nil {
			writeHydraAdminError(w, "login accept", err)
			return
		}
		redirectToHydra(w, r, redirectTo)
	})
}

// writeHydraAdminError maps an admin-API failure onto a browser-facing
// status. Nothing from the upstream body reaches the user or the log.
func writeHydraAdminError(w http.ResponseWriter, operation string, err error) {
	var adminErr *hydraAdminError
	if errors.As(err, &adminErr) && adminErr.gone() {
		log.Printf("oauth: %s failed: challenge is unknown or expired (status %d)", operation, adminErr.Status)
		oauthError(w, http.StatusBadRequest, "This login request has expired. Start the connection again from your application.")
		return
	}
	log.Printf("oauth: %s failed: %v", operation, err)
	oauthError(w, http.StatusBadGateway, "The authorization server is unavailable. Try again shortly.")
}

// redirectToHydra follows the redirect_to Hydra returned. The value is
// generated by Hydra itself and carries its verifier, so it is neither
// logged nor validated against a user-supplied allowlist; an empty value
// means Hydra misbehaved.
func redirectToHydra(w http.ResponseWriter, r *http.Request, redirectTo string) {
	if strings.TrimSpace(redirectTo) == "" {
		log.Println("oauth: hydra returned an empty redirect_to")
		oauthError(w, http.StatusBadGateway, "The authorization server returned an invalid response.")
		return
	}
	http.Redirect(w, r, redirectTo, http.StatusSeeOther)
}

// ---------------------------------------------------------------------
// Consent page
// ---------------------------------------------------------------------

type consentScopeView struct {
	Name        string
	Description string
	Checked     bool
	Write       bool
}

type consentPageView struct {
	StylesheetPath  string
	FormAction      string
	Challenge       string
	CSRFToken       string
	NetID           string
	ClientID        string
	ClientName      string
	RedirectOrigins []string
	Scopes          []consentScopeView
	DataCategories  []string
	Audience        string
}

// consentTemplate is JS-free by design: Caddy's CSP forbids inline
// scripts, headless end-to-end tests are simpler without them, and a
// consent decision should not depend on client-side code. All dynamic
// values are escaped by html/template — never build this HTML by
// concatenation.
var consentTemplate = template.Must(template.New("consent").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Authorize application access</title>
<link rel="stylesheet" href="{{.StylesheetPath}}">
</head>
<body>
<main class="consent">
<h1>Authorize application access</h1>

<p class="who">Signed in as <strong>{{.NetID}}</strong>.</p>

<section class="client">
<h2>The application asking for access</h2>
<dl>
<dt>Registered redirect location</dt>
<dd>
{{- if .RedirectOrigins}}
<ul class="origins">
{{- range .RedirectOrigins}}
<li><code>{{.}}</code></li>
{{- end}}
</ul>
{{- else}}
<p class="warn">No redirect location is registered for this application.</p>
{{- end}}
</dd>
<dt>Client ID</dt>
<dd><code>{{.ClientID}}</code></dd>
{{- if .ClientName}}
<dt>Name it reports for itself</dt>
<dd>{{.ClientName}} <span class="note">(self-reported and unverified &mdash; trust the redirect location above, not this name)</span></dd>
{{- end}}
</dl>
<p class="warn">Approve this only if you started a connection from that application yourself. Anything you approve leaves this course app and may be sent on to the third-party AI provider that application uses.</p>
</section>

<section class="data">
<h2>What this application can reach</h2>
<p>Approving access lets it read, on your behalf and limited to what you can already see:</p>
<ul>
{{- range .DataCategories}}
<li>{{.}}</li>
{{- end}}
</ul>
</section>

<form method="POST" action="{{.FormAction}}">
<input type="hidden" name="csrf_token" value="{{.CSRFToken}}">
<input type="hidden" name="consent_challenge" value="{{.Challenge}}">

<section class="scopes">
<h2>Permissions requested</h2>
{{- if .Scopes}}
<ul class="scopelist">
{{- range .Scopes}}
<li class="{{if .Write}}scope-write{{else}}scope-read{{end}}">
<label>
<input type="checkbox" name="grant_scope" value="{{.Name}}"{{if .Checked}} checked{{end}}>
<code>{{.Name}}</code>
{{- if .Write}} <span class="badge">changes your data</span>{{end}}
<span class="desc">{{.Description}}</span>
</label>
</li>
{{- end}}
</ul>
<p class="note">Permissions that change your data start unchecked. Uncheck anything else you would rather not share; the application only receives what stays checked.</p>
{{- else}}
<p>This application requested no permissions.</p>
{{- end}}
</section>

{{- if .Audience}}
<p class="note">Tokens issued here are usable only at <code>{{.Audience}}</code>.</p>
{{- end}}

<div class="actions">
<button type="submit" name="action" value="allow" class="allow">Allow access</button>
<button type="submit" name="action" value="deny" class="deny">Deny</button>
</div>
</form>
</main>
</body>
</html>
`))

// consentStylesheet is served from our own origin because Caddy's CSP
// sets style-src 'self', which forbids inline <style> and style
// attributes.
const consentStylesheet = `:root { color-scheme: light dark; }
body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; line-height: 1.5; margin: 0; padding: 2rem 1rem; }
main.consent { max-width: 42rem; margin: 0 auto; }
h1 { font-size: 1.5rem; }
h2 { font-size: 1.05rem; margin-bottom: 0.25rem; }
section { margin-bottom: 1.75rem; }
dl { margin: 0.25rem 0; }
dt { font-weight: 600; margin-top: 0.5rem; }
dd { margin: 0 0 0 1rem; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }
ul.origins, ul.scopelist { list-style: none; padding-left: 0; }
ul.scopelist li { border: 1px solid rgba(128,128,128,0.4); border-radius: 6px; padding: 0.6rem 0.75rem; margin-bottom: 0.5rem; }
ul.scopelist li.scope-write { border-color: rgba(200,80,0,0.8); }
span.desc { display: block; margin-left: 1.6rem; font-size: 0.9rem; }
span.badge { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; border: 1px solid currentColor; border-radius: 4px; padding: 0 0.3rem; }
span.note, p.note { font-size: 0.85rem; opacity: 0.8; }
p.warn { border-left: 3px solid rgba(200,80,0,0.8); padding-left: 0.75rem; }
div.actions { display: flex; gap: 0.75rem; margin-top: 1.5rem; }
button { font: inherit; padding: 0.55rem 1.1rem; border-radius: 6px; border: 1px solid rgba(128,128,128,0.6); cursor: pointer; }
button.allow { font-weight: 600; }
`

func getOAuthStylesheetHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		_, _ = io.WriteString(w, consentStylesheet)
	})
}

// isWriteScope reports whether a scope grants the ability to change
// course data. Unknown scopes containing a write-ish word are treated as
// writes: the failure mode of guessing wrong is an unchecked box.
func isWriteScope(scope string) bool {
	lower := strings.ToLower(scope)
	for _, marker := range oauthWriteScopeMarkers {
		if strings.Contains(lower, marker) {
			return true
		}
	}
	return false
}

func describeScope(scope string) string {
	if description, ok := oauthScopeDescriptions[scope]; ok {
		return description
	}
	return "Access requested by the application. Approve it only if you recognize it."
}

// buildConsentScopeViews turns Hydra's requested_scope list into the
// checkbox rows. Duplicates and blanks are dropped; read scopes start
// checked, write scopes start unchecked.
func buildConsentScopeViews(requested []string) []consentScopeView {
	views := make([]consentScopeView, 0, len(requested))
	seen := make(map[string]bool, len(requested))
	for _, scope := range requested {
		scope = strings.TrimSpace(scope)
		if scope == "" || seen[scope] {
			continue
		}
		seen[scope] = true
		write := isWriteScope(scope)
		views = append(views, consentScopeView{
			Name:        scope,
			Description: describeScope(scope),
			Checked:     !write,
			Write:       write,
		})
	}
	return views
}

// redirectOriginsFor reduces a client's REGISTERED redirect URIs to
// distinct origins. This — not client_name — is the identity we lead
// with: it is the only client attribute Hydra enforces at redirect time,
// so it is the only one an attacker cannot freely choose.
func redirectOriginsFor(uris []string) []string {
	origins := make([]string, 0, len(uris))
	seen := make(map[string]bool, len(uris))
	for _, raw := range uris {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		origin := raw
		if parsed, err := url.Parse(raw); err == nil && parsed.Scheme != "" {
			if parsed.Host != "" {
				origin = parsed.Scheme + "://" + parsed.Host
			} else {
				// Custom-scheme native redirects (myapp:/callback)
				// have no host; show the whole URI rather than a
				// misleadingly short prefix.
				origin = raw
			}
		}
		if seen[origin] {
			continue
		}
		seen[origin] = true
		origins = append(origins, origin)
	}
	return origins
}

// consentForm is one outstanding consent page: the challenge it was rendered
// for and the token that page carries.
type consentForm struct {
	Challenge string `json:"c"`
	Token     string `json:"t"`
}

func loadConsentForms(r *http.Request, sessionManager *scs.SessionManager) []consentForm {
	raw := sessionManager.GetString(r.Context(), sessionKeyConsentForms)
	if raw == "" {
		return nil
	}
	var forms []consentForm
	if err := json.Unmarshal([]byte(raw), &forms); err != nil {
		// A malformed value is treated as no outstanding forms: the caller
		// then rejects the submission, which is the safe direction.
		return nil
	}
	return forms
}

func storeConsentForms(r *http.Request, sessionManager *scs.SessionManager, forms []consentForm) {
	if len(forms) == 0 {
		sessionManager.Remove(r.Context(), sessionKeyConsentForms)
		return
	}
	encoded, err := json.Marshal(forms)
	if err != nil {
		sessionManager.Remove(r.Context(), sessionKeyConsentForms)
		return
	}
	sessionManager.Put(r.Context(), sessionKeyConsentForms, string(encoded))
}

// rememberConsentForm records the token for a freshly rendered consent page,
// replacing any previous entry for the same challenge and evicting the oldest
// once consentFormsKept is reached.
func rememberConsentForm(r *http.Request, sessionManager *scs.SessionManager, challenge, token string) {
	forms := loadConsentForms(r, sessionManager)
	kept := make([]consentForm, 0, len(forms)+1)
	for _, form := range forms {
		if form.Challenge != challenge {
			kept = append(kept, form)
		}
	}
	kept = append(kept, consentForm{Challenge: challenge, Token: token})
	if len(kept) > consentFormsKept {
		kept = kept[len(kept)-consentFormsKept:]
	}
	storeConsentForms(r, sessionManager, kept)
}

// consumeConsentForm returns the token issued for this challenge and removes
// it, so each rendered form can be submitted exactly once.
func consumeConsentForm(r *http.Request, sessionManager *scs.SessionManager, challenge string) string {
	forms := loadConsentForms(r, sessionManager)
	token := ""
	kept := make([]consentForm, 0, len(forms))
	for _, form := range forms {
		if form.Challenge == challenge {
			token = form.Token
			continue
		}
		kept = append(kept, form)
	}
	storeConsentForms(r, sessionManager, kept)
	return token
}

func newCSRFToken() (string, error) {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

// getOAuthConsentHandler serves GET and POST /auth/oauth/consent.
func getOAuthConsentHandler(config oauthFlowConfig, sessionManager *scs.SessionManager) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet, http.MethodHead:
			serveConsentForm(w, r, config, sessionManager)
		case http.MethodPost:
			serveConsentDecision(w, r, config, sessionManager)
		default:
			w.Header().Set("Allow", "GET, HEAD, POST")
			oauthError(w, http.StatusMethodNotAllowed, "Method Not Allowed")
		}
	})
}

func serveConsentForm(w http.ResponseWriter, r *http.Request, config oauthFlowConfig, sessionManager *scs.SessionManager) {
	setOAuthPageHeaders(w)

	challenge, ok := challengeFrom(r.URL.Query(), "consent_challenge")
	if !ok {
		oauthError(w, http.StatusBadRequest, "Missing or malformed consent_challenge")
		return
	}

	consentRequest, err := config.Admin.getConsentRequest(r.Context(), challenge)
	if err != nil {
		writeHydraAdminError(w, "consent challenge lookup", err)
		return
	}

	netID := sessionManager.GetString(r.Context(), "netid")
	if netID == "" {
		// Consent normally follows login, so a missing session means
		// the cookie expired mid-flow. Re-run CAS and return here.
		returnTo := safeRedirectPath(oauthConsentPath + "?" + url.Values{"consent_challenge": {challenge}}.Encode())
		casURL := config.CASLoginPath + "?" + url.Values{"next": {returnTo}}.Encode()
		http.Redirect(w, r, casURL, http.StatusFound)
		return
	}
	if consentRequest.Subject == "" || consentRequest.Subject != netID {
		// The browser's session identifies a different person than the
		// login step did — or Hydra returned no subject at all, which
		// must also fail closed. Refuse rather than let one account
		// consent on another's behalf.
		log.Printf("oauth: consent subject does not match the session; refusing (client_id=%q)", consentRequest.Client.ClientID)
		oauthError(w, http.StatusForbidden, "This authorization request belongs to a different signed-in user. Sign out and start the connection again.")
		return
	}

	// A remembered consent (remember=true) would arrive with skip set.
	// We never set remember, so this is defensive: honor Hydra's record
	// by granting exactly what was previously agreed.
	if consentRequest.Skip {
		finishConsent(w, r, config, challenge, consentRequest, netID, consentRequest.RequestedScope)
		return
	}

	token, err := newCSRFToken()
	if err != nil {
		log.Println("oauth: generating a consent CSRF token failed:", err)
		oauthError(w, http.StatusInternalServerError, "Internal Server Error")
		return
	}
	rememberConsentForm(r, sessionManager, challenge, token)

	view := consentPageView{
		StylesheetPath:  oauthStylesheetPath,
		FormAction:      oauthConsentPath,
		Challenge:       challenge,
		CSRFToken:       token,
		NetID:           netID,
		ClientID:        consentRequest.Client.ClientID,
		ClientName:      strings.TrimSpace(consentRequest.Client.ClientName),
		RedirectOrigins: redirectOriginsFor(consentRequest.Client.RedirectURIs),
		Scopes:          buildConsentScopeViews(consentRequest.RequestedScope),
		DataCategories:  oauthDataCategories,
		Audience:        config.MCPAudience,
	}

	// Render to a buffer so a template failure cannot emit a partial
	// page with a 200 already on the wire.
	var page bytes.Buffer
	if err := consentTemplate.Execute(&page, view); err != nil {
		log.Println("oauth: rendering the consent page failed:", err)
		oauthError(w, http.StatusInternalServerError, "Internal Server Error")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	if _, err := w.Write(page.Bytes()); err != nil {
		log.Println("oauth: writing the consent page failed:", err)
	}
}

func serveConsentDecision(w http.ResponseWriter, r *http.Request, config oauthFlowConfig, sessionManager *scs.SessionManager) {
	setOAuthPageHeaders(w)

	r.Body = http.MaxBytesReader(w, r.Body, oauthConsentMaxBodyBytes)
	if err := r.ParseForm(); err != nil {
		oauthError(w, http.StatusBadRequest, "Could not read the form submission")
		return
	}

	challenge, ok := challengeFrom(r.PostForm, "consent_challenge")
	if !ok {
		oauthError(w, http.StatusBadRequest, "Missing or malformed consent_challenge")
		return
	}

	// CSRF: the token must match the one issued to THIS session for
	// THIS challenge, and it is single-use. Both slots are cleared
	// before any decision is sent to Hydra, so a replayed submission
	// (back button, duplicated tab) cannot re-grant.
	submittedToken := r.PostForm.Get("csrf_token")
	// Consuming removes this challenge's entry whatever the outcome, so a
	// replayed submission cannot re-grant. Other outstanding forms are left
	// alone: one duplicated navigation must not invalidate the page the user
	// is actually looking at.
	expectedToken := consumeConsentForm(r, sessionManager, challenge)
	tokenMatches := expectedToken != "" &&
		subtle.ConstantTimeCompare([]byte(expectedToken), []byte(submittedToken)) == 1
	if !tokenMatches {
		log.Println("oauth: rejecting a consent submission with a missing, stale, or mismatched CSRF token")
		oauthError(w, http.StatusForbidden, "This form has expired or was not submitted from this page. Start the connection again from your application.")
		return
	}

	netID := sessionManager.GetString(r.Context(), "netid")
	if netID == "" {
		oauthError(w, http.StatusUnauthorized, "Your session has expired. Start the connection again from your application.")
		return
	}

	// Re-fetch: subject, client, and requested scopes come from Hydra
	// on this request, never from the form that was submitted.
	consentRequest, err := config.Admin.getConsentRequest(r.Context(), challenge)
	if err != nil {
		writeHydraAdminError(w, "consent challenge re-fetch", err)
		return
	}
	// An absent subject must fail closed, not skip the check: Hydra still
	// binds the token to the challenge's own subject, so accepting here
	// would mint a token carrying this session's claims for someone else's
	// identity.
	if consentRequest.Subject == "" || consentRequest.Subject != netID {
		log.Printf("oauth: consent POST subject is missing or does not match the session; refusing (client_id=%q)", consentRequest.Client.ClientID)
		oauthError(w, http.StatusForbidden, "This authorization request belongs to a different signed-in user.")
		return
	}

	// Fail closed: anything other than an explicit allow is a denial.
	if r.PostForm.Get("action") != "allow" {
		redirectTo, err := config.Admin.rejectConsent(r.Context(), challenge, hydraReject{
			Error:            "access_denied",
			ErrorDescription: "The user denied access to the requested data.",
		})
		if err != nil {
			writeHydraAdminError(w, "consent reject", err)
			return
		}
		log.Printf("oauth: consent denied by the user (client_id=%q)", consentRequest.Client.ClientID)
		redirectToHydra(w, r, redirectTo)
		return
	}

	finishConsent(w, r, config, challenge, consentRequest, netID, r.PostForm["grant_scope"])
}

// finishConsent grants the intersection of what Hydra requested and what
// the user approved, attaches identity claims, and hands the browser
// back to Hydra.
func finishConsent(
	w http.ResponseWriter,
	r *http.Request,
	config oauthFlowConfig,
	challenge string,
	consentRequest *hydraConsentRequest,
	netID string,
	approved []string,
) {
	granted := intersectScopes(consentRequest.RequestedScope, approved)

	user, err, status := config.FetchUser(netID)
	if err != nil || user == nil {
		log.Printf("oauth: could not resolve the consenting user (status %d): %v", status, err)
		if status == http.StatusForbidden {
			oauthError(w, http.StatusForbidden, "Your account is not enrolled in this course app.")
			return
		}
		oauthError(w, http.StatusBadGateway, "Could not look up your account. Try again shortly.")
		return
	}

	audience := []string{}
	if config.MCPAudience != "" {
		audience = append(audience, config.MCPAudience)
		// Belt and suspenders per the issue #271 spike: the granted
		// audience must also be on the client's allowlist or refresh
		// fails later. A failure here still leaves a working access
		// token, so it is logged rather than fatal.
		if err := config.Admin.ensureClientAudience(r.Context(), consentRequest.Client, config.MCPAudience); err != nil {
			log.Printf("oauth: could not add the MCP audience to the client allowlist (client_id=%q): %v",
				consentRequest.Client.ClientID, err)
		}
	}

	accept := hydraConsentAccept{
		GrantScope:               granted,
		GrantAccessTokenAudience: audience,
		Remember:                 false,
		RememberFor:              0,
		Session: hydraConsentSession{
			// These four names are hydra.yml's allowed_top_level_claims.
			// scopes is space-delimited to match the internal MCP JWT
			// convention (api.issue_user_jwt_for_mcp); mcpapp accepts
			// either form.
			AccessToken: map[string]any{
				"netid":   user.NetID,
				"user_id": user.ID,
				"role":    user.Role,
				"scopes":  strings.Join(granted, " "),
			},
		},
	}

	redirectTo, err := config.Admin.acceptConsent(r.Context(), challenge, accept)
	if err != nil {
		writeHydraAdminError(w, "consent accept", err)
		return
	}
	log.Printf("oauth: consent granted (client_id=%q, scopes=%q)", consentRequest.Client.ClientID, strings.Join(granted, " "))
	redirectToHydra(w, r, redirectTo)
}

// intersectScopes keeps the requested scopes the user approved, in the
// order Hydra requested them. Approving a scope that was never requested
// is impossible by construction, which is what makes the hidden form
// fields harmless.
func intersectScopes(requested []string, approved []string) []string {
	approvedSet := make(map[string]bool, len(approved))
	for _, scope := range approved {
		approvedSet[strings.TrimSpace(scope)] = true
	}
	granted := make([]string, 0, len(requested))
	seen := make(map[string]bool, len(requested))
	for _, scope := range requested {
		scope = strings.TrimSpace(scope)
		if scope == "" || seen[scope] || !approvedSet[scope] {
			continue
		}
		seen[scope] = true
		granted = append(granted, scope)
	}
	return granted
}
