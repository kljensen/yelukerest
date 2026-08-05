package main

// Session-gated MCP bearer-token minting (issue #264).
//
// Phase 0 lets students point a bearer-token MCP client (Claude Code,
// Cursor, VS Code, a script) at /mcp before OAuth lands. The client needs
// a token, and the only credential a browser already holds is the scs
// session cookie, so /auth/mcp-token trades that session for a short
// scope-carrying JWT exactly the way /auth/jwt trades it for a PostgREST
// JWT: session required, per-client rate limit, no-store headers, and no
// upstream error detail in the response body.
//
// The token itself is minted by api.issue_user_jwt_for_mcp, which admits
// only a service credential with role=app and app_name=mcpapp — hence the
// separate MCPAPP_JWT environment variable. Keeping the two credentials
// distinct is the point: either can be revoked without disturbing the
// other, and the mint path writes an audit row naming the caller.
//
// AUDIENCE CAVEAT (issue #264): auth.sign_mcp_user_jwt hardcodes
// aud = settings.get('jwt_audience'), i.e. yelukerest-postgrest. mcpapp
// currently rejects anything whose audience is not yelukerest-mcp. authapp
// holds no signing secret, so it cannot widen the audience on its own and
// this endpoint returns the database's token verbatim. Until either
// mcpapp accepts the PostgREST audience or the database signs an audience
// array containing both names, tokens from this endpoint work against
// /rest/* and are refused at /mcp. See docs/api-client-security.md.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// mcpTokenDefaultTTLSeconds is the lifetime auth.sign_mcp_user_jwt gives
// its tokens. It is only a fallback for the reported expires_in; the real
// value is read from the minted token's exp claim.
const mcpTokenDefaultTTLSeconds = 600

// mcpTokenMaxScopes matches the cardinality cap in
// api.issue_user_jwt_for_mcp, so an over-long request is refused here with
// a useful message instead of a generic upstream error.
const mcpTokenMaxScopes = 16

// mcpScopePattern mirrors the scope regex enforced by
// api.issue_user_jwt_for_mcp. Requests are checked against it before the
// allowlist so a malformed scope never reaches the database.
var mcpScopePattern = regexp.MustCompile(`^[a-z][a-z0-9._:-]{0,63}$`)

// mcpAllowedScopes is the set of scopes this endpoint will mint. Anything
// outside it is refused rather than passed through, so a typo does not
// silently produce a token that grants nothing.
var mcpAllowedScopes = map[string]bool{
	"course:read":       true,
	"grades:read":       true,
	"submissions:read":  true,
	"submissions:write": true,
}

// mcpDefaultScopes are granted when the caller asks for nothing. Read-only
// by design: write scopes must be named explicitly (ADR 0001 default-deny
// for writes).
var mcpDefaultScopes = []string{"course:read", "grades:read", "submissions:read"}

// MCPTokenConfig configures the /auth/mcp-token handler. MCPAppJWT is the
// mcpapp-role service credential; when it is empty the endpoint reports
// 503 rather than failing at startup, so deployments that have not minted
// one keep working.
type MCPTokenConfig struct {
	PostgrestHost string
	PostgrestPort string
	MCPAppJWT     string
}

type mcpTokenResponse struct {
	Token     string   `json:"token"`
	TokenType string   `json:"token_type"`
	ExpiresIn int64    `json:"expires_in"`
	Scopes    []string `json:"scopes"`
}

// mcpMintResult is the single row api.issue_user_jwt_for_mcp returns.
type mcpMintResult struct {
	JWT    string `json:"jwt"`
	UserID int    `json:"user_id"`
	NetID  string `json:"netid"`
	Role   string `json:"role"`
}

func issueUserJWTForMCPURL(config MCPTokenConfig) string {
	endpoint := url.URL{
		Scheme: "http",
		Host:   net.JoinHostPort(config.PostgrestHost, config.PostgrestPort),
		Path:   "/rpc/issue_user_jwt_for_mcp",
	}
	return endpoint.String()
}

// parseRequestedScopes turns the optional `scopes` query parameter into a
// validated, deduplicated scope list. Space and comma separators are both
// accepted: OAuth spells scope lists with spaces, but a space in a query
// string is easy to mangle in a shell, so commas are allowed too. An empty
// request yields the read-only defaults.
func parseRequestedScopes(raw string) ([]string, error) {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ' ' || r == ',' || r == '\t' || r == '\n' || r == '+'
	})
	if len(fields) == 0 {
		return append([]string(nil), mcpDefaultScopes...), nil
	}
	if len(fields) > mcpTokenMaxScopes {
		return nil, fmt.Errorf("at most %d scopes may be requested", mcpTokenMaxScopes)
	}

	seen := make(map[string]bool, len(fields))
	scopes := make([]string, 0, len(fields))
	for _, field := range fields {
		if !mcpScopePattern.MatchString(field) {
			return nil, fmt.Errorf("malformed scope %q", field)
		}
		if !mcpAllowedScopes[field] {
			return nil, fmt.Errorf("unknown scope %q", field)
		}
		if seen[field] {
			continue
		}
		seen[field] = true
		scopes = append(scopes, field)
	}
	return scopes, nil
}

// mintMCPUserJWT calls api.issue_user_jwt_for_mcp with the mcpapp service
// credential. It returns an error plus the status authapp should report;
// upstream response bodies are never propagated.
func mintMCPUserJWT(netID string, scopes []string, config MCPTokenConfig) (*mcpMintResult, error, int) {
	if netID == "" {
		return nil, fmt.Errorf("netid is nil"), http.StatusUnauthorized
	}
	if config.MCPAppJWT == "" {
		return nil, fmt.Errorf("MCPAPP_JWT is not configured"), http.StatusServiceUnavailable
	}

	// p_external records who asked for the mint in the audit trail. It
	// grants nothing; the identity that matters is p_netid, which comes
	// from the server-side session.
	requestBody, err := json.Marshal(map[string]any{
		"p_netid":  netID,
		"p_scopes": scopes,
		"p_external": map[string]string{
			"iss":       "authapp",
			"client_id": "authapp:/auth/mcp-token",
		},
	})
	if err != nil {
		return nil, fmt.Errorf("error creating mcp token request body: %v", err), http.StatusInternalServerError
	}

	req, err := http.NewRequest("POST", issueUserJWTForMCPURL(config), bytes.NewReader(requestBody))
	if err != nil {
		return nil, fmt.Errorf("error creating request: %v", err), http.StatusInternalServerError
	}
	req.Header.Set("Authorization", "Bearer "+config.MCPAppJWT)
	req.Header.Set("Accept", "application/vnd.pgrst.object+json")
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("postgrest unavailable: %v", err), http.StatusBadGateway
	}
	defer resp.Body.Close()

	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("error reading response: %v", err), http.StatusInternalServerError
	}

	if resp.StatusCode != http.StatusOK {
		switch resp.StatusCode {
		case http.StatusNotAcceptable, http.StatusNotFound:
			// No row: the netid is unknown to the course database.
			return nil, fmt.Errorf("user is not authorized"), http.StatusForbidden
		case http.StatusForbidden:
			// insufficient_privilege: the user's role is not mintable
			// for MCP, or the service credential is not app_name=mcpapp.
			return nil, fmt.Errorf("mcp token minting refused by policy"), http.StatusForbidden
		case http.StatusUnauthorized:
			return nil, fmt.Errorf("mcpapp service token rejected by postgrest"), http.StatusBadGateway
		case http.StatusBadRequest:
			// Our own parameters were rejected; scope validation above
			// should have caught this, so treat it as an authapp bug.
			return nil, fmt.Errorf("postgrest rejected the mcp mint parameters"), http.StatusInternalServerError
		default:
			return nil, fmt.Errorf("unexpected postgrest status %s", resp.Status), http.StatusBadGateway
		}
	}

	var result mcpMintResult
	if err := json.Unmarshal(responseBody, &result); err != nil {
		return nil, fmt.Errorf("error parsing mcp token response: %v", err), http.StatusBadGateway
	}
	if result.JWT == "" {
		return nil, fmt.Errorf("user is not authorized"), http.StatusForbidden
	}
	return &result, nil, http.StatusOK
}

// getMCPTokenHandler serves GET /auth/mcp-token.
//
// GET rather than POST, deliberately. The endpoint is a read of a derived
// credential, it has no request body, and it matches its siblings
// /auth/me and /auth/jwt so one session-middleware story covers all
// three. The usual CSRF objection to a state-changing GET does not bite:
// the response is JSON with no CORS headers, so a cross-site page can
// cause the request but cannot read the token, and the only state it
// changes is an append-only audit row.
func getMCPTokenHandler(config MCPTokenConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		setNoStoreHeaders(w)

		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}

		netID, _ := r.Context().Value("netid").(string)
		if netID == "" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		if config.MCPAppJWT == "" {
			log.Println("/auth/mcp-token: MCPAPP_JWT is not configured; refusing to mint")
			http.Error(w, "MCP token issuance is not configured on this deployment", http.StatusServiceUnavailable)
			return
		}

		scopes, err := parseRequestedScopes(r.URL.Query().Get("scopes"))
		if err != nil {
			// The scope text came from the caller, so echoing it leaks
			// nothing they do not already know.
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		result, err, statusCode := mintMCPUserJWT(netID, scopes, config)
		if err != nil {
			log.Printf("Error minting MCP token: %v", err)
			http.Error(w, http.StatusText(statusCode), statusCode)
			return
		}

		response := mcpTokenResponse{
			Token:     result.JWT,
			TokenType: "Bearer",
			ExpiresIn: mcpTokenExpiresIn(result.JWT, time.Now()),
			Scopes:    mcpTokenScopes(result.JWT, scopes),
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(encoded)
	}
}

// mcpTokenExpiresIn reports the minted token's remaining lifetime in
// seconds, read from its own exp claim so the client never has to guess
// at the database's TTL. Falls back to the documented default when the
// claim cannot be read.
func mcpTokenExpiresIn(token string, now time.Time) int64 {
	claims, err := decodeJWTClaims(token, "mcp token")
	if err != nil {
		return mcpTokenDefaultTTLSeconds
	}
	exp, err := numericDateClaim(claims, "mcp token", "exp")
	if err != nil {
		return mcpTokenDefaultTTLSeconds
	}
	remaining := exp - now.Unix()
	if remaining < 0 {
		return 0
	}
	return remaining
}

// mcpTokenScopes reports the scopes actually carried by the minted token
// (a space-separated `scopes` claim), falling back to what was requested.
func mcpTokenScopes(token string, requested []string) []string {
	claims, err := decodeJWTClaims(token, "mcp token")
	if err != nil {
		return requested
	}
	granted, ok := claims["scopes"].(string)
	if !ok {
		return requested
	}
	fields := strings.Fields(granted)
	if len(fields) == 0 {
		return requested
	}
	return fields
}
