package main

import (
	"context"
	"crypto/hmac"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

// testSecret stands in for JWT_SECRET, the shared secret the database and
// authapp sign with. mcpapp no longer verifies anything with it: it appears
// here only to mint the internal credentials tools forward to PostgREST, and
// to prove that a token signed with it cannot get in (issue #322).
const testSecret = "reallyreallyreallylongsecretkey"

var testNow = time.Unix(1_700_000_000, 0)

// validClaims is an internally-minted user JWT: the shape api.issue_user_jwt_for_mcp
// returns, and the shape the retired phase 0 bearer token had.
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

// TestBearerVerifierRefusesInternallySignedToken pins the removal of the phase
// 0 credential class (issue #322). A token signed with JWT_SECRET, with claims
// that would once have opened /mcp, must be refused — and refused in exactly
// the words a token bearing an algorithm nobody ever supported gets, so the
// 401 body says nothing about what this deployment used to accept.
func TestBearerVerifierRefusesInternallySignedToken(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	verifier := &bearerVerifier{hydra: newTestHydraVerifier(t, jwks)}

	internal := signTestToken(t, hs256Header(), validClaims(), testSecret)
	_, err := verifier.verify(context.Background(), internal, testNow)
	if err == nil {
		t.Fatal("an HS256 token signed with JWT_SECRET was accepted")
	}

	unknownAlg := signTestToken(t, map[string]any{"alg": "XS512", "typ": "JWT"}, validClaims(), testSecret)
	_, unknownErr := verifier.verify(context.Background(), unknownAlg, testNow)
	if unknownErr == nil {
		t.Fatal("a token with an unknown alg was accepted")
	}
	if err.Error() != unknownErr.Error() {
		t.Fatalf("HS256 was refused with %q but an unknown alg with %q; the difference tells a caller what this server used to accept", err, unknownErr)
	}
	if jwks.fetchCount() != 0 {
		t.Fatal("a symmetric token must be refused before any key material is consulted")
	}
}
