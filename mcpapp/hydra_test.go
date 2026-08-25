package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---- fake authorization server ----

const (
	testHydraIssuer   = "https://example.com"
	testMCPResource   = "https://example.com/mcp"
	testHydraClientID = "abcdef-client"
)

// testRSAKey is generated once per test binary: 2048-bit key generation is
// slow enough to matter across a table of cases.
var (
	testRSAKeyOnce sync.Once
	testRSAKeyA    *rsa.PrivateKey
	testRSAKeyB    *rsa.PrivateKey
)

func hydraTestKeys(t *testing.T) (*rsa.PrivateKey, *rsa.PrivateKey) {
	t.Helper()
	testRSAKeyOnce.Do(func() {
		var err error
		testRSAKeyA, err = rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			panic(err)
		}
		testRSAKeyB, err = rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			panic(err)
		}
	})
	return testRSAKeyA, testRSAKeyB
}

// fakeJWKS serves a JWKS document whose contents the test can swap, counting
// every fetch so refresh behaviour can be asserted.
type fakeJWKS struct {
	mu       sync.Mutex
	document []byte
	fetches  int
	server   *httptest.Server
}

func newFakeJWKS(t *testing.T, keys map[string]*rsa.PrivateKey) *fakeJWKS {
	t.Helper()
	fake := &fakeJWKS{document: jwksDocument(t, keys)}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.fetches++
		body := fake.document
		fake.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeJWKS) setKeys(t *testing.T, keys map[string]*rsa.PrivateKey) {
	t.Helper()
	document := jwksDocument(t, keys)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.document = document
}

func (f *fakeJWKS) fetchCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.fetches
}

// jwksDocument renders public keys as a JWKS, matching the shape Hydra
// publishes (kty/kid/alg/use/n/e).
func jwksDocument(t *testing.T, keys map[string]*rsa.PrivateKey) []byte {
	t.Helper()
	type jwk struct {
		Kty string `json:"kty"`
		Kid string `json:"kid"`
		Alg string `json:"alg"`
		Use string `json:"use"`
		N   string `json:"n"`
		E   string `json:"e"`
	}
	document := struct {
		Keys []jwk `json:"keys"`
	}{}
	for kid, key := range keys {
		document.Keys = append(document.Keys, jwk{
			Kty: "RSA",
			Kid: kid,
			Alg: "RS256",
			Use: "sig",
			N:   base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes()),
			E:   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.PublicKey.E)).Bytes()),
		})
	}
	encoded, err := json.Marshal(document)
	if err != nil {
		t.Fatalf("marshal jwks: %v", err)
	}
	return encoded
}

// signRS256 builds a JWT signed with RSASSA-PKCS1-v1_5 over SHA-256.
func signRS256(t *testing.T, key *rsa.PrivateKey, header map[string]any, claims map[string]any) string {
	t.Helper()
	headerBytes, err := json.Marshal(header)
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	claimsBytes, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal claims: %v", err)
	}
	signingInput := base64.RawURLEncoding.EncodeToString(headerBytes) + "." +
		base64.RawURLEncoding.EncodeToString(claimsBytes)
	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func rs256Header(kid string) map[string]any {
	return map[string]any{"alg": "RS256", "typ": "JWT", "kid": kid}
}

// hydraClaims mirrors a real Hydra access token for this deployment: netid in
// sub, identity claims duplicated top-level and under ext, scp as an array
// (issue #271 finding 5).
func hydraClaims() map[string]any {
	return map[string]any{
		"iss":       testHydraIssuer,
		"aud":       []any{testMCPResource},
		"sub":       "abc123",
		"client_id": testHydraClientID,
		"jti":       "6b2d0a1e-8b62-4a8e-9c1f-1b0dd2b53d9f",
		"iat":       testNow.Unix() - 60,
		"nbf":       testNow.Unix() - 60,
		"exp":       testNow.Unix() + 3600,
		"netid":     "abc123",
		"user_id":   json.Number("42"),
		"role":      "student",
		"scopes":    "openid offline_access course:read grades:read submissions:read",
		"scp":       []any{"openid", "offline_access", "course:read", "grades:read", "submissions:read"},
		"ext": map[string]any{
			"netid":   "abc123",
			"user_id": json.Number("42"),
			"role":    "student",
		},
	}
}

func newTestHydraVerifier(t *testing.T, jwks *fakeJWKS) *hydraVerifier {
	t.Helper()
	verifier := newHydraVerifier(hydraConfig{
		Issuer:   testHydraIssuer,
		JWKSURL:  jwks.server.URL,
		Audience: testMCPResource,
	}, jwks.server.Client(), func() time.Time { return testNow })
	// Most tests exercise key selection rather than the refresh rate limit,
	// which has its own test below.
	verifier.keys.minRefresh = 0
	return verifier
}

// ---- happy path ----

func TestHydraVerifyValidToken(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	verifier := newTestHydraVerifier(t, jwks)

	token := signRS256(t, keyA, rs256Header("key-a"), hydraClaims())
	id, external, err := verifier.verify(context.Background(), token, testNow)
	if err != nil {
		t.Fatalf("verify error = %v", err)
	}
	if !id.External {
		t.Fatal("identity is not marked external")
	}
	if id.NetID != "abc123" {
		t.Fatalf("NetID = %q", id.NetID)
	}
	if id.Subject != "user:42" || id.UserID != "42" {
		t.Fatalf("Subject = %q, UserID = %q", id.Subject, id.UserID)
	}
	if id.Role != "student" {
		t.Fatalf("Role = %q", id.Role)
	}
	if got, want := strings.Join(id.Scopes, " "), "course:read grades:read submissions:read"; got != want {
		t.Fatalf("Scopes = %q, want %q", got, want)
	}
	if !id.ExpiresAt.Equal(time.Unix(testNow.Unix()+3600, 0)) {
		t.Fatalf("ExpiresAt = %v", id.ExpiresAt)
	}
	if external.Issuer != testHydraIssuer || external.Subject != "abc123" ||
		external.ClientID != testHydraClientID || external.JTI == "" {
		t.Fatalf("externalRef = %+v", external)
	}
	if jwks.fetchCount() != 1 {
		t.Fatalf("jwks fetches = %d, want 1", jwks.fetchCount())
	}
}

func TestHydraVerifyCachesKeysAcrossTokens(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	verifier := newTestHydraVerifier(t, jwks)

	for i := 0; i < 3; i++ {
		token := signRS256(t, keyA, rs256Header("key-a"), hydraClaims())
		if _, _, err := verifier.verify(context.Background(), token, testNow); err != nil {
			t.Fatalf("verify %d error = %v", i, err)
		}
	}
	if jwks.fetchCount() != 1 {
		t.Fatalf("jwks fetches = %d, want 1 (keys must be cached)", jwks.fetchCount())
	}
}

// ---- key rotation ----

func TestHydraVerifyUnknownKIDRefetches(t *testing.T) {
	keyA, keyB := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	verifier := newTestHydraVerifier(t, jwks)

	// Prime the cache with key-a.
	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyA, rs256Header("key-a"), hydraClaims()), testNow); err != nil {
		t.Fatalf("verify with key-a: %v", err)
	}

	// The authorization server adds a key; the old one is still published
	// (the rotation-safe behaviour the issue #271 spike observed).
	jwks.setKeys(t, map[string]*rsa.PrivateKey{"key-a": keyA, "key-b": keyB})
	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyB, rs256Header("key-b"), hydraClaims()), testNow); err != nil {
		t.Fatalf("verify with rotated key-b: %v", err)
	}
	if jwks.fetchCount() != 2 {
		t.Fatalf("jwks fetches = %d, want 2 (one refetch for the unknown kid)", jwks.fetchCount())
	}
	// Both keys remain usable.
	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyA, rs256Header("key-a"), hydraClaims()), testNow); err != nil {
		t.Fatalf("verify with key-a after rotation: %v", err)
	}
}

func TestHydraVerifyWithdrawnKeyStopsVerifying(t *testing.T) {
	keyA, keyB := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	verifier := newTestHydraVerifier(t, jwks)

	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyA, rs256Header("key-a"), hydraClaims()), testNow); err != nil {
		t.Fatalf("verify with key-a: %v", err)
	}
	// Full rotation: key-a is withdrawn upstream. Fetching for key-b must
	// replace the key set, not merge into it.
	jwks.setKeys(t, map[string]*rsa.PrivateKey{"key-b": keyB})
	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyB, rs256Header("key-b"), hydraClaims()), testNow); err != nil {
		t.Fatalf("verify with key-b: %v", err)
	}
	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyA, rs256Header("key-a"), hydraClaims()), testNow); err == nil {
		t.Fatal("a token signed by a withdrawn key was accepted")
	}
}

func TestHydraUnknownKIDIsRateLimited(t *testing.T) {
	keyA, keyB := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	now := testNow
	verifier := newHydraVerifier(hydraConfig{
		Issuer:   testHydraIssuer,
		JWKSURL:  jwks.server.URL,
		Audience: testMCPResource,
	}, jwks.server.Client(), func() time.Time { return now })

	// Prime the cache (fetch 1).
	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyA, rs256Header("key-a"), hydraClaims()), now); err != nil {
		t.Fatalf("verify with key-a: %v", err)
	}
	// Tokens carrying unknown kids must not turn into upstream requests: the
	// whole burst is served from the key set fetched a moment ago.
	for i := 0; i < 5; i++ {
		if _, _, err := verifier.verify(context.Background(), signRS256(t, keyB, rs256Header("key-b"), hydraClaims()), now); err == nil {
			t.Fatal("token signed by an unpublished key was accepted")
		}
	}
	if jwks.fetchCount() != 1 {
		t.Fatalf("jwks fetches = %d, want 1 (unknown kids must be rate limited)", jwks.fetchCount())
	}

	// Once the window passes, a genuine rotation is picked up.
	jwks.setKeys(t, map[string]*rsa.PrivateKey{"key-a": keyA, "key-b": keyB})
	now = now.Add(jwksMinRefreshInterval + time.Second)
	if _, _, err := verifier.verify(context.Background(), signRS256(t, keyB, rs256Header("key-b"), hydraClaims()), now); err != nil {
		t.Fatalf("verify after the refresh window: %v", err)
	}
	if jwks.fetchCount() != 2 {
		t.Fatalf("jwks fetches = %d, want 2", jwks.fetchCount())
	}
}

// ---- negative cases ----

func TestHydraVerifyRejects(t *testing.T) {
	keyA, keyB := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})

	tests := []struct {
		name   string
		header map[string]any
		mutate func(map[string]any)
		key    *rsa.PrivateKey
		want   string
	}{
		{
			name:   "wrong issuer",
			mutate: func(c map[string]any) { c["iss"] = "https://evil.example" },
			want:   "iss claim",
		},
		{
			name:   "missing aud",
			mutate: func(c map[string]any) { delete(c, "aud") },
			want:   "missing aud claim",
		},
		{
			name:   "empty aud array",
			mutate: func(c map[string]any) { c["aud"] = []any{} },
			want:   "aud claim is empty",
		},
		{
			name:   "aud without the MCP resource",
			mutate: func(c map[string]any) { c["aud"] = []any{"https://example.com/other"} },
			want:   "aud claim must include",
		},
		{
			name:   "aud string that is not the resource",
			mutate: func(c map[string]any) { c["aud"] = "https://example.com/other" },
			want:   "aud claim must include",
		},
		{
			name:   "expired",
			mutate: func(c map[string]any) { c["exp"] = testNow.Unix() - 1 },
			want:   "expired",
		},
		{
			name:   "nbf in the future",
			mutate: func(c map[string]any) { c["nbf"] = testNow.Add(10 * time.Minute).Unix() },
			want:   "nbf is in the future",
		},
		{
			name:   "iat in the future",
			mutate: func(c map[string]any) { c["iat"] = testNow.Add(10 * time.Minute).Unix() },
			want:   "iat is in the future",
		},
		{
			name: "no netid and an internal-shaped sub",
			mutate: func(c map[string]any) {
				delete(c, "netid")
				delete(c, "ext")
				c["sub"] = "user:42"
			},
			want: "no netid",
		},
		{
			name:   "missing sub",
			mutate: func(c map[string]any) { delete(c, "sub") },
			want:   "missing sub claim",
		},
		{
			name:   "id token",
			mutate: func(c map[string]any) { c["at_hash"] = "PGKPYXAvYA5eqCbdEBmqQg" },
			want:   "id token",
		},
		{
			name:   "no kid",
			header: map[string]any{"alg": "RS256", "typ": "JWT"},
			want:   "no kid",
		},
		{
			name:   "unpublished kid",
			header: rs256Header("key-unknown"),
			want:   "unknown key",
		},
		{
			name:   "signed by the wrong key",
			header: rs256Header("key-a"),
			key:    keyB,
			want:   "signature is invalid",
		},
		{
			name:   "id-token typ",
			header: map[string]any{"alg": "RS256", "typ": "id_token+jwt", "kid": "key-a"},
			want:   "not an access token",
		},
		{
			name:   "HS256 header on an RSA-signed token",
			header: map[string]any{"alg": "HS256", "typ": "JWT", "kid": "key-a"},
			want:   "not an accepted OAuth signature algorithm",
		},
		{
			name:   "alg none",
			header: map[string]any{"alg": "none", "typ": "JWT", "kid": "key-a"},
			want:   "not an accepted OAuth signature algorithm",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			verifier := newTestHydraVerifier(t, jwks)
			claims := hydraClaims()
			if tt.mutate != nil {
				tt.mutate(claims)
			}
			header := tt.header
			if header == nil {
				header = rs256Header("key-a")
			}
			key := tt.key
			if key == nil {
				key = keyA
			}
			token := signRS256(t, key, header, claims)
			_, _, err := verifier.verify(context.Background(), token, testNow)
			if err == nil {
				t.Fatal("token was accepted")
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error = %q, want it to contain %q", err, tt.want)
			}
		})
	}
}

// TestHydraVerifyRejectsHMACForgedWithPublicKey is the classic algorithm
// confusion attack: the attacker takes the public key everyone can fetch and
// uses it as an HMAC secret. No symmetric algorithm has a path here at all, so
// it is refused on the alg alone.
func TestHydraVerifyRejectsHMACForgedWithPublicKey(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	verifier := &bearerVerifier{hydra: newTestHydraVerifier(t, jwks)}

	publicKeyAsSecret := string(keyA.PublicKey.N.Bytes())
	forged := signTestToken(t, map[string]any{"alg": "HS256", "typ": "JWT", "kid": "key-a"}, hydraClaims(), publicKeyAsSecret)
	if _, err := verifier.verify(context.Background(), forged, testNow); err == nil {
		t.Fatal("an HS256 token signed with the RSA public key was accepted")
	}

	// The mirror image: an HMAC-signed token presented with an RS256 header.
	// It must not be verified with the HMAC secret.
	claims := validClaims()
	rsHeaderOnHMACToken := signTestToken(t, map[string]any{"alg": "RS256", "typ": "JWT", "kid": "key-a"}, claims, testSecret)
	if _, err := verifier.verify(context.Background(), rsHeaderOnHMACToken, testNow); err == nil {
		t.Fatal("an HMAC-signed token with an RS256 header was accepted")
	}
}

// TestBearerVerifierAcceptsOnlyOAuthAlgs: the Hydra path is the only path, and
// an alg it does not advertise never reaches a key.
func TestBearerVerifierAcceptsOnlyOAuthAlgs(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	verifier := &bearerVerifier{hydra: newTestHydraVerifier(t, jwks)}

	oauth := signRS256(t, keyA, rs256Header("key-a"), hydraClaims())
	id, err := verifier.verify(context.Background(), oauth, testNow)
	if err != nil {
		t.Fatalf("oauth token rejected: %v", err)
	}
	if !id.External {
		t.Fatal("oauth identity is not marked external")
	}

	// alg=none is refused before any key is consulted.
	none := "eyJhbGciOiJub25lIn0." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"abc123"}`)) + "."
	if _, err := verifier.verify(context.Background(), none, testNow); err == nil {
		t.Fatal("alg=none was accepted")
	}
}

func TestBearerVerifierWithoutHydraRejectsOAuthTokens(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	verifier := &bearerVerifier{}
	token := signRS256(t, keyA, rs256Header("key-a"), hydraClaims())
	_, err := verifier.verify(context.Background(), token, testNow)
	if err == nil || !strings.Contains(err.Error(), "does not accept OAuth access tokens") {
		t.Fatalf("error = %v", err)
	}
}

// ---- scope extraction and mapping ----

func TestHydraScopeMapping(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})

	tests := []struct {
		name   string
		mutate func(map[string]any)
		want   []string
	}{
		{
			name:   "scp array only",
			mutate: func(c map[string]any) { delete(c, "scopes") },
			want:   []string{"course:read", "grades:read", "submissions:read"},
		},
		{
			name:   "space-delimited scopes claim only",
			mutate: func(c map[string]any) { delete(c, "scp") },
			want:   []string{"course:read", "grades:read", "submissions:read"},
		},
		{
			name: "write scope",
			mutate: func(c map[string]any) {
				c["scopes"] = "openid submissions:write"
				delete(c, "scp")
			},
			want: []string{"submissions:write"},
		},
		{
			name: "coarse names still map",
			mutate: func(c map[string]any) {
				c["scopes"] = "read write"
				delete(c, "scp")
			},
			want: []string{"course:read", "grades:read", "submissions:read", "submissions:write"},
		},
		{
			name: "unknown and OIDC-only scopes map to nothing",
			mutate: func(c map[string]any) {
				c["scopes"] = "openid offline_access profile invented:scope"
				delete(c, "scp")
			},
			want: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			verifier := newTestHydraVerifier(t, jwks)
			claims := hydraClaims()
			tt.mutate(claims)
			id, _, err := verifier.verify(context.Background(), signRS256(t, keyA, rs256Header("key-a"), claims), testNow)
			if err != nil {
				t.Fatalf("verify error = %v", err)
			}
			if strings.Join(id.Scopes, " ") != strings.Join(tt.want, " ") {
				t.Fatalf("Scopes = %v, want %v", id.Scopes, tt.want)
			}
		})
	}
}

// TestExternalTokenWithoutMappedScopesIsDeniedEverything pins the default-deny
// rule for OAuth callers: a token whose grant maps to nothing this server
// exposes gets no read access either. TestScopelessIdentityIsDeniedEveryTool
// covers the same rule for an identity not marked External, which since issue
// #324 is refused identically.
func TestExternalTokenWithoutMappedScopesIsDeniedEverything(t *testing.T) {
	external := &identity{External: true}
	for _, required := range []string{scopeRead, scopeWrite} {
		err := authorizeScope(external, required)
		if err == nil {
			t.Fatalf("%q was allowed for an OAuth token with no mapped scopes", required)
		}
		if !strings.Contains(err.Error(), "granted no yelukerest scopes") {
			t.Fatalf("error = %q", err)
		}
	}
}

// ---- JWKS parsing ----

func TestParseJWKSSkipsUnusableKeys(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	document := []byte(`{"keys":[
		{"kty":"RSA","kid":"enc","use":"enc","alg":"RS256","n":"` +
		base64.RawURLEncoding.EncodeToString(keyA.PublicKey.N.Bytes()) + `","e":"AQAB"},
		{"kty":"oct","kid":"symmetric","alg":"HS256","k":"c2VjcmV0"},
		{"kty":"RSA","kid":"tiny","alg":"RS256","n":"AQAB","e":"AQAB"},
		{"kty":"RSA","kid":"good","alg":"RS256","use":"sig","n":"` +
		base64.RawURLEncoding.EncodeToString(keyA.PublicKey.N.Bytes()) + `","e":"AQAB"}
	]}`)

	keys, err := parseJWKS(document)
	if err != nil {
		t.Fatalf("parseJWKS error = %v", err)
	}
	if len(keys) != 1 {
		t.Fatalf("parsed %d keys, want 1: %v", len(keys), keys)
	}
	if _, ok := keys["good"]; !ok {
		t.Fatalf("keys = %v", keys)
	}
}

func TestParseJWKSRejectsEmptyKeySet(t *testing.T) {
	if _, err := parseJWKS([]byte(`{"keys":[]}`)); err == nil {
		t.Fatal("an empty key set was accepted")
	}
	if _, err := parseJWKS([]byte(`not json`)); err == nil {
		t.Fatal("a non-JSON key set was accepted")
	}
}

// A key withdrawn upstream must stop verifying within the cache window even
// when its kid stays in the cache and no unknown kid forces a refetch.
func TestJWKSCacheRefreshesAfterMaxAge(t *testing.T) {
	keyA, keyB := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"kid-1": keyA})
	clock := time.Now()
	cache := &jwksCache{
		url:        jwks.server.URL,
		client:     jwks.server.Client(),
		minRefresh: 0,
		maxAge:     15 * time.Minute,
		now:        func() time.Time { return clock },
	}
	ctx := context.Background()

	if _, err := cache.keyForKID(ctx, "kid-1"); err != nil {
		t.Fatalf("first lookup: %v", err)
	}
	fetches := jwks.fetchCount()

	// Fresh cache: served without touching the network.
	if _, err := cache.keyForKID(ctx, "kid-1"); err != nil {
		t.Fatalf("cached lookup: %v", err)
	}
	if jwks.fetchCount() != fetches {
		t.Fatal("a fresh cache must not refetch")
	}

	// Withdraw the key upstream, then cross the max-age boundary.
	jwks.setKeys(t, map[string]*rsa.PrivateKey{"kid-2": keyB})
	clock = clock.Add(16 * time.Minute)
	if _, err := cache.keyForKID(ctx, "kid-1"); err == nil {
		t.Fatal("a withdrawn key must stop verifying once the cache goes stale")
	}
	if jwks.fetchCount() == fetches {
		t.Fatal("a stale cache must refetch")
	}
}
