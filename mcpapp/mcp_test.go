package main

import (
	"bytes"
	"context"
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

// currentClaims returns claims that are valid at real wall-clock time, for
// end-to-end tests that go through newTokenVerifier (which uses time.Now).
func currentClaims() map[string]any {
	claims := validClaims()
	claims["iat"] = time.Now().Add(-time.Minute).Unix()
	claims["nbf"] = time.Now().Add(-time.Minute).Unix()
	claims["exp"] = time.Now().Add(time.Hour).Unix()
	return claims
}

func testAppConfig(rateLimit int) appConfig {
	return appConfig{
		JWT:                    testJWTConfig(),
		ResourceURL:            "https://example.com/mcp",
		MetadataURL:            "https://example.com/.well-known/oauth-protected-resource",
		AuthorizationServerURL: "",
		StatelessEnabled:       false,
		RateLimit:              rateLimit,
		RateWindow:             time.Minute,
	}
}

func newTestApp(t *testing.T, config appConfig) (*httptest.Server, *safeBuffer) {
	t.Helper()
	server, _, logs := newTestAppWithPostgREST(t, config)
	return server, logs
}

// newTestAppWithPostgREST builds the full HTTP stack backed by a fake
// PostgREST so tool round trips can assert on forwarded requests.
func newTestAppWithPostgREST(t *testing.T, config appConfig) (*httptest.Server, *fakePostgREST, *safeBuffer) {
	t.Helper()

	logs := &safeBuffer{}
	fake := newFakePostgREST(t)
	deps := &toolDeps{
		logger:    slog.New(slog.NewJSONHandler(logs, nil)),
		postgrest: fake.client(t),
		intent:    newIntentSigner([]byte(testSecret), time.Now),
	}
	server := httptest.NewServer(newMux(config, deps))
	t.Cleanup(server.Close)
	return server, fake, logs
}

// expectedToolNames is the deterministic tools/list order: the server sorts
// tools by name.
var expectedToolNames = []string{
	"commit_submission_change",
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
	"prepare_api_request",
	"prepare_submission_change",
	"whoami",
}

// writeCapableTools are the tools that must NOT carry readOnlyHint and must
// carry destructiveHint=true.
var writeCapableTools = map[string]bool{
	"commit_submission_change": true,
	"postgrest_request":        true,
}

func TestWhoamiOverStreamableHTTP(t *testing.T) {
	server, fake, logs := newTestAppWithPostgREST(t, testAppConfig(100))
	fake.respond("/users", fixtureUserRows)
	claims := currentClaims()
	claims["netid"] = "abc123"
	token := signTestToken(t, hs256Header(), claims, testSecret)

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

	// The user lookup forwarded the caller's own bearer token to PostgREST.
	recorded := fake.recorded()
	if len(recorded) != 1 || recorded[0].path != "/users" {
		t.Fatalf("PostgREST requests = %+v", recorded)
	}
	if recorded[0].auth != "Bearer "+token {
		t.Fatal("whoami did not forward the caller's bearer token to PostgREST")
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
	server, fake, _ := newTestAppWithPostgREST(t, testAppConfig(100))
	fake.respond("/assignments", fixtureAssignments)
	token := signTestToken(t, hs256Header(), currentClaims(), testSecret)

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
	if recorded[0].auth != "Bearer "+token {
		t.Fatal("list_assignments did not forward the caller's bearer token to PostgREST")
	}
	if recorded[0].query.Get("order") != "closed_at.asc,slug.asc" {
		t.Fatalf("order = %q", recorded[0].query.Get("order"))
	}
}

func TestMCPEndpointUnauthorized(t *testing.T) {
	server, _ := newTestApp(t, testAppConfig(100))

	expiredClaims := currentClaims()
	expiredClaims["exp"] = time.Now().Add(-time.Hour).Unix()
	wrongAudienceClaims := currentClaims()
	wrongAudienceClaims["aud"] = "yelukerest-postgrest"

	tests := []struct {
		name          string
		authorization string
	}{
		{name: "no authorization header", authorization: ""},
		{name: "not a bearer token", authorization: "Basic dXNlcjpwYXNz"},
		{name: "garbage token", authorization: "Bearer not.a.jwt"},
		{
			name:          "expired token",
			authorization: "Bearer " + signTestToken(t, hs256Header(), expiredClaims, testSecret),
		},
		{
			name:          "postgrest audience token",
			authorization: "Bearer " + signTestToken(t, hs256Header(), wrongAudienceClaims, testSecret),
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
	server, _ := newTestApp(t, testAppConfig(2))

	tokenFor := func(sub string) string {
		claims := currentClaims()
		claims["sub"] = sub
		return signTestToken(t, hs256Header(), claims, testSecret)
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

	tokenA := tokenFor("user:42")
	tokenB := tokenFor("user:43")

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
	server, _ := newTestApp(t, testAppConfig(100))

	resp, err := http.Get(server.URL + "/healthz")
	if err != nil {
		t.Fatalf("get /healthz: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
}
