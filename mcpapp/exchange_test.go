package main

import (
	"context"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// ---- helpers ----

// internalTokenFor mints the kind of token api.issue_user_jwt_for_mcp returns:
// an HS256 dual-audience JWT whose exp bounds how long it may be cached.
func internalTokenFor(t *testing.T, jti string, expiresAt time.Time) string {
	t.Helper()
	claims := map[string]any{
		"iss":     "yelukerest",
		"aud":     []any{"yelukerest-postgrest", "yelukerest-mcp"},
		"sub":     "user:42",
		"user_id": 42,
		"netid":   "abc123",
		"role":    "student",
		"scopes":  "course:read grades:read submissions:read",
		"jti":     jti,
		"iat":     expiresAt.Add(-10 * time.Minute).Unix(),
		"nbf":     expiresAt.Add(-10 * time.Minute).Unix(),
		"exp":     expiresAt.Unix(),
	}
	return signTestToken(t, hs256Header(), claims, testSecret)
}

// mintResponse is the PostgREST single-object body for one mint.
func mintResponse(token string) string {
	body, _ := json.Marshal(mintResult{JWT: token, UserID: 42, NetID: "abc123", Role: "student"})
	return string(body)
}

func newTestExchanger(t *testing.T, fake *fakePostgREST, now time.Time) *tokenExchanger {
	t.Helper()
	exchanger := newTokenExchanger(fake.client(t), "service-token")
	exchanger.now = func() time.Time { return now }
	// Deterministic tests: the jitter is exercised by its own assertion below.
	exchanger.jitter = func() time.Duration { return 0 }
	return exchanger
}

func testExchangeRequest(outerExp time.Time) exchangeRequest {
	return exchangeRequest{
		netID:  "abc123",
		scopes: []string{"course:read", "grades:read", "submissions:read"},
		external: externalRef{
			Issuer:   testHydraIssuer,
			Subject:  "abc123",
			JTI:      "6b2d0a1e-8b62-4a8e-9c1f-1b0dd2b53d9f",
			ClientID: testHydraClientID,
		},
		outerExp: outerExp,
	}
}

// ---- call shape ----

func TestExchangeCallShape(t *testing.T) {
	fake := newFakePostgREST(t)
	now := testNow
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-1", now.Add(10*time.Minute))))

	exchanger := newTestExchanger(t, fake, now)
	minted, err := exchanger.tokenFor(context.Background(), testExchangeRequest(now.Add(time.Hour)))
	if err != nil {
		t.Fatalf("tokenFor error = %v", err)
	}
	if minted.userID != "42" || minted.netID != "abc123" || minted.role != "student" {
		t.Fatalf("minted = %+v", minted)
	}
	if !minted.expiresAt.Equal(now.Add(10 * time.Minute)) {
		t.Fatalf("minted.expiresAt = %v", minted.expiresAt)
	}

	requests := fake.recorded()
	if len(requests) != 1 {
		t.Fatalf("recorded %d requests, want 1", len(requests))
	}
	request := requests[0]
	if request.method != http.MethodPost || request.path != "/rpc/issue_user_jwt_for_mcp" {
		t.Fatalf("request = %s %s", request.method, request.path)
	}
	if request.auth != "Bearer service-token" {
		t.Fatalf("Authorization = %q (the mcpapp service credential must be used, never the caller's token)", request.auth)
	}
	if request.accept != "application/vnd.pgrst.object+json" {
		t.Fatalf("Accept = %q", request.accept)
	}

	var body struct {
		NetID    string            `json:"p_netid"`
		Scopes   []string          `json:"p_scopes"`
		External map[string]string `json:"p_external"`
	}
	if err := json.Unmarshal([]byte(request.body), &body); err != nil {
		t.Fatalf("decode body %q: %v", request.body, err)
	}
	if body.NetID != "abc123" {
		t.Fatalf("p_netid = %q", body.NetID)
	}
	if strings.Join(body.Scopes, " ") != "course:read grades:read submissions:read" {
		t.Fatalf("p_scopes = %v", body.Scopes)
	}
	want := map[string]string{
		"iss":       testHydraIssuer,
		"sub":       "abc123",
		"jti":       "6b2d0a1e-8b62-4a8e-9c1f-1b0dd2b53d9f",
		"client_id": testHydraClientID,
	}
	for key, value := range want {
		if body.External[key] != value {
			t.Fatalf("p_external[%q] = %q, want %q", key, body.External[key], value)
		}
	}
}

func TestExchangeOmitsEmptyExternalFields(t *testing.T) {
	fake := newFakePostgREST(t)
	now := testNow
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-1", now.Add(10*time.Minute))))

	exchanger := newTestExchanger(t, fake, now)
	request := testExchangeRequest(now.Add(time.Hour))
	request.external.ClientID = ""
	if _, err := exchanger.tokenFor(context.Background(), request); err != nil {
		t.Fatalf("tokenFor error = %v", err)
	}

	var body struct {
		External map[string]string `json:"p_external"`
	}
	if err := json.Unmarshal([]byte(fake.recorded()[0].body), &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if _, present := body.External["client_id"]; present {
		t.Fatalf("p_external = %v, want no empty client_id key", body.External)
	}
}

// ---- caching ----

func TestExchangeCachesWithinTTL(t *testing.T) {
	fake := newFakePostgREST(t)
	now := testNow
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-1", now.Add(10*time.Minute))))

	exchanger := newTestExchanger(t, fake, now)
	request := testExchangeRequest(now.Add(time.Hour))

	first, err := exchanger.tokenFor(context.Background(), request)
	if err != nil {
		t.Fatalf("first tokenFor: %v", err)
	}
	second, err := exchanger.tokenFor(context.Background(), request)
	if err != nil {
		t.Fatalf("second tokenFor: %v", err)
	}
	if first.token != second.token {
		t.Fatal("the cached credential was not reused")
	}
	if got := len(fake.recorded()); got != 1 {
		t.Fatalf("%d mint calls, want 1 (each mint writes an audit row)", got)
	}

	// A different scope set is a different cache entry.
	other := request
	other.scopes = []string{"course:read"}
	if _, err := exchanger.tokenFor(context.Background(), other); err != nil {
		t.Fatalf("tokenFor for other scopes: %v", err)
	}
	if got := len(fake.recorded()); got != 2 {
		t.Fatalf("%d mint calls, want 2 (scopes are part of the cache key)", got)
	}

	// So is a different OAuth client, so the mint-audit row names the client
	// that actually reached the student's data.
	otherClient := request
	otherClient.external.ClientID = "another-client"
	if _, err := exchanger.tokenFor(context.Background(), otherClient); err != nil {
		t.Fatalf("tokenFor for another client: %v", err)
	}
	if got := len(fake.recorded()); got != 3 {
		t.Fatalf("%d mint calls, want 3 (the OAuth client is part of the cache key)", got)
	}
}

func TestExchangeCacheKeyIsInjective(t *testing.T) {
	// A client id chosen to look like a different (client, scopes) split must
	// not collide with the genuine tuple.
	forged := exchangeCacheKey("abc123", "x|24:course:read grades:read", []string{"submissions:write"})
	genuine := exchangeCacheKey("abc123", "x", []string{"course:read", "grades:read", "submissions:write"})
	if forged == genuine {
		t.Fatal("cache keys collide across different (client, scopes) tuples")
	}
	if !strings.HasPrefix(forged, exchangeCacheKeyPrefix("abc123")) ||
		!strings.HasPrefix(genuine, exchangeCacheKeyPrefix("abc123")) {
		t.Fatal("cache keys do not share the per-netid prefix that forget relies on")
	}
}

func TestExchangeReMintsAfterTTL(t *testing.T) {
	fake := newFakePostgREST(t)
	now := testNow
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-1", now.Add(10*time.Minute))))

	exchanger := newTestExchanger(t, fake, now)
	request := testExchangeRequest(now.Add(time.Hour))
	if _, err := exchanger.tokenFor(context.Background(), request); err != nil {
		t.Fatalf("first tokenFor: %v", err)
	}

	// Past the internal token's life minus the safety margin.
	later := now.Add(10*time.Minute - exchangeSafetyMargin + time.Second)
	exchanger.now = func() time.Time { return later }
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-2", later.Add(10*time.Minute))))
	if _, err := exchanger.tokenFor(context.Background(), request); err != nil {
		t.Fatalf("second tokenFor: %v", err)
	}
	if got := len(fake.recorded()); got != 2 {
		t.Fatalf("%d mint calls, want 2 (the cached credential expired)", got)
	}
}

// TestExchangeNeverServesPastOuterExpiry is the property the issue #266 review
// called out: a cached internal credential must never outlive the access token
// that justified minting it.
func TestExchangeNeverServesPastOuterExpiry(t *testing.T) {
	fake := newFakePostgREST(t)
	now := testNow
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-1", now.Add(10*time.Minute))))
	exchanger := newTestExchanger(t, fake, now)

	// Minted under a long-lived access token, so the entry is cached.
	longLived := testExchangeRequest(now.Add(time.Hour))
	if _, err := exchanger.tokenFor(context.Background(), longLived); err != nil {
		t.Fatalf("tokenFor: %v", err)
	}

	// The same caller, same scopes, but presenting a token that has since
	// expired: the cached credential must not be served — and no fresh one
	// may be minted either, since the caller's authorization has lapsed.
	expired := testExchangeRequest(now.Add(-time.Second))
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-2", now.Add(10*time.Minute))))
	if _, err := exchanger.tokenFor(context.Background(), expired); err == nil {
		t.Fatal("an expired access token must not yield a credential")
	}
	if got := len(fake.recorded()); got != 1 {
		t.Fatalf("%d mint calls, want 1 (an expired token must neither be served from cache nor minted afresh)", got)
	}
}

// TestExchangeCacheDeadlineIsBounded checks the TTL formula directly over a
// range of internal/outer lifetimes: an entry never outlives either token.
func TestExchangeCacheDeadlineIsBounded(t *testing.T) {
	now := testNow
	internalLifetimes := []time.Duration{30 * time.Second, 90 * time.Second, 10 * time.Minute, time.Hour}
	outerLifetimes := []time.Duration{5 * time.Second, 2 * time.Minute, 10 * time.Minute, time.Hour, 24 * time.Hour}

	for _, internal := range internalLifetimes {
		for _, outer := range outerLifetimes {
			fake := newFakePostgREST(t)
			internalExp := now.Add(internal)
			outerExp := now.Add(outer)
			fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
				mintResponse(internalTokenFor(t, "mint", internalExp)))
			exchanger := newTestExchanger(t, fake, now)
			// A non-zero jitter must only ever shorten the entry's life.
			exchanger.jitter = func() time.Duration { return exchangeMaxJitter }

			if _, err := exchanger.tokenFor(context.Background(), testExchangeRequest(outerExp)); err != nil {
				t.Fatalf("tokenFor(internal=%s, outer=%s): %v", internal, outer, err)
			}
			entry, cached := exchanger.lookup(exchangeCacheKey("abc123", testHydraClientID, testExchangeRequest(outerExp).scopes))
			if !cached {
				// Correct when the usable window would already be gone.
				if internal > exchangeSafetyMargin+exchangeMaxJitter && outer > exchangeSafetyMargin+exchangeMaxJitter {
					t.Fatalf("nothing cached for internal=%s outer=%s", internal, outer)
				}
				continue
			}
			if entry.notAfter.After(internalExp) {
				t.Fatalf("entry outlives the internal token (internal=%s outer=%s)", internal, outer)
			}
			if entry.notAfter.After(outerExp) {
				t.Fatalf("entry outlives the access token (internal=%s outer=%s)", internal, outer)
			}
		}
	}
}

func TestExchangeForgetDropsCachedCredentials(t *testing.T) {
	fake := newFakePostgREST(t)
	now := testNow
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-1", now.Add(10*time.Minute))))
	exchanger := newTestExchanger(t, fake, now)
	request := testExchangeRequest(now.Add(time.Hour))

	if _, err := exchanger.tokenFor(context.Background(), request); err != nil {
		t.Fatalf("tokenFor: %v", err)
	}
	exchanger.forget("abc123")
	if _, err := exchanger.tokenFor(context.Background(), request); err != nil {
		t.Fatalf("tokenFor after forget: %v", err)
	}
	if got := len(fake.recorded()); got != 2 {
		t.Fatalf("%d mint calls, want 2 (forget must drop the entry)", got)
	}
}

// ---- failures ----

func TestExchangeFailuresSurfaceClearErrors(t *testing.T) {
	now := testNow
	tests := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{name: "unknown netid", status: http.StatusNotAcceptable, body: `{}`, want: "not enrolled"},
		{name: "policy refusal", status: http.StatusForbidden, body: `{"message":"insufficient_privilege"}`, want: "not permitted"},
		{name: "service credential rejected", status: http.StatusUnauthorized, body: `{}`, want: "MCPAPP_JWT"},
		{name: "bad parameters", status: http.StatusBadRequest, body: `{}`, want: "rejected the credential request"},
		{name: "server error", status: http.StatusInternalServerError, body: `{}`, want: "HTTP 500"},
		{name: "empty jwt", status: http.StatusOK, body: `{"jwt":"","user_id":42}`, want: "not authorized"},
		{name: "unreadable body", status: http.StatusOK, body: `not json`, want: "unreadable"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			fake.respondMethod(http.MethodPost, exchangeRPCPath, tt.status, tt.body)
			exchanger := newTestExchanger(t, fake, now)

			_, err := exchanger.tokenFor(context.Background(), testExchangeRequest(now.Add(time.Hour)))
			if err == nil {
				t.Fatal("exchange succeeded")
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error = %q, want it to contain %q", err, tt.want)
			}
			// A failed mint is never cached.
			if _, cached := exchanger.lookup(exchangeCacheKey("abc123", testHydraClientID, testExchangeRequest(now).scopes)); cached {
				t.Fatal("a failed exchange was cached")
			}
		})
	}
}

func TestExchangeWithoutServiceCredentialFailsFast(t *testing.T) {
	fake := newFakePostgREST(t)
	exchanger := newTokenExchanger(fake.client(t), "")
	_, err := exchanger.tokenFor(context.Background(), testExchangeRequest(testNow.Add(time.Hour)))
	if err == nil || !strings.Contains(err.Error(), "MCPAPP_JWT") {
		t.Fatalf("error = %v", err)
	}
	if got := len(fake.recorded()); got != 0 {
		t.Fatalf("%d upstream calls, want 0", got)
	}
}

func TestExchangeRequiresNetIDAndScopes(t *testing.T) {
	fake := newFakePostgREST(t)
	exchanger := newTestExchanger(t, fake, testNow)

	noNetID := testExchangeRequest(testNow.Add(time.Hour))
	noNetID.netID = ""
	if _, err := exchanger.tokenFor(context.Background(), noNetID); err == nil {
		t.Fatal("an exchange without a netid succeeded")
	}

	noScopes := testExchangeRequest(testNow.Add(time.Hour))
	noScopes.scopes = nil
	if _, err := exchanger.tokenFor(context.Background(), noScopes); err == nil {
		t.Fatal("an exchange without scopes succeeded")
	}
	if got := len(fake.recorded()); got != 0 {
		t.Fatalf("%d upstream calls, want 0", got)
	}
}

// ---- end to end through the MCP stack ----

// newOAuthTestApp builds the full HTTP stack with the OAuth path enabled
// against a fake authorization server and a fake PostgREST.
func newOAuthTestApp(t *testing.T, jwks *fakeJWKS, serviceJWT string) (*httptest.Server, *fakePostgREST) {
	t.Helper()
	fake := newFakePostgREST(t)
	deps := &toolDeps{
		logger:    slog.New(slog.NewTextHandler(io.Discard, nil)),
		postgrest: fake.client(t),
		intent:    newIntentSigner([]byte(testSecret), time.Now),
		exchanger: newTokenExchanger(fake.client(t), serviceJWT),
	}
	config := testAppConfig(100)
	config.ResourceURL = testMCPResource
	config.AuthorizationServerURL = testHydraIssuer
	config.Hydra = &hydraConfig{
		Issuer:   testHydraIssuer,
		JWKSURL:  jwks.server.URL,
		Audience: testMCPResource,
	}
	server := httptest.NewServer(newMux(config, deps))
	t.Cleanup(server.Close)
	return server, fake
}

// currentHydraToken signs an access token valid at wall-clock time, for tests
// that go through the real verifier.
func currentHydraToken(t *testing.T, key *rsa.PrivateKey, mutate func(map[string]any)) string {
	t.Helper()
	claims := hydraClaims()
	claims["iat"] = time.Now().Add(-time.Minute).Unix()
	claims["nbf"] = time.Now().Add(-time.Minute).Unix()
	claims["exp"] = time.Now().Add(time.Hour).Unix()
	if mutate != nil {
		mutate(claims)
	}
	return signRS256(t, key, rs256Header("key-a"), claims)
}

// toolResultText flattens a tool result's text content for assertions.
func toolResultText(result *mcp.CallToolResult) string {
	var parts []string
	for _, content := range result.Content {
		if text, ok := content.(*mcp.TextContent); ok {
			parts = append(parts, text.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func callWhoami(t *testing.T, serverURL string, token string) *mcp.CallToolResult {
	t.Helper()
	ctx := context.Background()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.1"}, nil)
	session, err := client.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint:   serverURL + mcpPath,
		HTTPClient: &http.Client{Transport: authTransport{token: token}},
	}, nil)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer session.Close()
	if _, err := session.ListTools(ctx, nil); err != nil {
		t.Fatalf("tools/list: %v", err)
	}
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "whoami"})
	if err != nil {
		t.Fatalf("tools/call: %v", err)
	}
	return result
}

// TestOAuthCallerExchangesTokenEndToEnd drives a Hydra-shaped access token
// through the whole HTTP stack and asserts that PostgREST sees the minted
// internal credential, never the OAuth token.
func TestOAuthCallerExchangesTokenEndToEnd(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	server, fake := newOAuthTestApp(t, jwks, "service-token")

	internal := internalTokenFor(t, "mint-e2e", time.Now().Add(10*time.Minute))
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK, mintResponse(internal))
	fake.respond("/users", fixtureUserRows)

	accessToken := currentHydraToken(t, keyA, nil)
	result := callWhoami(t, server.URL, accessToken)
	if result.IsError {
		t.Fatalf("whoami returned a tool error: %+v", result.Content)
	}

	structured, err := json.Marshal(result.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structured content: %v", err)
	}
	var output whoamiOutput
	if err := json.Unmarshal(structured, &output); err != nil {
		t.Fatalf("unmarshal structured content: %v", err)
	}
	if output.NetID != "abc123" || output.UserID != "42" {
		t.Fatalf("whoami output = %+v", output)
	}

	sawMint := false
	sawUsers := false
	for _, request := range fake.recorded() {
		if request.path == exchangeRPCPath {
			sawMint = true
			if request.auth != "Bearer service-token" {
				t.Fatalf("mint Authorization = %q", request.auth)
			}
			continue
		}
		sawUsers = true
		if request.auth == "Bearer "+accessToken {
			t.Fatalf("the OAuth access token was forwarded to %s", request.path)
		}
		if request.auth != "Bearer "+internal {
			t.Fatalf("Authorization on %s = %q, want the minted internal credential", request.path, request.auth)
		}
	}
	if !sawMint || !sawUsers {
		t.Fatalf("mint call = %v, PostgREST read = %v", sawMint, sawUsers)
	}
}

// TestOAuthCallerWithoutServiceCredentialGetsAClearToolError checks the
// deployment-misconfiguration path: verification still succeeds (so the client
// does not loop through OAuth), and the tool call explains what is missing.
func TestOAuthCallerWithoutServiceCredentialGetsAClearToolError(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	server, fake := newOAuthTestApp(t, jwks, "")

	result := callWhoami(t, server.URL, currentHydraToken(t, keyA, nil))
	if !result.IsError {
		t.Fatal("whoami succeeded without a service credential")
	}
	text := toolResultText(result)
	if !strings.Contains(text, "MCPAPP_JWT") {
		t.Fatalf("whoami error = %s", text)
	}
	if got := len(fake.recorded()); got != 0 {
		t.Fatalf("%d upstream calls, want 0", got)
	}
}

// TestOAuthCallerWithoutMappedScopesIsDenied is the scope-mapping mismatch
// case end to end: consent granted only OIDC scopes, so no tool runs and
// nothing is minted.
func TestOAuthCallerWithoutMappedScopesIsDenied(t *testing.T) {
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	server, fake := newOAuthTestApp(t, jwks, "service-token")
	fake.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK,
		mintResponse(internalTokenFor(t, "mint-denied", time.Now().Add(10*time.Minute))))

	token := currentHydraToken(t, keyA, func(claims map[string]any) {
		claims["scopes"] = "openid offline_access"
		claims["scp"] = []any{"openid", "offline_access"}
	})
	result := callWhoami(t, server.URL, token)
	if !result.IsError {
		t.Fatal("a token with no yelukerest scopes was allowed to read")
	}
	if got := len(fake.recorded()); got != 0 {
		t.Fatalf("%d upstream calls, want 0 (no credential may be minted for an unauthorized caller)", got)
	}
}

// TestOAuthDiscoveryStillAdvertisesTheAuthorizationServer covers the RFC 9728
// side of the flow: an unauthenticated (or bad-token) request must point the
// client at the metadata document, and that document must name Hydra.
func TestOAuthDiscoveryStillAdvertisesTheAuthorizationServer(t *testing.T) {
	keyA, keyB := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	server, _ := newOAuthTestApp(t, jwks, "service-token")

	// An access token signed by a key the authorization server never
	// published is refused with a discoverable challenge.
	forged := signRS256(t, keyB, rs256Header("key-a"), hydraClaims())
	request, err := http.NewRequest(http.MethodPost, server.URL+mcpPath, strings.NewReader("{}"))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+forged)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", response.StatusCode)
	}
	if got := response.Header.Get("WWW-Authenticate"); !strings.Contains(got, "resource_metadata=") {
		t.Fatalf("WWW-Authenticate = %q", got)
	}

	metadata, err := http.Get(server.URL + protectedResourceMetadataPath + "/mcp")
	if err != nil {
		t.Fatalf("fetch metadata: %v", err)
	}
	defer metadata.Body.Close()
	var document protectedResourceMetadata
	if err := json.NewDecoder(metadata.Body).Decode(&document); err != nil {
		t.Fatalf("decode metadata: %v", err)
	}
	if document.Resource != testMCPResource {
		t.Fatalf("resource = %q", document.Resource)
	}
	if len(document.AuthorizationServers) != 1 || document.AuthorizationServers[0] != testHydraIssuer {
		t.Fatalf("authorization_servers = %v", document.AuthorizationServers)
	}
}

func TestMapExternalScopes(t *testing.T) {
	tests := []struct {
		granted []string
		want    string
	}{
		{granted: []string{"openid", "offline_access"}, want: ""},
		{granted: []string{"course:read", "course:read"}, want: "course:read"},
		{granted: []string{"submissions:write", "course:read"}, want: "submissions:write course:read"},
		{granted: []string{"read"}, want: "course:read grades:read submissions:read"},
		{granted: []string{"read", "course:read"}, want: "course:read grades:read submissions:read"},
		{granted: nil, want: ""},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprint(tt.granted), func(t *testing.T) {
			if got := strings.Join(mapExternalScopes(tt.granted), " "); got != tt.want {
				t.Fatalf("mapExternalScopes(%v) = %q, want %q", tt.granted, got, tt.want)
			}
		})
	}
}
