package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const testSecret = "reallyreallyreallylongsecretkey"

var testNow = time.Unix(1_700_000_000, 0)

func testJWTConfig() mcpJWTConfig {
	return mcpJWTConfig{
		Secret:   []byte(testSecret),
		Issuer:   "yelukerest",
		Audience: "yelukerest-mcp",
	}
}

func validClaims() map[string]any {
	return map[string]any{
		"iss":     "yelukerest",
		"aud":     "yelukerest-mcp",
		"sub":     "user:42",
		"user_id": 42,
		"role":    "student",
		"jti":     "0b6f1625-3f39-4a12-9c4e-9ce67a9b6f37",
		"iat":     testNow.Unix() - 60,
		"nbf":     testNow.Unix() - 60,
		"exp":     testNow.Unix() + 3600,
	}
}

// signTestToken builds a JWT with the given header and claims, signed with
// HMAC-SHA256 over the given secret.
func signTestToken(t *testing.T, header map[string]any, claims map[string]any, secret string) string {
	t.Helper()

	headerBytes, err := json.Marshal(header)
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	claimsBytes, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal claims: %v", err)
	}
	signingInput := base64.RawURLEncoding.EncodeToString(headerBytes) + "." + base64.RawURLEncoding.EncodeToString(claimsBytes)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signingInput))
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func hs256Header() map[string]any {
	return map[string]any{"alg": "HS256", "typ": "JWT"}
}

func TestVerifyMCPTokenValid(t *testing.T) {
	token := signTestToken(t, hs256Header(), validClaims(), testSecret)

	id, err := verifyMCPToken(token, testJWTConfig(), testNow)
	if err != nil {
		t.Fatalf("verifyMCPToken error = %v", err)
	}
	if id.Subject != "user:42" {
		t.Fatalf("Subject = %q", id.Subject)
	}
	if id.UserID != "42" {
		t.Fatalf("UserID = %q", id.UserID)
	}
	if id.Role != "student" {
		t.Fatalf("Role = %q", id.Role)
	}
	if id.JTI == "" {
		t.Fatal("JTI is empty")
	}
	if id.NetID != "" {
		t.Fatalf("NetID = %q, want empty", id.NetID)
	}
	if got := id.ExpiresAt.Unix(); got != testNow.Unix()+3600 {
		t.Fatalf("ExpiresAt = %d", got)
	}
}

func TestVerifyMCPTokenNetIDClaim(t *testing.T) {
	claims := validClaims()
	claims["netid"] = "abc123"
	token := signTestToken(t, hs256Header(), claims, testSecret)

	id, err := verifyMCPToken(token, testJWTConfig(), testNow)
	if err != nil {
		t.Fatalf("verifyMCPToken error = %v", err)
	}
	if id.NetID != "abc123" {
		t.Fatalf("NetID = %q", id.NetID)
	}
}

func TestVerifyMCPTokenAudienceArray(t *testing.T) {
	claims := validClaims()
	claims["aud"] = []string{"something-else", "yelukerest-mcp"}
	token := signTestToken(t, hs256Header(), claims, testSecret)

	if _, err := verifyMCPToken(token, testJWTConfig(), testNow); err != nil {
		t.Fatalf("verifyMCPToken error = %v", err)
	}
}

func TestVerifyMCPTokenRejections(t *testing.T) {
	tests := []struct {
		name    string
		header  map[string]any
		mutate  func(map[string]any)
		secret  string
		wantErr string
	}{
		{
			name:    "wrong audience",
			mutate:  func(c map[string]any) { c["aud"] = "wrong-audience" },
			wantErr: "aud",
		},
		{
			name:    "postgrest audience token",
			mutate:  func(c map[string]any) { c["aud"] = "yelukerest-postgrest" },
			wantErr: "aud",
		},
		{
			name:    "audience array without mcp",
			mutate:  func(c map[string]any) { c["aud"] = []string{"yelukerest-postgrest"} },
			wantErr: "aud",
		},
		{
			name:    "missing audience",
			mutate:  func(c map[string]any) { delete(c, "aud") },
			wantErr: "aud",
		},
		{
			name:    "expired",
			mutate:  func(c map[string]any) { c["exp"] = testNow.Unix() - 1 },
			wantErr: "expired",
		},
		{
			name:    "exp equal to now",
			mutate:  func(c map[string]any) { c["exp"] = testNow.Unix() },
			wantErr: "expired",
		},
		{
			name:    "missing exp",
			mutate:  func(c map[string]any) { delete(c, "exp") },
			wantErr: "exp",
		},
		{
			name:    "non-numeric exp",
			mutate:  func(c map[string]any) { c["exp"] = "tomorrow" },
			wantErr: "exp",
		},
		{
			name:    "missing iat",
			mutate:  func(c map[string]any) { delete(c, "iat") },
			wantErr: "iat",
		},
		{
			name:    "missing nbf",
			mutate:  func(c map[string]any) { delete(c, "nbf") },
			wantErr: "nbf",
		},
		{
			name:    "nbf in future",
			mutate:  func(c map[string]any) { c["nbf"] = testNow.Unix() + 300 },
			wantErr: "nbf",
		},
		{
			name:    "missing jti",
			mutate:  func(c map[string]any) { delete(c, "jti") },
			wantErr: "jti",
		},
		{
			name:    "empty jti",
			mutate:  func(c map[string]any) { c["jti"] = "" },
			wantErr: "jti",
		},
		{
			name:    "missing role",
			mutate:  func(c map[string]any) { delete(c, "role") },
			wantErr: "role",
		},
		{
			name:    "missing sub",
			mutate:  func(c map[string]any) { delete(c, "sub") },
			wantErr: "sub",
		},
		{
			name:    "app subject",
			mutate:  func(c map[string]any) { c["sub"] = "app:authapp" },
			wantErr: "sub",
		},
		{
			name:    "subject without id",
			mutate:  func(c map[string]any) { c["sub"] = "user:" },
			wantErr: "sub",
		},
		{
			name:    "subject with non-numeric id",
			mutate:  func(c map[string]any) { c["sub"] = "user:abc" },
			wantErr: "sub",
		},
		{
			name:    "missing issuer",
			mutate:  func(c map[string]any) { delete(c, "iss") },
			wantErr: "iss",
		},
		{
			name:    "wrong issuer",
			mutate:  func(c map[string]any) { c["iss"] = "someone-else" },
			wantErr: "iss",
		},
		{
			name:    "alg none",
			header:  map[string]any{"alg": "none", "typ": "JWT"},
			wantErr: "alg",
		},
		{
			name:    "alg RS256 confusion",
			header:  map[string]any{"alg": "RS256", "typ": "JWT"},
			wantErr: "alg",
		},
		{
			name:    "alg lowercase hs256",
			header:  map[string]any{"alg": "hs256", "typ": "JWT"},
			wantErr: "alg",
		},
		{
			name:    "wrong secret",
			secret:  "a-different-secret-entirely",
			wantErr: "signature",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			header := tt.header
			if header == nil {
				header = hs256Header()
			}
			claims := validClaims()
			if tt.mutate != nil {
				tt.mutate(claims)
			}
			secret := tt.secret
			if secret == "" {
				secret = testSecret
			}
			token := signTestToken(t, header, claims, secret)

			_, err := verifyMCPToken(token, testJWTConfig(), testNow)
			if err == nil {
				t.Fatal("expected error")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("error = %q, want it to mention %q", err, tt.wantErr)
			}
			if strings.Contains(err.Error(), token) {
				t.Fatalf("error leaks the token: %q", err)
			}
		})
	}
}

func TestVerifyMCPTokenAlgNoneEmptySignature(t *testing.T) {
	// An alg=none token with an empty signature segment must be rejected.
	headerBytes, _ := json.Marshal(map[string]any{"alg": "none", "typ": "JWT"})
	claimsBytes, _ := json.Marshal(validClaims())
	token := base64.RawURLEncoding.EncodeToString(headerBytes) + "." + base64.RawURLEncoding.EncodeToString(claimsBytes) + "."

	if _, err := verifyMCPToken(token, testJWTConfig(), testNow); err == nil {
		t.Fatal("expected error")
	}
}

func TestVerifyMCPTokenTamperedPayload(t *testing.T) {
	token := signTestToken(t, hs256Header(), validClaims(), testSecret)
	parts := strings.Split(token, ".")
	claims := validClaims()
	claims["role"] = "faculty"
	claimsBytes, _ := json.Marshal(claims)
	tampered := parts[0] + "." + base64.RawURLEncoding.EncodeToString(claimsBytes) + "." + parts[2]

	_, err := verifyMCPToken(tampered, testJWTConfig(), testNow)
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "signature") {
		t.Fatalf("error = %q", err)
	}
}

func TestVerifyMCPTokenMalformed(t *testing.T) {
	tests := []struct {
		name  string
		token string
	}{
		{name: "empty", token: ""},
		{name: "two segments", token: "aaaa.bbbb"},
		{name: "four segments", token: "a.b.c.d"},
		{name: "not base64", token: "!!.!!.!!"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := verifyMCPToken(tt.token, testJWTConfig(), testNow); err == nil {
				t.Fatal("expected error")
			}
		})
	}
}
