package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// testMCPTokenConfig points the handler at a fake PostgREST.
func testMCPTokenConfig(t *testing.T, handler http.HandlerFunc) MCPTokenConfig {
	t.Helper()

	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse test server URL: %v", err)
	}
	host, port, err := net.SplitHostPort(serverURL.Host)
	if err != nil {
		t.Fatalf("split test server host: %v", err)
	}

	return MCPTokenConfig{
		PostgrestHost: host,
		PostgrestPort: port,
		MCPAppJWT:     "mcpapp-service-token",
	}
}

// mintedTestToken builds an unsigned JWT shaped like the one
// auth.sign_mcp_user_jwt returns.
func mintedTestToken(t *testing.T, scopes string, expiresAt time.Time) string {
	t.Helper()

	return testJWT(t, map[string]any{
		"iss":     "yelukerest",
		"aud":     "yelukerest-postgrest",
		"sub":     "user:42",
		"user_id": 42,
		"role":    "student",
		"netid":   "abc123",
		"scopes":  scopes,
		"iat":     expiresAt.Add(-10 * time.Minute).Unix(),
		"nbf":     expiresAt.Add(-10 * time.Minute).Unix(),
		"jti":     "00000000-0000-0000-0000-000000000000",
		"exp":     expiresAt.Unix(),
	})
}

func mcpTokenRequest(scopes string) *http.Request {
	target := "http://example.test/auth/mcp-token"
	if scopes != "" {
		target += "?scopes=" + url.QueryEscape(scopes)
	}
	req := httptest.NewRequest(http.MethodGet, target, nil)
	return req.WithContext(context.WithValue(req.Context(), "netid", "abc123"))
}

func TestIssueUserJWTForMCPURL(t *testing.T) {
	config := MCPTokenConfig{
		PostgrestHost: "postgrest",
		PostgrestPort: "3000",
	}

	got := issueUserJWTForMCPURL(config)

	if got != "http://postgrest:3000/rpc/issue_user_jwt_for_mcp" {
		t.Fatalf("issueUserJWTForMCPURL = %q", got)
	}
}

func TestParseRequestedScopes(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    []string
		wantErr string
	}{
		{
			name: "empty request defaults to read-only",
			raw:  "",
			want: []string{"course:read", "grades:read", "submissions:read"},
		},
		{
			name: "whitespace only defaults to read-only",
			raw:  "   ",
			want: []string{"course:read", "grades:read", "submissions:read"},
		},
		{
			name: "space separated",
			raw:  "course:read grades:read",
			want: []string{"course:read", "grades:read"},
		},
		{
			name: "comma separated",
			raw:  "course:read,grades:read",
			want: []string{"course:read", "grades:read"},
		},
		{
			name: "plus separated",
			raw:  "course:read+grades:read",
			want: []string{"course:read", "grades:read"},
		},
		{
			name: "duplicates collapse",
			raw:  "course:read course:read",
			want: []string{"course:read"},
		},
		{
			name: "write scope granted only when asked for",
			raw:  "submissions:write",
			want: []string{"submissions:write"},
		},
		{
			name:    "unknown scope rejected",
			raw:     "course:read admin:everything",
			wantErr: "unknown scope",
		},
		{
			name:    "malformed scope rejected before the allowlist",
			raw:     "Course:Read",
			wantErr: "malformed scope",
		},
		{
			name:    "leading digit is malformed",
			raw:     "1course",
			wantErr: "malformed scope",
		},
		{
			name:    "over-long scope list rejected",
			raw:     strings.Repeat("course:read ", 17),
			wantErr: "at most 16 scopes",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseRequestedScopes(tt.raw)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error, got %v", got)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error = %q, want substring %q", err.Error(), tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseRequestedScopes(%q) error = %v", tt.raw, err)
			}
			if strings.Join(got, " ") != strings.Join(tt.want, " ") {
				t.Fatalf("scopes = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestParseRequestedScopesDefaultsAreReadOnly(t *testing.T) {
	scopes, err := parseRequestedScopes("")
	if err != nil {
		t.Fatalf("parseRequestedScopes error = %v", err)
	}
	for _, scope := range scopes {
		if strings.HasSuffix(scope, ":write") {
			t.Fatalf("default scopes include a write scope: %v", scopes)
		}
	}
}

func TestGetMCPTokenHandlerSendsExpectedRPC(t *testing.T) {
	expiresAt := time.Now().Add(10 * time.Minute)
	config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.Method; got != http.MethodPost {
			t.Errorf("method = %q", got)
		}
		if got := r.URL.Path; got != "/rpc/issue_user_jwt_for_mcp" {
			t.Errorf("path = %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer mcpapp-service-token" {
			t.Errorf("Authorization header = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "application/vnd.pgrst.object+json" {
			t.Errorf("Accept header = %q", got)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("Content-Type header = %q", got)
		}

		var body struct {
			NetID    string            `json:"p_netid"`
			Scopes   []string          `json:"p_scopes"`
			External map[string]string `json:"p_external"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if body.NetID != "abc123" {
			t.Errorf("p_netid = %q", body.NetID)
		}
		if strings.Join(body.Scopes, " ") != "course:read submissions:write" {
			t.Errorf("p_scopes = %v", body.Scopes)
		}
		if body.External["iss"] != "authapp" {
			t.Errorf("p_external.iss = %q", body.External["iss"])
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(mcpMintResult{
			JWT:    mintedTestToken(t, "course:read submissions:write", expiresAt),
			UserID: 42,
			NetID:  "abc123",
			Role:   "student",
		})
	})

	recorder := httptest.NewRecorder()
	getMCPTokenHandler(config).ServeHTTP(recorder, mcpTokenRequest("course:read submissions:write"))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	assertNoStoreHeaders(t, recorder.Result())

	var response mcpTokenResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Token == "" {
		t.Fatal("token is empty")
	}
	if response.TokenType != "Bearer" {
		t.Fatalf("token_type = %q", response.TokenType)
	}
	if response.ExpiresIn <= 0 || response.ExpiresIn > mcpTokenDefaultTTLSeconds {
		t.Fatalf("expires_in = %d, want (0, %d]", response.ExpiresIn, mcpTokenDefaultTTLSeconds)
	}
	if strings.Join(response.Scopes, " ") != "course:read submissions:write" {
		t.Fatalf("scopes = %v", response.Scopes)
	}
}

func TestGetMCPTokenHandlerDefaultsToReadOnlyScopes(t *testing.T) {
	var seen []string
	config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Scopes []string `json:"p_scopes"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		seen = body.Scopes

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(mcpMintResult{
			JWT:   mintedTestToken(t, strings.Join(body.Scopes, " "), time.Now().Add(10*time.Minute)),
			NetID: "abc123",
			Role:  "student",
		})
	})

	recorder := httptest.NewRecorder()
	getMCPTokenHandler(config).ServeHTTP(recorder, mcpTokenRequest(""))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	for _, scope := range seen {
		if strings.HasSuffix(scope, ":write") {
			t.Fatalf("default request asked for a write scope: %v", seen)
		}
	}
	if len(seen) == 0 {
		t.Fatal("no scopes were requested")
	}
}

func TestGetMCPTokenHandlerRejectsBadScopes(t *testing.T) {
	tests := []struct {
		name   string
		scopes string
		want   string
	}{
		{name: "unknown scope", scopes: "admin:everything", want: "unknown scope"},
		{name: "malformed scope", scopes: "BAD SCOPE", want: "malformed scope"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
				t.Error("postgrest should not be called for an invalid scope request")
			})

			recorder := httptest.NewRecorder()
			getMCPTokenHandler(config).ServeHTTP(recorder, mcpTokenRequest(tt.scopes))

			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", recorder.Code, http.StatusBadRequest)
			}
			if !strings.Contains(recorder.Body.String(), tt.want) {
				t.Fatalf("body = %q, want substring %q", recorder.Body.String(), tt.want)
			}
			assertNoStoreHeaders(t, recorder.Result())
		})
	}
}

func TestGetMCPTokenHandlerRequiresSession(t *testing.T) {
	config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("postgrest should not be called without a session")
	})

	// The handler itself refuses an empty netid...
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/mcp-token", nil)
	req = req.WithContext(context.WithValue(req.Context(), "netid", ""))
	getMCPTokenHandler(config).ServeHTTP(recorder, req)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusUnauthorized)
	}
	assertNoStoreHeaders(t, recorder.Result())

	// ...and the session middleware refuses a request with no session at
	// all, exactly as it does for /auth/me and /auth/jwt.
	sessionManager := newSessionManager(true)
	guarded := sessionManager.LoadAndSave(getSessionMiddleware(sessionManager, getMCPTokenHandler(config)))
	recorder = httptest.NewRecorder()
	guarded.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "http://example.test/auth/mcp-token", nil))
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("middleware status = %d, want %d", recorder.Code, http.StatusUnauthorized)
	}
}

func TestGetMCPTokenHandlerWithoutServiceCredential(t *testing.T) {
	config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("postgrest should not be called without MCPAPP_JWT")
	})
	config.MCPAppJWT = ""

	recorder := httptest.NewRecorder()
	getMCPTokenHandler(config).ServeHTTP(recorder, mcpTokenRequest(""))

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
	if !strings.Contains(recorder.Body.String(), "not configured") {
		t.Fatalf("body = %q", recorder.Body.String())
	}
	assertNoStoreHeaders(t, recorder.Result())
}

func TestGetMCPTokenHandlerRejectsNonGET(t *testing.T) {
	config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("postgrest should not be called for a disallowed method")
	})

	req := httptest.NewRequest(http.MethodPost, "http://example.test/auth/mcp-token", nil)
	req = req.WithContext(context.WithValue(req.Context(), "netid", "abc123"))
	recorder := httptest.NewRecorder()
	getMCPTokenHandler(config).ServeHTTP(recorder, req)

	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusMethodNotAllowed)
	}
	if got := recorder.Header().Get("Allow"); got != "GET, HEAD" {
		t.Fatalf("Allow = %q", got)
	}
}

func TestMintMCPUserJWTMapsPostgRESTStatuses(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
		wantStatus int
	}{
		{
			name:       "unknown netid returns no rows",
			statusCode: http.StatusNotAcceptable,
			body:       `{"code":"PGRST116"}`,
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "policy refusal",
			statusCode: http.StatusForbidden,
			body:       `{"code":"42501","message":"users with role observer are not mintable for MCP"}`,
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "service jwt rejected",
			statusCode: http.StatusUnauthorized,
			body:       `{"code":"PGRST301"}`,
			wantStatus: http.StatusBadGateway,
		},
		{
			name:       "bad parameters are an authapp bug",
			statusCode: http.StatusBadRequest,
			body:       `{"code":"22023","message":"malformed scope"}`,
			wantStatus: http.StatusInternalServerError,
		},
		{
			name:       "malformed success body",
			statusCode: http.StatusOK,
			body:       `not json`,
			wantStatus: http.StatusBadGateway,
		},
		{
			name:       "empty jwt in success body",
			statusCode: http.StatusOK,
			body:       `{"jwt":""}`,
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "unexpected postgrest failure",
			statusCode: http.StatusInternalServerError,
			body:       `{"code":"PGRST000"}`,
			wantStatus: http.StatusBadGateway,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tt.statusCode)
				_, _ = w.Write([]byte(tt.body))
			})

			_, err, status := mintMCPUserJWT("abc123", []string{"course:read"}, config)
			if err == nil {
				t.Fatal("expected error")
			}
			if status != tt.wantStatus {
				t.Fatalf("status = %d, want %d", status, tt.wantStatus)
			}
		})
	}
}

func TestGetMCPTokenHandlerDoesNotExposeUpstreamErrorBody(t *testing.T) {
	config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"detail":"internal table name"}`))
	})

	recorder := httptest.NewRecorder()
	getMCPTokenHandler(config).ServeHTTP(recorder, mcpTokenRequest(""))

	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusBadGateway)
	}
	if strings.Contains(recorder.Body.String(), "internal table name") {
		t.Fatalf("response body leaked upstream detail: %q", recorder.Body.String())
	}
}

func TestMCPTokenRateLimiting(t *testing.T) {
	config := testMCPTokenConfig(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(mcpMintResult{
			JWT:   mintedTestToken(t, "course:read", time.Now().Add(10*time.Minute)),
			NetID: "abc123",
			Role:  "student",
		})
	})

	const limit = 3
	handler := rateLimitMiddleware(newRateLimiter(limit, time.Minute), getMCPTokenHandler(config))
	for i := 0; i < limit; i++ {
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, mcpTokenRequest(""))
		if recorder.Code != http.StatusOK {
			t.Fatalf("request %d status = %d, body = %q", i, recorder.Code, recorder.Body.String())
		}
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, mcpTokenRequest(""))
	if recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusTooManyRequests)
	}
	assertNoStoreHeaders(t, recorder.Result())
}

func TestMCPTokenExpiresIn(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)

	tests := []struct {
		name  string
		token string
		want  int64
	}{
		{
			name:  "reads the exp claim",
			token: mintedTestToken(t, "course:read", now.Add(600*time.Second)),
			want:  600,
		},
		{
			name:  "already expired clamps to zero",
			token: mintedTestToken(t, "course:read", now.Add(-time.Minute)),
			want:  0,
		},
		{
			name:  "unparseable token falls back to the documented ttl",
			token: "not-a-jwt",
			want:  mcpTokenDefaultTTLSeconds,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := mcpTokenExpiresIn(tt.token, now); got != tt.want {
				t.Fatalf("mcpTokenExpiresIn = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestMCPTokenScopes(t *testing.T) {
	requested := []string{"course:read"}

	tests := []struct {
		name  string
		token string
		want  string
	}{
		{
			name:  "prefers the granted scopes claim",
			token: mintedTestToken(t, "grades:read submissions:read", time.Now().Add(time.Minute)),
			want:  "grades:read submissions:read",
		},
		{
			name:  "falls back to the request when unparseable",
			token: "not-a-jwt",
			want:  "course:read",
		},
		{
			name:  "falls back when the claim is empty",
			token: mintedTestToken(t, "", time.Now().Add(time.Minute)),
			want:  "course:read",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := strings.Join(mcpTokenScopes(tt.token, requested), " ")
			if got != tt.want {
				t.Fatalf("mcpTokenScopes = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestValidateMCPAppJWT(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)

	tests := []struct {
		name    string
		claims  map[string]any
		wantErr string
	}{
		{
			name: "valid mcpapp token",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      "yelukerest-postgrest",
				"sub":      "app:mcpapp",
				"role":     "app",
				"app_name": "mcpapp",
				"iat":      now.Unix(),
				"nbf":      now.Unix(),
				"exp":      now.Add(time.Hour).Unix(),
			},
		},
		{
			name: "authapp credential is not accepted here",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      "yelukerest-postgrest",
				"sub":      "app:authapp",
				"role":     "app",
				"app_name": "authapp",
				"iat":      now.Unix(),
				"nbf":      now.Unix(),
				"exp":      now.Add(time.Hour).Unix(),
			},
			wantErr: `MCPAPP_JWT app_name claim must be "mcpapp"`,
		},
		{
			name: "subject must name the app",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      "yelukerest-postgrest",
				"sub":      "user:1",
				"role":     "app",
				"app_name": "mcpapp",
				"iat":      now.Unix(),
				"nbf":      now.Unix(),
				"exp":      now.Add(time.Hour).Unix(),
			},
			wantErr: `MCPAPP_JWT sub claim must be "app:mcpapp"`,
		},
		{
			name: "expired token",
			claims: map[string]any{
				"iss":      "yelukerest",
				"aud":      "yelukerest-postgrest",
				"sub":      "app:mcpapp",
				"role":     "app",
				"app_name": "mcpapp",
				"iat":      now.Add(-2 * time.Hour).Unix(),
				"nbf":      now.Add(-2 * time.Hour).Unix(),
				"exp":      now.Add(-time.Hour).Unix(),
			},
			wantErr: "MCPAPP_JWT exp is not in the future",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateMCPAppJWT(testJWT(t, tt.claims), "yelukerest", "yelukerest-postgrest", now)
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("validateMCPAppJWT error = %v", err)
				}
				return
			}
			if err == nil {
				t.Fatal("expected error")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("error = %q, want substring %q", err.Error(), tt.wantErr)
			}
		})
	}
}
