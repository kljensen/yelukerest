package main

// JWT verification for MCP bearer tokens.
//
// mcpapp accepts internal HS256 JWTs minted with the shared JWT_SECRET but
// with an MCP-specific audience (JWT_MCP_AUDIENCE). Validation mirrors the
// discipline of api.check_request_jwt in the database and authapp's
// validateAuthappJWT: exact issuer, audience membership (string or array),
// exp/iat/nbf, a non-empty jti, a non-empty role, and a subject of the form
// "user:<id>". Tokens minted for the PostgREST audience are rejected.

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
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

type mcpJWTConfig struct {
	Secret   []byte
	Issuer   string
	Audience string
}

// identity is the verified caller identity carried to tool handlers.
type identity struct {
	Subject   string // e.g. "user:42"
	UserID    string // e.g. "42"
	NetID     string // optional netid claim; empty if absent
	Role      string // e.g. "student", "faculty"
	JTI       string
	ExpiresAt time.Time
	// Scopes holds the optional scopes claim. Phase 0 tokens carry no scopes
	// claim, so an empty slice means "scopeless legacy": read-allowed,
	// write-denied (ADR 0001 default-deny for writes). See authorizeScope.
	Scopes []string
	// RawToken is the bearer token exactly as presented by the caller. It is
	// never logged; tools obtain it only through forwardableToken.
	RawToken string
}

// forwardableToken returns the credential tools must forward to PostgREST as
// "Authorization: Bearer ..." so every read runs under the caller's own
// row-level-security context. In phase 0 the MCP bearer token IS the internal
// JWT, so the raw inbound token is forwarded unchanged. When Hydra token
// exchange lands (issue #274) this accessor is the single place to swap the
// inbound access token for a freshly minted internal JWT; tool handlers must
// not reach for RawToken directly.
func (id *identity) forwardableToken() (string, error) {
	if id.RawToken == "" {
		return "", errors.New("no forwardable credential is attached to this caller")
	}
	return id.RawToken, nil
}

// verifyMCPToken validates an HS256 MCP bearer token. Error messages never
// include the token or claim values supplied by the caller.
func verifyMCPToken(token string, config mcpJWTConfig, now time.Time) (*identity, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("token must have three JWT segments")
	}

	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("token header is not base64url")
	}
	var header struct {
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, errors.New("token header is not JSON")
	}
	// Only HS256 is accepted. This rejects alg=none and asymmetric algorithm
	// confusion (e.g. RS256), regardless of what the signature contains.
	if header.Alg != "HS256" {
		return nil, errors.New("token alg must be HS256")
	}

	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, errors.New("token signature is not base64url")
	}
	mac := hmac.New(sha256.New, config.Secret)
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return nil, errors.New("token signature is invalid")
	}

	claims, err := decodeJWTClaims(parts[1])
	if err != nil {
		return nil, err
	}

	if err := requireStringClaim(claims, "iss", config.Issuer); err != nil {
		return nil, err
	}
	if err := requireAudienceClaim(claims, config.Audience); err != nil {
		return nil, err
	}

	exp, err := numericDateClaim(claims, "exp")
	if err != nil {
		return nil, err
	}
	if exp <= now.Unix() {
		return nil, errors.New("token is expired")
	}
	iat, err := numericDateClaim(claims, "iat")
	if err != nil {
		return nil, err
	}
	if iat > now.Add(clockSkewAllowance).Unix() {
		return nil, errors.New("token iat is in the future")
	}
	nbf, err := numericDateClaim(claims, "nbf")
	if err != nil {
		return nil, err
	}
	if nbf > now.Unix() {
		return nil, errors.New("token nbf is in the future")
	}

	jti, err := nonEmptyStringClaim(claims, "jti")
	if err != nil {
		return nil, err
	}
	role, err := nonEmptyStringClaim(claims, "role")
	if err != nil {
		return nil, err
	}
	subject, err := nonEmptyStringClaim(claims, "sub")
	if err != nil {
		return nil, err
	}
	userID, ok := strings.CutPrefix(subject, "user:")
	if !ok || !isAllDigits(userID) {
		return nil, errors.New("token sub claim must have the form user:<id>")
	}

	// netid is optional in phase 0: user JWTs minted by auth.sign_jwt do not
	// carry it, but MCP-audience tokens may.
	netID, _ := claims["netid"].(string)

	return &identity{
		Subject:   subject,
		UserID:    userID,
		NetID:     netID,
		Role:      role,
		JTI:       jti,
		ExpiresAt: time.Unix(exp, 0),
		// The scopes claim is optional and its absence is meaningful (see
		// identity.Scopes); extracting it changes no accept/reject decision.
		Scopes: scopesFromClaims(claims),
	}, nil
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

// newTokenVerifier adapts verifyMCPToken to the go-sdk auth.TokenVerifier
// interface used by auth.RequireBearerToken. The returned error text is sent
// to the client in the 401 body; it never contains token material.
func newTokenVerifier(config mcpJWTConfig) auth.TokenVerifier {
	return func(_ context.Context, token string, _ *http.Request) (*auth.TokenInfo, error) {
		id, err := verifyMCPToken(token, config, time.Now())
		if err != nil {
			return nil, fmt.Errorf("%w: %v", auth.ErrInvalidToken, err)
		}
		return &auth.TokenInfo{
			Expiration: id.ExpiresAt,
			UserID:     id.Subject,
			Scopes:     id.Scopes,
			Extra: map[string]any{
				"user_id": id.UserID,
				"netid":   id.NetID,
				"role":    id.Role,
				"jti":     id.JTI,
				"scopes":  id.Scopes,
				// The raw bearer token, carried so tools can forward the
				// caller's own credential to PostgREST (see
				// identity.forwardableToken). Never logged.
				"raw_token": token,
			},
		}, nil
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
	if value, ok := info.Extra["raw_token"].(string); ok {
		id.RawToken = value
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

func requireAudienceClaim(claims map[string]any, want string) error {
	audience, ok := claims["aud"]
	if !ok {
		return errors.New("token missing aud claim")
	}

	if got, ok := audience.(string); ok {
		if got == want {
			return nil
		}
		return fmt.Errorf("token aud claim must include %q", want)
	}

	if got, ok := audience.([]any); ok {
		for _, item := range got {
			if item == want {
				return nil
			}
		}
	}
	return fmt.Errorf("token aud claim must include %q", want)
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
