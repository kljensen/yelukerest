package main

// JWT verification for MCP bearer tokens.
//
// One token domain reaches /mcp: an OAuth access token issued by the
// authorization server. The JWT header's `alg` selects the path before any
// key material is touched, and only the asymmetric algorithms Hydra can
// advertise have one — RS256 and its siblings are verified against the
// authorization server's JWKS (hydra.go) and then exchanged for an internal
// credential (exchange.go), so the presented token itself never leaves
// mcpapp.
//
// Everything else is refused identically: alg=none, an algorithm we do not
// know, and any symmetric algorithm, including the HS256 the retired phase 0
// bearer token used (issue #322). A caller cannot tell from the refusal which
// of those it hit, and JWT_SECRET no longer opens this door at all.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
)

// clockSkewAllowance tolerates small clock drift between the token minter
// and this service when checking issued-at times.
const clockSkewAllowance = 60 * time.Second

// identity is the verified caller identity carried to tool handlers.
type identity struct {
	Subject   string // e.g. "user:42"
	UserID    string // e.g. "42"
	NetID     string // optional netid claim; empty if absent
	Role      string // e.g. "student", "faculty"
	JTI       string
	ExpiresAt time.Time
	// Scopes holds the scopes the authorization server granted, mapped to the
	// names this server gates on. An empty slice means it granted nothing we
	// recognise, and denies every tool (issue #324). See authorizeScope.
	Scopes []string
	// External marks a caller who presented an OAuth access token. Every
	// caller does since the phase 0 credential class was retired (issue
	// #322), so this is descriptive — it names what a log line or audit row
	// is about — and no authorization decision reads it.
	External bool
	// exchange is the recipe for turning the verified identity into the
	// internal credential tools forward. An identity without one has no
	// credential at all; there is no second way to obtain one.
	exchange *pendingExchange
}

// pendingExchange defers the token exchange until a tool actually needs a
// credential, so protocol traffic that touches no course data (initialize,
// tools/list) mints nothing and writes no audit row.
type pendingExchange struct {
	exchanger *tokenExchanger
	request   exchangeRequest
}

// forwardableToken returns the credential tools must forward to PostgREST as
// "Authorization: Bearer ..." so every read runs under the caller's own
// row-level-security context. There is exactly one way to obtain it: the
// verified identity is exchanged for a freshly minted internal JWT
// (api.issue_user_jwt_for_mcp, cached per netid+client+scopes). The presented
// access token is never forwarded.
//
// Until issue #324 a caller could instead have its own raw token forwarded
// upstream, which is what a phase 0 bearer token was. That credential class is
// gone (issue #322), and with it the second path: an identity with no
// exchange now has no credential, so no request is made.
func (id *identity) forwardableToken(ctx context.Context) (string, error) {
	if id.exchange == nil {
		return "", errors.New("OAuth token exchange is not configured on this deployment")
	}
	minted, err := id.exchange.exchanger.tokenFor(ctx, id.exchange.request)
	if err != nil {
		return "", err
	}
	// The database is authoritative about who the caller is; the claims in
	// the external token are only a hint. Adopting its answer keeps PostgREST
	// filters built from id.UserID correct even if the OAuth token's copy is
	// stale.
	if minted.userID != "" {
		id.UserID = minted.userID
		id.Subject = "user:" + minted.userID
	}
	if minted.netID != "" {
		id.NetID = minted.netID
	}
	if minted.role != "" {
		id.Role = minted.role
	}
	return minted.token, nil
}

// scopesFromClaims extracts the optional scopes claim. Both a "scopes" and an
// OAuth-style "scope" claim are accepted, each as either a JSON array of
// strings or a space-delimited string. A missing or empty claim yields nil.
func scopesFromClaims(claims map[string]any) []string {
	for _, key := range []string{"scopes", "scope"} {
		value, ok := claims[key]
		if !ok {
			continue
		}
		switch typed := value.(type) {
		case string:
			return strings.Fields(typed)
		case []any:
			scopes := make([]string, 0, len(typed))
			for _, item := range typed {
				if s, ok := item.(string); ok && s != "" {
					scopes = append(scopes, s)
				}
			}
			return scopes
		}
	}
	return nil
}

// bearerVerifier routes a bearer token to the OAuth verification path its
// `alg` selects; no other path exists. hydra and exchanger are nil when the
// deployment has no OAuth authorization server configured, in which case no
// token is accepted at all.
type bearerVerifier struct {
	hydra     *hydraVerifier
	exchanger *tokenExchanger
}

// tokenAlg reads the `alg` header without validating anything else. Routing on
// it is safe because the path it selects then pins the algorithms it accepts.
func tokenAlg(token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", errors.New("token must have three JWT segments")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", errors.New("token header is not base64url")
	}
	var header struct {
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return "", errors.New("token header is not JSON")
	}
	if header.Alg == "" {
		return "", errors.New("token header has no alg")
	}
	return header.Alg, nil
}

// verify validates one bearer token and returns the caller identity.
func (v *bearerVerifier) verify(ctx context.Context, token string, now time.Time) (*identity, error) {
	alg, err := tokenAlg(token)
	if err != nil {
		return nil, err
	}
	if !hydraAllowedAlgs[alg] {
		// Includes alg=none and every symmetric algorithm, so an HS256 token
		// — however it was signed — is refused here with the same words an
		// algorithm nobody has heard of gets.
		return nil, errors.New("token alg is not accepted")
	}
	if v.hydra == nil {
		return nil, errors.New("this server does not accept OAuth access tokens")
	}
	id, external, err := v.hydra.verify(ctx, token, now)
	if err != nil {
		return nil, err
	}
	if v.exchanger != nil {
		id.exchange = &pendingExchange{
			exchanger: v.exchanger,
			request: exchangeRequest{
				netID:    id.NetID,
				scopes:   id.Scopes,
				external: external,
				outerExp: id.ExpiresAt,
			},
		}
	}
	return id, nil
}

// newTokenVerifier adapts bearerVerifier to the go-sdk auth.TokenVerifier
// interface used by auth.RequireBearerToken. The returned error text is sent
// to the client in the 401 body; it never contains token material.
func newTokenVerifier(verifier *bearerVerifier) auth.TokenVerifier {
	return func(ctx context.Context, token string, _ *http.Request) (*auth.TokenInfo, error) {
		id, err := verifier.verify(ctx, token, time.Now())
		if err != nil {
			return nil, fmt.Errorf("%w: %v", auth.ErrInvalidToken, err)
		}
		return tokenInfoFromIdentity(id), nil
	}
}

// tokenInfoFromIdentity packs a verified identity into the auth.TokenInfo the
// transport carries to tool handlers; identityFromTokenInfo unpacks it again.
func tokenInfoFromIdentity(id *identity) *auth.TokenInfo {
	return &auth.TokenInfo{
		Expiration: id.ExpiresAt,
		UserID:     id.Subject,
		Scopes:     id.Scopes,
		Extra: map[string]any{
			"user_id":  id.UserID,
			"netid":    id.NetID,
			"role":     id.Role,
			"jti":      id.JTI,
			"scopes":   id.Scopes,
			"external": id.External,
			// The deferred token exchange: the only route to a credential
			// tools may forward. In-process only, since TokenInfo is never
			// serialized, and never logged.
			"exchange": id.exchange,
		},
	}
}

// identityFromTokenInfo reverses newTokenVerifier's packing. The streamable
// HTTP transport forwards the request's auth.TokenInfo to tool handlers via
// mcp.RequestExtra.
func identityFromTokenInfo(info *auth.TokenInfo) *identity {
	id := &identity{Subject: info.UserID, ExpiresAt: info.Expiration}
	if value, ok := info.Extra["user_id"].(string); ok {
		id.UserID = value
	}
	if value, ok := info.Extra["netid"].(string); ok {
		id.NetID = value
	}
	if value, ok := info.Extra["role"].(string); ok {
		id.Role = value
	}
	if value, ok := info.Extra["jti"].(string); ok {
		id.JTI = value
	}
	if value, ok := info.Extra["scopes"].([]string); ok {
		id.Scopes = value
	}
	if value, ok := info.Extra["external"].(bool); ok {
		id.External = value
	}
	if value, ok := info.Extra["exchange"].(*pendingExchange); ok {
		id.exchange = value
	}
	return id
}

func decodeJWTClaims(payloadSegment string) (map[string]any, error) {
	payload, err := base64.RawURLEncoding.DecodeString(payloadSegment)
	if err != nil {
		return nil, errors.New("token payload is not base64url")
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	claims := make(map[string]any)
	if err := decoder.Decode(&claims); err != nil {
		return nil, errors.New("token payload is not JSON")
	}
	return claims, nil
}

func requireStringClaim(claims map[string]any, key string, want string) error {
	got, ok := claims[key].(string)
	if !ok || got == "" {
		return fmt.Errorf("token missing %s claim", key)
	}
	if got != want {
		return fmt.Errorf("token %s claim must be %q", key, want)
	}
	return nil
}

func nonEmptyStringClaim(claims map[string]any, key string) (string, error) {
	got, ok := claims[key].(string)
	if !ok || got == "" {
		return "", fmt.Errorf("token missing %s claim", key)
	}
	return got, nil
}

func numericDateClaim(claims map[string]any, key string) (int64, error) {
	value, ok := claims[key]
	if !ok {
		return 0, fmt.Errorf("token missing %s claim", key)
	}

	number, ok := value.(json.Number)
	if !ok {
		return 0, fmt.Errorf("token %s claim must be numeric", key)
	}
	result, err := number.Int64()
	if err != nil {
		return 0, fmt.Errorf("token %s claim must be an integer", key)
	}
	return result, nil
}

func isAllDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
