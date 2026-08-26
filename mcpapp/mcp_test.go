package main

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// safeBuffer is a concurrency-safe bytes.Buffer for capturing slog output
// written from server goroutines.
type safeBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *safeBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// authTransport adds a bearer token to every outgoing request.
type authTransport struct {
	token string
}

func (t authTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	req.Header.Set("Authorization", "Bearer "+t.token)
	return http.DefaultTransport.RoundTrip(req)
}

// currentClaims returns internal-credential claims that are valid at real
// wall-clock time, for fixtures that pack a caller identity directly.
func currentClaims() map[string]any {
	claims := validClaims()
	claims["iat"] = time.Now().Add(-time.Minute).Unix()
	claims["nbf"] = time.Now().Add(-time.Minute).Unix()
	claims["exp"] = time.Now().Add(time.Hour).Unix()
	return claims
}

// testAppConfig is the deployment these end-to-end tests serve: OAuth only,
// with a fake authorization server publishing the key accessToken signs with.
func testAppConfig(t *testing.T, rateLimit int) appConfig {
	t.Helper()
	keyA, _ := hydraTestKeys(t)
	jwks := newFakeJWKS(t, map[string]*rsa.PrivateKey{"key-a": keyA})
	return appConfig{
		ResourceURL:            testMCPResource,
		MetadataURL:            "https://example.com/.well-known/oauth-protected-resource",
		AuthorizationServerURL: testHydraIssuer,
		Hydra: &hydraConfig{
			Issuer:   testHydraIssuer,
			JWKSURL:  jwks.server.URL,
			Audience: testMCPResource,
		},
		StatelessEnabled: false,
		RateLimit:        rateLimit,
		RateWindow:       time.Minute,
	}
}

// accessToken mints an OAuth access token the stack accepts: signed by the
// key testAppConfig's fake authorization server publishes, and valid at
// wall-clock time, which is what the verifier checks against.
func accessToken(t *testing.T, mutate func(map[string]any)) string {
	t.Helper()
	keyA, _ := hydraTestKeys(t)
	return currentHydraToken(t, keyA, mutate)
}

func newTestApp(t *testing.T, config appConfig) (*httptest.Server, *safeBuffer) {
	t.Helper()
	server, _, _, logs := newTestAppWithPostgREST(t, config)
	return server, logs
}

// newTestAppWithPostgREST builds the full HTTP stack backed by a fake
// PostgREST so tool round trips can assert on forwarded requests. Callers
// arrive over OAuth, so the stack also needs to exchange a verified token for
// an internal credential; that mint runs against a second fake, which keeps
// the mint call out of the request list the tool assertions read. The returned
// token is the credential tools must forward.
func newTestAppWithPostgREST(t *testing.T, config appConfig) (*httptest.Server, *fakePostgREST, string, *safeBuffer) {
	t.Helper()

	logs := &safeBuffer{}
	fake := newFakePostgREST(t)
	mint := newFakePostgREST(t)
	minted := internalTokenFor(t, "mint-e2e", time.Now().Add(10*time.Minute))
	mint.respondMethod(http.MethodPost, exchangeRPCPath, http.StatusOK, mintResponse(minted))
	deps := &toolDeps{
		logger:    slog.New(slog.NewJSONHandler(logs, nil)),
		postgrest: fake.client(t),
		exchanger: newTokenExchanger(mint.client(t), "service-token"),
	}
	server := httptest.NewServer(newMux(config, deps))
	t.Cleanup(server.Close)
	return server, fake, minted, logs
}

// expectedToolNames is the deterministic tools/list order: the server sorts
// tools by name.
var expectedToolNames = []string{
	"get_api_schema",
	"get_assignment",
	"get_my_engagements",
	"get_my_grades",
	"get_my_quiz_grades",
	"get_my_submissions",
	"list_assignments",
	"list_meetings",
	"list_quizzes",
	"postgrest_request",
	"preview_submission_change",
	"submit_submission_change",
	"whoami",
}

// writeCapableTools are the tools that must NOT carry readOnlyHint and must
// carry destructiveHint=true. preview_submission_change is deliberately not
// here: it resolves the same change submit_submission_change would make but
// never writes, so it advertises itself as read-only. Neither is
// postgrest_request: with escapeHatchWritesEnabled off, which is the default
// this test stack builds (issue #331), it refuses every mutating verb, so it
// advertises itself read-only too. escape_hatch_test.go covers both postures.
var writeCapableTools = map[string]bool{
	"submit_submission_change": true,
}

func TestWhoamiOverStreamableHTTP(t *testing.T) {
	server, fake, minted, logs := newTestAppWithPostgREST(t, testAppConfig(t, 100))
	fake.respond("/users", fixtureUserRows)
	token := accessToken(t, nil)

	ctx := context.Background()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.1"}, nil)
	session, err := client.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint:   server.URL + mcpPath,
		HTTPClient: &http.Client{Transport: authTransport{token: token}},
	}, nil)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer session.Close()

	toolList, err := session.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("tools/list: %v", err)
	}
	if len(toolList.Tools) != len(expectedToolNames) {
		t.Fatalf("tool count = %d, want %d", len(toolList.Tools), len(expectedToolNames))
	}
	for i, tool := range toolList.Tools {
		if tool.Name != expectedToolNames[i] {
			t.Fatalf("tools[%d] = %q, want %q (deterministic order)", i, tool.Name, expectedToolNames[i])
		}
		if tool.Annotations == nil {
			t.Fatalf("tool %q has no annotations", tool.Name)
		}
		if writeCapableTools[tool.Name] {
			if tool.Annotations.ReadOnlyHint {
				t.Fatalf("write tool %q must not carry readOnlyHint", tool.Name)
			}
			if tool.Annotations.DestructiveHint == nil || !*tool.Annotations.DestructiveHint {
				t.Fatalf("write tool %q is missing destructiveHint=true", tool.Name)
			}
		} else if !tool.Annotations.ReadOnlyHint {
			t.Fatalf("tool %q is missing readOnlyHint", tool.Name)
		}
		if tool.Annotations.OpenWorldHint == nil || *tool.Annotations.OpenWorldHint {
			t.Fatalf("tool %q is missing openWorldHint=false", tool.Name)
		}
		if tool.Description == "" {
			t.Fatalf("tool %q has no description", tool.Name)
		}
	}

	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "whoami"})
	if err != nil {
		t.Fatalf("tools/call: %v", err)
	}
	if result.IsError {
		t.Fatalf("whoami returned tool error: %+v", result.Content)
	}

	structured, err := json.Marshal(result.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structured content: %v", err)
	}
	var output whoamiOutput
	if err := json.Unmarshal(structured, &output); err != nil {
		t.Fatalf("unmarshal structured content: %v", err)
	}
	if output.Subject != "user:42" {
		t.Fatalf("sub = %q", output.Subject)
	}
	if output.UserID != "42" {
		t.Fatalf("user_id = %q", output.UserID)
	}
	if output.NetID != "abc123" {
		t.Fatalf("netid = %q", output.NetID)
	}
	if output.Role != "student" {
		t.Fatalf("role = %q", output.Role)
	}
	if output.Nickname != "fuzzy-bunny" {
		t.Fatalf("nickname = %q", output.Nickname)
	}
	if output.TeamNickname != "team-one" {
		t.Fatalf("team_nickname = %q", output.TeamNickname)
	}
	if output.DBRole != "student" {
		t.Fatalf("db_role = %q", output.DBRole)
	}

	// The user lookup forwarded the credential minted for this caller, never
	// the access token they presented.
	recorded := fake.recorded()
	if len(recorded) != 1 || recorded[0].path != "/users" {
		t.Fatalf("PostgREST requests = %+v", recorded)
	}
	if recorded[0].auth != "Bearer "+minted {
		t.Fatal("whoami did not forward the exchanged credential to PostgREST")
	}
	if strings.Contains(recorded[0].auth, token) {
		t.Fatal("whoami forwarded the OAuth access token to PostgREST")
	}

	// Audit log assertions: subject and tool name are present; token
	// material is not.
	logText := logs.String()
	if !strings.Contains(logText, `"tool":"whoami"`) {
		t.Fatalf("logs missing tool name: %s", logText)
	}
	if !strings.Contains(logText, `"subject":"user:42"`) {
		t.Fatalf("logs missing subject: %s", logText)
	}
	if strings.Contains(logText, token) {
		t.Fatal("logs contain the bearer token")
	}
	if strings.Contains(logText, testSecret) {
		t.Fatal("logs contain the JWT secret")
	}
	if strings.Contains(logText, "Authorization") {
		t.Fatal("logs contain an Authorization header")
	}
}

func TestListAssignmentsOverStreamableHTTP(t *testing.T) {
	server, fake, minted, _ := newTestAppWithPostgREST(t, testAppConfig(t, 100))
	fake.respond("/assignments", fixtureAssignments)
	token := accessToken(t, nil)

	ctx := context.Background()
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.1"}, nil)
	session, err := client.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint:   server.URL + mcpPath,
		HTTPClient: &http.Client{Transport: authTransport{token: token}},
	}, nil)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer session.Close()

	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "list_assignments"})
	if err != nil {
		t.Fatalf("tools/call: %v", err)
	}
	if result.IsError {
		t.Fatalf("list_assignments returned tool error: %+v", result.Content)
	}

	structured, err := json.Marshal(result.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structured content: %v", err)
	}
	var output listAssignmentsOutput
	if err := json.Unmarshal(structured, &output); err != nil {
		t.Fatalf("unmarshal structured content: %v", err)
	}
	if output.TotalCount != 1 || output.Truncated || len(output.Assignments) != 1 {
		t.Fatalf("output = %+v", output)
	}
	if output.Assignments[0].Slug != "proj1" || !output.Assignments[0].IsOpen {
		t.Fatalf("assignment = %+v", output.Assignments[0])
	}

	recorded := fake.recorded()
	if len(recorded) != 1 || recorded[0].path != "/assignments" {
		t.Fatalf("PostgREST requests = %+v", recorded)
	}
	if recorded[0].auth != "Bearer "+minted {
		t.Fatal("list_assignments did not forward the exchanged credential to PostgREST")
	}
	if recorded[0].query.Get("order") != "closed_at.asc,slug.asc" {
		t.Fatalf("order = %q", recorded[0].query.Get("order"))
	}
}

func TestMCPEndpointUnauthorized(t *testing.T) {
	server, _ := newTestApp(t, testAppConfig(t, 100))

	tests := []struct {
		name          string
		authorization string
	}{
		{name: "no authorization header", authorization: ""},
		{name: "not a bearer token", authorization: "Basic dXNlcjpwYXNz"},
		{name: "garbage token", authorization: "Bearer not.a.jwt"},
		{
			name: "expired token",
			authorization: "Bearer " + accessToken(t, func(claims map[string]any) {
				claims["exp"] = time.Now().Add(-time.Hour).Unix()
			}),
		},
		{
			name: "token for another resource",
			authorization: "Bearer " + accessToken(t, func(claims map[string]any) {
				claims["aud"] = []any{"https://example.com/somewhere-else"}
			}),
		},
		{
			// The retired phase 0 credential (issue #322): an internally
			// signed HS256 token with claims that once opened /mcp. It gets a
			// 401 like anything else unusable, and the body says nothing
			// about the credential class having existed.
			name:          "internally signed HS256 token",
			authorization: "Bearer " + signTestToken(t, hs256Header(), currentClaims(), testSecret),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodPost, server.URL+mcpPath, strings.NewReader("{}"))
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			if tt.authorization != "" {
				req.Header.Set("Authorization", tt.authorization)
			}

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("do request: %v", err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusUnauthorized)
			}
			wwwAuthenticate := resp.Header.Get("WWW-Authenticate")
			if !strings.Contains(wwwAuthenticate, `resource_metadata="https://example.com/.well-known/oauth-protected-resource"`) {
				t.Fatalf("WWW-Authenticate = %q", wwwAuthenticate)
			}
			if !strings.HasPrefix(wwwAuthenticate, "Bearer") {
				t.Fatalf("WWW-Authenticate = %q, want Bearer scheme", wwwAuthenticate)
			}
			if got := resp.Header.Get("Cache-Control"); got != "no-store" {
				t.Fatalf("Cache-Control = %q, want no-store", got)
			}
		})
	}
}

func TestMCPEndpointRateLimitsPerSubject(t *testing.T) {
	server, _ := newTestApp(t, testAppConfig(t, 2))

	// The limiter keys on the subject the token resolves to, which for these
	// tokens is "user:<user_id>".
	tokenFor := func(userID string) string {
		return accessToken(t, func(claims map[string]any) {
			claims["user_id"] = json.Number(userID)
			claims["ext"] = map[string]any{"netid": "abc123", "user_id": json.Number(userID), "role": "student"}
		})
	}
	post := func(token string) int {
		t.Helper()
		req, err := http.NewRequest(http.MethodPost, server.URL+mcpPath, strings.NewReader("{}"))
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("do request: %v", err)
		}
		defer resp.Body.Close()
		return resp.StatusCode
	}

	tokenA := tokenFor("42")
	tokenB := tokenFor("43")

	// Two requests for subject A pass the limiter; the third is rejected.
	for i := range 2 {
		if status := post(tokenA); status == http.StatusTooManyRequests {
			t.Fatalf("request %d for subject A was rate limited", i+1)
		}
	}
	if status := post(tokenA); status != http.StatusTooManyRequests {
		t.Fatalf("third request for subject A: status = %d, want %d", status, http.StatusTooManyRequests)
	}

	// Subject B is unaffected even though requests come from the same client.
	if status := post(tokenB); status == http.StatusTooManyRequests {
		t.Fatal("request for subject B was rate limited")
	}
}

func TestWhoamiWithoutVerifiedIdentityIsToolError(t *testing.T) {
	// Over an in-memory transport there is no HTTP bearer middleware, so no
	// verified identity reaches the handler and whoami must fail closed.
	logs := &safeBuffer{}
	deps := &toolDeps{
		logger:    slog.New(slog.NewJSONHandler(logs, nil)),
		postgrest: newPostgRESTClient("postgrest", "3000"),
	}
	server := newMCPServer(deps)

	ctx := context.Background()
	clientTransport, serverTransport := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer serverSession.Close()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.1"}, nil)
	session, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer session.Close()

	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "whoami"})
	if err != nil {
		t.Fatalf("tools/call: %v", err)
	}
	if !result.IsError {
		t.Fatal("whoami without identity should be a tool error")
	}
	if !strings.Contains(logs.String(), `"outcome":"tool_error"`) {
		t.Fatalf("logs missing tool_error outcome: %s", logs.String())
	}
}

func TestHealthEndpoint(t *testing.T) {
	server, _ := newTestApp(t, testAppConfig(t, 100))

	resp, err := http.Get(server.URL + "/healthz")
	if err != nil {
		t.Fatalf("get /healthz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
}
