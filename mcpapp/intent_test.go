package main

// Unit tests for the intent-token layer (intent.go): key derivation, payload
// binding, expiry, single use, and tamper rejection.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func testIdentity() *identity {
	return &identity{
		Subject: "user:42",
		UserID:  "42",
		Role:    "student",
		JTI:     "0b6f1625-3f39-4a12-9c4e-9ce67a9b6f37",
	}
}

func newTestIntentSigner(now func() time.Time) *intentSigner {
	if now == nil {
		now = time.Now
	}
	return newIntentSigner([]byte(testSecret), now)
}

func TestIntentTokenRoundTripAndContents(t *testing.T) {
	signer := newTestIntentSigner(nil)
	id := testIdentity()
	token, expiresAt, err := signer.mint(intentPayload{
		Kind:           intentKindSubmission,
		AssignmentSlug: "proj1",
		FieldSlug:      "repo-url",
		BodySHA256:     sha256Hex("hello"),
		Expected:       "2026-08-02T00:00:00+00:00",
		SubmissionID:   7,
	}, id)
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	if until := time.Until(expiresAt); until < 4*time.Minute || until > 6*time.Minute {
		t.Fatalf("expiry = %v from now, want ~5 minutes", until)
	}

	// The token is two segments, so it can never parse as a JWT.
	if got := strings.Count(token, "."); got != 1 {
		t.Fatalf("token has %d dots, want exactly 1", got)
	}

	// Decode the payload directly and verify the binding fields.
	segment := token[:strings.IndexByte(token, '.')]
	decoded, err := base64.RawURLEncoding.DecodeString(segment)
	if err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	var payload intentPayload
	if err := json.Unmarshal(decoded, &payload); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if payload.Subject != id.Subject || payload.TokenJTI != id.JTI {
		t.Fatalf("binding = %q/%q, want subject and jti of the caller", payload.Subject, payload.TokenJTI)
	}
	if payload.AssignmentSlug != "proj1" || payload.FieldSlug != "repo-url" || payload.SubmissionID != 7 {
		t.Fatalf("target binding = %+v", payload)
	}
	if payload.BodySHA256 != sha256Hex("hello") {
		t.Fatalf("body hash = %q", payload.BodySHA256)
	}
	if payload.Nonce == "" {
		t.Fatal("nonce must be set")
	}
	if payload.ExpiresAt != expiresAt.Unix() {
		t.Fatalf("exp = %d, want %d", payload.ExpiresAt, expiresAt.Unix())
	}

	verified, err := signer.verify(token, intentKindSubmission, id)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if verified.Expected != "2026-08-02T00:00:00+00:00" {
		t.Fatalf("expected = %q", verified.Expected)
	}
}

func TestIntentSigningKeyIsNotTheJWTSecret(t *testing.T) {
	signer := newTestIntentSigner(nil)
	if string(signer.key) == testSecret {
		t.Fatal("intent key must not be the raw JWT secret")
	}
	mac := hmac.New(sha256.New, []byte(testSecret))
	mac.Write([]byte(intentKeyDerivationLabel))
	if hmac.Equal(signer.key, mac.Sum(nil)) {
		t.Fatal("intent key must also mix in the per-process salt")
	}
}

// Each process derives a distinct key, so intent tokens minted before a
// restart stop verifying afterwards — the in-memory consumed-nonce set
// cannot survive a restart, so the tokens must not either.
func TestIntentSigningKeyIsPerProcess(t *testing.T) {
	first := newIntentSigner([]byte(testSecret), time.Now)
	second := newIntentSigner([]byte(testSecret), time.Now)
	if hmac.Equal(first.key, second.key) {
		t.Fatal("two signers must not share a key")
	}
}

func TestIntentTokenRejections(t *testing.T) {
	signer := newTestIntentSigner(nil)
	id := testIdentity()
	token, _, err := signer.mint(intentPayload{Kind: intentKindSubmission, BodySHA256: sha256Hex("x")}, id)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name  string
		token string
		kind  string
		id    *identity
	}{
		{name: "garbage", token: "nonsense", kind: intentKindSubmission, id: id},
		{name: "three segments (a JWT)", token: token + ".extra", kind: intentKindSubmission, id: id},
		{name: "tampered payload", token: "A" + token[1:], kind: intentKindSubmission, id: id},
		{name: "tampered signature", token: token[:len(token)-2] + "zz", kind: intentKindSubmission, id: id},
		{name: "wrong kind", token: token, kind: intentKindAPIRequest, id: id},
		{name: "foreign subject", token: token, kind: intentKindSubmission, id: &identity{Subject: "user:43", JTI: id.JTI}},
		{name: "different access token jti", token: token, kind: intentKindSubmission, id: &identity{Subject: id.Subject, JTI: "another-jti"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := signer.verify(tt.token, tt.kind, tt.id); err == nil {
				t.Fatal("expected rejection")
			}
		})
	}
}

func TestIntentTokenExpires(t *testing.T) {
	current := time.Now()
	signer := newTestIntentSigner(func() time.Time { return current })
	id := testIdentity()
	token, _, err := signer.mint(intentPayload{Kind: intentKindSubmission, BodySHA256: sha256Hex("x")}, id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := signer.verify(token, intentKindSubmission, id); err != nil {
		t.Fatalf("fresh token rejected: %v", err)
	}
	current = current.Add(intentTokenTTL + time.Second)
	if _, err := signer.verify(token, intentKindSubmission, id); err == nil {
		t.Fatal("expired token accepted")
	} else if !strings.Contains(err.Error(), "expired") {
		t.Fatalf("error = %v, want mention of expiry", err)
	}
}

func TestIntentTokenSingleUse(t *testing.T) {
	signer := newTestIntentSigner(nil)
	id := testIdentity()
	token, _, err := signer.mint(intentPayload{Kind: intentKindSubmission, BodySHA256: sha256Hex("x")}, id)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := signer.verify(token, intentKindSubmission, id)
	if err != nil {
		t.Fatal(err)
	}
	if err := signer.consume(payload); err != nil {
		t.Fatalf("first consume: %v", err)
	}
	if err := signer.consume(payload); err == nil {
		t.Fatal("second consume must fail")
	} else if !strings.Contains(err.Error(), "already used") {
		t.Fatalf("error = %v, want already-used", err)
	}
}

func TestIntentTokenForgedWithJWTSecretFails(t *testing.T) {
	// A forger holding a signing oracle keyed with the raw JWT secret (e.g. a
	// JWT-minting endpoint) still cannot mint intent tokens: the domains are
	// separated by key derivation.
	signer := newTestIntentSigner(nil)
	id := testIdentity()
	payload := intentPayload{
		Kind:       intentKindSubmission,
		Subject:    id.Subject,
		TokenJTI:   id.JTI,
		Nonce:      "abcd",
		ExpiresAt:  time.Now().Add(time.Minute).Unix(),
		BodySHA256: sha256Hex("x"),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	segment := base64.RawURLEncoding.EncodeToString(encoded)
	mac := hmac.New(sha256.New, []byte(testSecret)) // raw secret, wrong key
	mac.Write([]byte(segment))
	forged := segment + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if _, err := signer.verify(forged, intentKindSubmission, id); err == nil {
		t.Fatal("token signed with the raw JWT secret must be rejected")
	}
}

func TestMemoryNonceStorePrunesExpired(t *testing.T) {
	current := time.Now()
	store := newMemoryNonceStore(func() time.Time { return current })
	if !store.consume("n1", current.Add(time.Minute)) {
		t.Fatal("fresh nonce rejected")
	}
	if store.consume("n1", current.Add(time.Minute)) {
		t.Fatal("nonce reuse allowed")
	}
	current = current.Add(2 * time.Minute)
	// After expiry the entry is pruned; a (theoretically) recycled nonce would
	// be accepted, which is safe because verify rejects expired tokens first.
	if !store.consume("n2", current.Add(time.Minute)) {
		t.Fatal("nonce after pruning rejected")
	}
	store.mu.Lock()
	_, stillThere := store.used["n1"]
	store.mu.Unlock()
	if stillThere {
		t.Fatal("expired nonce was not pruned")
	}
}
