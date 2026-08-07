package main

// Connected applications: see what has access to your coursework, and take it
// back (issue #277).
//
// "Disconnect" has to mean more than forgetting a remembered consent, and it
// takes three writes in one request because no single one of them is enough:
//
//  1. Hydra's consent sessions for (subject, client) are revoked. This kills
//     the refresh token immediately — verified: a refresh straight afterwards
//     comes back invalid_grant — so the application cannot mint itself a new
//     access token.
//  2. A row is recorded in data.mcp_grant_revocation. This is what stops the
//     access token the application is *already holding*. mcpapp verifies those
//     offline against Hydra's JWKS, so nothing about step 1 reaches it; what
//     does reach it is that every few minutes it must exchange that token for
//     a fresh internal credential, and api.issue_user_jwt_for_mcp refuses once
//     this row exists. Without it, disconnect would leave up to an hour of
//     working access behind.
//  3. The same row is the audit trail, which is why it is append-only.
//
// The grace period that remains is the internal credential's own lifetime plus
// mcpapp's exchange cache — minutes, not the hour a bare Hydra revocation
// would leave. docs/hydra.md states it.

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/alexedwards/scs/v2"
)

const (
	connectedAppsPath = "/auth/connected-apps"
	// sessionKeyConnectedAppsCSRF holds the token minted with the page and
	// required back on the disconnect POST.
	sessionKeyConnectedAppsCSRF = "connected_apps_csrf"
)

// connectedApp is one application a student has authorized, as shown to them.
type connectedApp struct {
	ClientID   string   `json:"client_id"`
	ClientName string   `json:"client_name"`
	ClientURI  string   `json:"client_uri,omitempty"`
	Scopes     []string `json:"scopes"`
	// LastActivity is Hydra's handled_at for the most recent consent, which is
	// the last time the user actually approved something for this client —
	// not the last API call, which Hydra does not track.
	LastActivity string `json:"last_activity,omitempty"`
}

// hydraGrantedConsent is the shape Hydra returns from
// GET /admin/oauth2/auth/sessions/consent. Only the fields shown to the user
// are decoded. (hydraConsentSession is a different thing: the session payload
// authapp *sends* when accepting a consent.)
type hydraGrantedConsent struct {
	GrantScope     []string `json:"grant_scope"`
	HandledAt      string   `json:"handled_at"`
	ConsentRequest struct {
		Subject string `json:"subject"`
		Client  struct {
			ClientID   string `json:"client_id"`
			ClientName string `json:"client_name"`
			ClientURI  string `json:"client_uri"`
		} `json:"client"`
	} `json:"consent_request"`
}

// listConnectedApps asks Hydra what the subject has authorized and folds the
// consent sessions into one entry per client. A client the user consented to
// several times has several sessions; they think of it as one application.
func listConnectedApps(ctx context.Context, admin *hydraAdminClient, subject string) ([]connectedApp, error) {
	var sessions []hydraGrantedConsent
	query := url.Values{}
	query.Set("subject", subject)
	if err := admin.request(ctx, http.MethodGet, "/admin/oauth2/auth/sessions/consent", query, nil, &sessions); err != nil {
		var adminErr *hydraAdminError
		// Hydra answers 404/410 when the subject has never consented to
		// anything, which is an empty list rather than a failure.
		if asHydraAdminError(err, &adminErr) && (adminErr.Status == http.StatusNotFound || adminErr.gone()) {
			return nil, nil
		}
		return nil, err
	}

	byClient := map[string]*connectedApp{}
	for _, session := range sessions {
		client := session.ConsentRequest.Client
		if client.ClientID == "" {
			continue
		}
		entry, seen := byClient[client.ClientID]
		if !seen {
			entry = &connectedApp{
				ClientID:   client.ClientID,
				ClientName: client.ClientName,
				ClientURI:  client.ClientURI,
			}
			byClient[client.ClientID] = entry
		}
		entry.Scopes = mergeScopes(entry.Scopes, session.GrantScope)
		if session.HandledAt > entry.LastActivity {
			// RFC 3339 timestamps sort lexically, so this picks the latest.
			entry.LastActivity = session.HandledAt
		}
	}

	apps := make([]connectedApp, 0, len(byClient))
	for _, entry := range byClient {
		if entry.ClientName == "" {
			entry.ClientName = entry.ClientID
		}
		sort.Strings(entry.Scopes)
		apps = append(apps, *entry)
	}
	sort.Slice(apps, func(i, j int) bool {
		if apps[i].LastActivity != apps[j].LastActivity {
			// Most recently used first: that is what a person is looking for.
			return apps[i].LastActivity > apps[j].LastActivity
		}
		return apps[i].ClientName < apps[j].ClientName
	})
	return apps, nil
}

func mergeScopes(existing []string, incoming []string) []string {
	seen := map[string]bool{}
	for _, scope := range existing {
		seen[scope] = true
	}
	for _, scope := range incoming {
		if scope != "" && !seen[scope] {
			seen[scope] = true
			existing = append(existing, scope)
		}
	}
	return existing
}

// revokeConnectedApp performs the disconnect.
//
// The database row goes first, and the order matters. Each write can fail
// independently, so the question is which half-done state is survivable:
//
//   - Row written, Hydra revocation fails: the access token the application
//     holds is already dead (the mint check sees the row), the application is
//     still listed, and the user can press Disconnect again. Recoverable.
//   - Hydra revoked first, row fails: refresh is dead but the access token
//     keeps working for its remaining hour, and the application has vanished
//     from the list — so the user cannot retry the thing that would stop it.
//     Not recoverable, and the page would have told them they were safe.
//
// So the durable stop is written first and Hydra second, and any failure is
// reported rather than swallowed.
func revokeConnectedApp(ctx context.Context, config oauthFlowConfig, jwtConfig FetchJWTConfig, subject string, app connectedApp) error {
	if err := recordGrantRevocation(ctx, jwtConfig, subject, app); err != nil {
		return err
	}

	query := url.Values{}
	query.Set("subject", subject)
	query.Set("client", app.ClientID)
	query.Set("all", "false")
	query.Set("trigger_backchannel_logout", "false")
	if err := config.Admin.request(ctx, http.MethodDelete, "/admin/oauth2/auth/sessions/consent", query, nil, nil); err != nil {
		var adminErr *hydraAdminError
		// Already gone is the desired end state, not an error to show.
		if !asHydraAdminError(err, &adminErr) || !(adminErr.Status == http.StatusNotFound || adminErr.gone()) {
			return fmt.Errorf("revoking consent at hydra: %w", err)
		}
	}
	return nil
}

// recordGrantRevocation writes the row that stops an access token already in
// the wild. A failure here is reported, because a disconnect that only
// revoked at Hydra leaves working access behind and the user must know.
func recordGrantRevocation(ctx context.Context, jwtConfig FetchJWTConfig, netID string, app connectedApp) error {
	payload, err := json.Marshal(map[string]any{
		"netid":       netID,
		"client_id":   app.ClientID,
		"client_name": app.ClientName,
		"scopes":      strings.Join(app.Scopes, " "),
	})
	if err != nil {
		return fmt.Errorf("encoding the revocation record: %w", err)
	}
	endpoint := postgrestRPCURL(jwtConfig, "record_mcp_grant_revocation")
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(payload)))
	if err != nil {
		return fmt.Errorf("building the revocation request: %w", err)
	}
	request.Header.Set("Authorization", "Bearer "+jwtConfig.AuthappJWT)
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("recording the revocation: %w", err)
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<16))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("recording the revocation: postgrest returned %s", response.Status)
	}
	return nil
}

// getConnectedAppsHandler serves the list and the disconnect action for the
// signed-in user. It is session-authenticated like the rest of /auth: there is
// no bearer-token path, because an application must not be able to disconnect
// another application on the user's behalf.
func getConnectedAppsHandler(config oauthFlowConfig, jwtConfig FetchJWTConfig, sessionManager *scs.SessionManager) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		netID := sessionManager.GetString(r.Context(), "netid")
		if netID == "" {
			http.Error(w, "not signed in", http.StatusUnauthorized)
			return
		}

		switch r.Method {
		case http.MethodGet:
			serveConnectedApps(w, r, config, sessionManager, netID)
		case http.MethodPost:
			serveDisconnect(w, r, config, jwtConfig, sessionManager, netID)
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
}

func serveConnectedApps(w http.ResponseWriter, r *http.Request, config oauthFlowConfig, sessionManager *scs.SessionManager, netID string) {
	apps, err := listConnectedApps(r.Context(), config.Admin, netID)
	if err != nil {
		log.Printf("connected apps: listing for %q failed: %v", netID, err)
		http.Error(w, "could not read your connected applications", http.StatusBadGateway)
		return
	}

	if wantsJSON(r) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(map[string]any{"connected_apps": apps})
		return
	}

	token, err := newCSRFToken()
	if err != nil {
		http.Error(w, "could not prepare the page", http.StatusInternalServerError)
		return
	}
	sessionManager.Put(r.Context(), sessionKeyConnectedAppsCSRF, token)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := connectedAppsTemplate.Execute(w, map[string]any{
		"NetID":     netID,
		"Apps":      apps,
		"CSRFToken": token,
		"Notice":    r.URL.Query().Get("notice"),
	}); err != nil {
		log.Printf("connected apps: rendering failed: %v", err)
	}
}

func serveDisconnect(w http.ResponseWriter, r *http.Request, config oauthFlowConfig, jwtConfig FetchJWTConfig, sessionManager *scs.SessionManager, netID string) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "malformed form", http.StatusBadRequest)
		return
	}

	expected := sessionManager.GetString(r.Context(), sessionKeyConnectedAppsCSRF)
	submitted := r.PostForm.Get("csrf_token")
	if expected == "" || subtle.ConstantTimeCompare([]byte(expected), []byte(submitted)) != 1 {
		http.Error(w, "this form has expired; reload the page and try again", http.StatusForbidden)
		return
	}
	// One token, one disconnect: a replayed form cannot cut off a second
	// application the user did not choose.
	sessionManager.Remove(r.Context(), sessionKeyConnectedAppsCSRF)

	clientID := strings.TrimSpace(r.PostForm.Get("client_id"))
	if clientID == "" {
		http.Error(w, "no application was named", http.StatusBadRequest)
		return
	}

	// Take the details from what the user actually has, so a forged form
	// cannot record a revocation naming an application they never authorized,
	// and cannot disconnect on behalf of someone else.
	apps, err := listConnectedApps(r.Context(), config.Admin, netID)
	if err != nil {
		log.Printf("connected apps: listing for %q failed: %v", netID, err)
		http.Error(w, "could not read your connected applications", http.StatusBadGateway)
		return
	}
	var target *connectedApp
	for i := range apps {
		if apps[i].ClientID == clientID {
			target = &apps[i]
			break
		}
	}
	if target == nil {
		http.Error(w, "that application is not connected to your account", http.StatusNotFound)
		return
	}

	if err := revokeConnectedApp(r.Context(), config, jwtConfig, netID, *target); err != nil {
		log.Printf("connected apps: disconnecting %q for %q failed: %v", clientID, netID, err)
		http.Error(w, "could not fully disconnect that application; try again", http.StatusBadGateway)
		return
	}
	log.Printf("connected_apps_disconnect netid=%q client_id=%q", netID, clientID)

	if wantsJSON(r) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"disconnected": clientID,
			"grace_note":   "Access already granted stops within a few minutes; refreshing is refused immediately.",
		})
		return
	}
	http.Redirect(w, r, connectedAppsPath+"?notice="+url.QueryEscape("Disconnected "+target.ClientName), http.StatusSeeOther)
}

func wantsJSON(r *http.Request) bool {
	accept := r.Header.Get("Accept")
	return strings.Contains(accept, "application/json") && !strings.Contains(accept, "text/html")
}

// asHydraAdminError unwraps a hydraAdminError, if that is what this is.
func asHydraAdminError(err error, target **hydraAdminError) bool {
	for err != nil {
		if typed, ok := err.(*hydraAdminError); ok {
			*target = typed
			return true
		}
		unwrapper, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = unwrapper.Unwrap()
	}
	return false
}

// The page is deliberately JS-free, like the consent page it complements: it
// is reached from a browser session, it does one thing, and it must work in
// whatever the student is using.
var connectedAppsTemplate = template.Must(template.New("connected-apps").Funcs(template.FuncMap{
	"friendlyTime": func(value string) string {
		parsed, err := time.Parse(time.RFC3339, value)
		if err != nil {
			return value
		}
		return parsed.Format("2 January 2006, 15:04 MST")
	},
}).Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connected applications</title>
<link rel="stylesheet" href="/auth/oauth/consent.css">
</head>
<body>
<main class="card">
<h1>Connected applications</h1>
<p class="subtitle">Signed in as {{.NetID}}</p>
{{if .Notice}}<p class="notice">{{.Notice}}</p>{{end}}
{{if .Apps}}
<p>These applications can reach your course data using your account. Disconnect
anything you do not recognise or no longer use.</p>
<ul class="apps">
{{range .Apps}}
<li class="app">
  <div class="app-name">{{.ClientName}}</div>
  {{if .ClientURI}}<div class="app-uri">{{.ClientURI}}</div>{{end}}
  <div class="app-scopes">Can: {{range $index, $scope := .Scopes}}{{if $index}}, {{end}}{{$scope}}{{end}}</div>
  {{if .LastActivity}}<div class="app-when">Last approved {{friendlyTime .LastActivity}}</div>{{end}}
  <form method="post" action="` + connectedAppsPath + `">
    <input type="hidden" name="csrf_token" value="{{$.CSRFToken}}">
    <input type="hidden" name="client_id" value="{{.ClientID}}">
    <button type="submit" class="deny">Disconnect</button>
  </form>
</li>
{{end}}
</ul>
<p class="fine-print">Disconnecting stops the application from getting new
access straight away. Access it already holds stops working within a few
minutes.</p>
{{else}}
<p>No applications are connected to your account.</p>
{{end}}
</main>
</body>
</html>
`))
