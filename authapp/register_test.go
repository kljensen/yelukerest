package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

// newFakeHydra returns an httptest server that records the last request
// it saw and replies with a fixed status/body.
type fakeHydra struct {
	server      *httptest.Server
	status      int
	contentType string
	body        string

	lastMethod string
	lastPath   string
	lastBody   string
	lastAuth   string
	calls      int
}

func newFakeHydra(status int, contentType string, body string) *fakeHydra {
	fake := &fakeHydra{status: status, contentType: contentType, body: body}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestBody, _ := io.ReadAll(r.Body)
		fake.calls++
		fake.lastMethod = r.Method
		fake.lastPath = r.URL.Path
		fake.lastBody = string(requestBody)
		fake.lastAuth = r.Header.Get("Authorization")
		if fake.contentType != "" {
			w.Header().Set("Content-Type", fake.contentType)
		}
		w.Header().Set("X-Fake-Hydra", "1")
		w.WriteHeader(fake.status)
		fmt.Fprint(w, fake.body)
	}))
	return fake
}

func newTestRegisterHandler(fake *fakeHydra, limit int) http.Handler {
	return getRegisterProxyHandler(registerProxyConfig{
		HydraPublicURL: fake.server.URL,
		Client:         fake.server.Client(),
	}, newRateLimiter(limit, time.Minute))
}

func newTestRegisterHandlerWithAudience(fake *fakeHydra, audience string) http.Handler {
	return getRegisterProxyHandler(registerProxyConfig{
		HydraPublicURL: fake.server.URL,
		MCPAudience:    audience,
		Client:         fake.server.Client(),
	}, newRateLimiter(100, time.Minute))
}

func mustJSONEqual(t *testing.T, got []byte, want string) {
	t.Helper()
	var gotValue, wantValue any
	if err := json.Unmarshal(got, &gotValue); err != nil {
		t.Fatalf("response is not JSON: %v\nbody: %s", err, got)
	}
	if err := json.Unmarshal([]byte(want), &wantValue); err != nil {
		t.Fatalf("want is not JSON: %v", err)
	}
	if !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("cleaned JSON mismatch\ngot:  %s\nwant: %s", got, want)
	}
}

func TestRegisterProxyCleansResponse(t *testing.T) {
	tests := []struct {
		name         string
		upstreamBody string
		want         string
	}{
		{
			name:         "null fields are removed",
			upstreamBody: `{"client_id":"abc","contacts":null,"skip_logout_consent":null,"refresh_token_grant_id_token_lifespan":null}`,
			want:         `{"client_id":"abc"}`,
		},
		{
			name:         "empty optional string fields are removed",
			upstreamBody: `{"client_id":"abc","client_uri":"","logo_uri":"","tos_uri":"","policy_uri":"","owner":""}`,
			want:         `{"client_id":"abc"}`,
		},
		{
			name:         "populated optional uri fields are kept",
			upstreamBody: `{"client_id":"abc","client_uri":"https://example.com","logo_uri":"https://example.com/logo.png"}`,
			want:         `{"client_id":"abc","client_uri":"https://example.com","logo_uri":"https://example.com/logo.png"}`,
		},
		{
			name:         "empty optional arrays are removed",
			upstreamBody: `{"client_id":"abc","contacts":[],"allowed_cors_origins":[],"audience":[]}`,
			want:         `{"client_id":"abc"}`,
		},
		{
			name:         "populated contacts and audience are kept",
			upstreamBody: `{"client_id":"abc","contacts":["ops@example.com"],"audience":["https://localhost/mcp"]}`,
			want:         `{"client_id":"abc","contacts":["ops@example.com"],"audience":["https://localhost/mcp"]}`,
		},
		{
			name:         "empty optional objects are removed",
			upstreamBody: `{"client_id":"abc","jwks":{},"metadata":{}}`,
			want:         `{"client_id":"abc"}`,
		},
		{
			name:         "empty values outside the optional-field lists are kept",
			upstreamBody: `{"client_id":"abc","scope":"","redirect_uris":[],"future_object":{}}`,
			want:         `{"client_id":"abc","scope":"","redirect_uris":[],"future_object":{}}`,
		},
		{
			// metadata is opaque client-controlled data: cleaning inside it
			// would silently mutate values the client set deliberately.
			name:         "client metadata passes through untouched",
			upstreamBody: `{"client_id":"abc","metadata":{"note":null,"keep":"x","inner":{"gone":null}}}`,
			want:         `{"client_id":"abc","metadata":{"note":null,"keep":"x","inner":{"gone":null}}}`,
		},
		{
			name:         "metadata containing only nulls is still preserved",
			upstreamBody: `{"client_id":"abc","metadata":{"note":null}}`,
			want:         `{"client_id":"abc","metadata":{"note":null}}`,
		},
		{
			name:         "metadata emitted empty by hydra is removed",
			upstreamBody: `{"client_id":"abc","metadata":{}}`,
			want:         `{"client_id":"abc"}`,
		},
		{
			name:         "unknown fields and meaningful zero values pass through",
			upstreamBody: `{"client_id":"abc","client_secret_expires_at":0,"future_field":{"a":[1,2,3]}}`,
			want:         `{"client_id":"abc","client_secret_expires_at":0,"future_field":{"a":[1,2,3]}}`,
		},
		{
			name: "realistic hydra response",
			upstreamBody: `{"client_id":"e64a","client_name":"probe","redirect_uris":["http://localhost:33418/callback"],` +
				`"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"scope":"openid offline_access",` +
				`"audience":[],"owner":"","policy_uri":"","allowed_cors_origins":[],"tos_uri":"","client_uri":"","logo_uri":"",` +
				`"contacts":null,"client_secret_expires_at":0,"subject_type":"public","jwks":{},"metadata":{},"token_endpoint_auth_method":"none",` +
				`"skip_logout_consent":null,"authorization_code_grant_access_token_lifespan":null,` +
				`"device_authorization_grant_refresh_token_lifespan":null}`,
			want: `{"client_id":"e64a","client_name":"probe","redirect_uris":["http://localhost:33418/callback"],` +
				`"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"scope":"openid offline_access",` +
				`"client_secret_expires_at":0,"subject_type":"public","token_endpoint_auth_method":"none"}`,
		},
		{
			name: "realistic hydra response with injected audience keeps it",
			upstreamBody: `{"client_id":"e64a","audience":["https://localhost/mcp"],"owner":"","contacts":null,` +
				`"jwks":{},"client_secret_expires_at":0}`,
			want: `{"client_id":"e64a","audience":["https://localhost/mcp"],"client_secret_expires_at":0}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newFakeHydra(http.StatusCreated, "application/json", test.upstreamBody)
			defer fake.server.Close()
			handler := newTestRegisterHandler(fake, 100)

			request := httptest.NewRequest(http.MethodPost, "http://example.test/oauth2/register",
				strings.NewReader(`{"redirect_uris":["https://example.com/cb"]}`))
			request.RemoteAddr = "192.0.2.1:1234"
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusCreated {
				t.Fatalf("status = %d, want %d; body: %s", recorder.Code, http.StatusCreated, recorder.Body.String())
			}
			mustJSONEqual(t, recorder.Body.Bytes(), test.want)
			if got := recorder.Header().Get("X-Fake-Hydra"); got != "1" {
				t.Fatalf("upstream headers were not copied; X-Fake-Hydra = %q", got)
			}
		})
	}
}

func TestRegisterProxyPassesThroughErrors(t *testing.T) {
	tests := []struct {
		name         string
		status       int
		contentType  string
		upstreamBody string
	}{
		{
			name:         "400 body with nulls is untouched",
			status:       http.StatusBadRequest,
			contentType:  "application/json",
			upstreamBody: `{"error":"invalid_client_metadata","error_description":null}`,
		},
		{
			name:         "500 body is untouched",
			status:       http.StatusInternalServerError,
			contentType:  "application/json",
			upstreamBody: `{"error":"server_error","contacts":null}`,
		},
		{
			name:         "non-json 2xx body is untouched",
			status:       http.StatusOK,
			contentType:  "text/plain",
			upstreamBody: `null null null`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newFakeHydra(test.status, test.contentType, test.upstreamBody)
			defer fake.server.Close()
			handler := newTestRegisterHandler(fake, 100)

			request := httptest.NewRequest(http.MethodPost, "http://example.test/oauth2/register",
				strings.NewReader(`{"redirect_uris":["https://example.com/cb"]}`))
			request.RemoteAddr = "192.0.2.1:1234"
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != test.status {
				t.Fatalf("status = %d, want %d", recorder.Code, test.status)
			}
			if recorder.Body.String() != test.upstreamBody {
				t.Fatalf("body was modified\ngot:  %s\nwant: %s", recorder.Body.String(), test.upstreamBody)
			}
		})
	}
}

func TestRegisterProxyRejectsBadPayloads(t *testing.T) {
	manyURIs := make([]string, 11)
	for i := range manyURIs {
		manyURIs[i] = fmt.Sprintf("https://example.com/cb%d", i)
	}
	manyURIsJSON, _ := json.Marshal(map[string]any{"redirect_uris": manyURIs})

	tests := []struct {
		name      string
		body      string
		wantError string
	}{
		{
			name:      "more than 10 redirect uris",
			body:      string(manyURIsJSON),
			wantError: "invalid_redirect_uri",
		},
		{
			name:      "redirect uri too long",
			body:      `{"redirect_uris":["https://example.com/` + strings.Repeat("a", 2001) + `"]}`,
			wantError: "invalid_redirect_uri",
		},
		{
			name:      "plain http non-loopback",
			body:      `{"redirect_uris":["http://example.com/cb"]}`,
			wantError: "invalid_redirect_uri",
		},
		{
			name:      "http localhost lookalike host",
			body:      `{"redirect_uris":["http://localhost.evil.com/cb"]}`,
			wantError: "invalid_redirect_uri",
		},
		{
			name:      "non-http scheme",
			body:      `{"redirect_uris":["ftp://example.com/cb"]}`,
			wantError: "invalid_redirect_uri",
		},
		{
			name:      "not json",
			body:      `redirect_uris=https://example.com`,
			wantError: "invalid_client_metadata",
		},
		{
			name:      "empty body",
			body:      ``,
			wantError: "invalid_client_metadata",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newFakeHydra(http.StatusCreated, "application/json", `{}`)
			defer fake.server.Close()
			handler := newTestRegisterHandler(fake, 100)

			request := httptest.NewRequest(http.MethodPost, "http://example.test/oauth2/register", strings.NewReader(test.body))
			request.RemoteAddr = "192.0.2.1:1234"
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d; body: %s", recorder.Code, http.StatusBadRequest, recorder.Body.String())
			}
			var payload map[string]string
			if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
				t.Fatalf("error response is not JSON: %v", err)
			}
			if payload["error"] != test.wantError {
				t.Fatalf("error = %q, want %q (description: %q)", payload["error"], test.wantError, payload["error_description"])
			}
			if fake.calls != 0 {
				t.Fatalf("rejected payload reached Hydra (%d calls)", fake.calls)
			}
		})
	}
}

func TestRegisterProxyAcceptsLoopbackAndHTTPSRedirects(t *testing.T) {
	tests := []string{
		`{"redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}`,
		`{"redirect_uris":["http://localhost:33418/callback"]}`,
		`{"redirect_uris":["http://127.0.0.1:8976/oauth/callback"]}`,
		`{"client_name":"no redirect uris at all"}`,
	}
	for _, body := range tests {
		t.Run(body, func(t *testing.T) {
			fake := newFakeHydra(http.StatusCreated, "application/json", `{"client_id":"abc"}`)
			defer fake.server.Close()
			handler := newTestRegisterHandler(fake, 100)

			request := httptest.NewRequest(http.MethodPost, "http://example.test/oauth2/register", strings.NewReader(body))
			request.RemoteAddr = "192.0.2.1:1234"
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusCreated {
				t.Fatalf("status = %d, want %d; body: %s", recorder.Code, http.StatusCreated, recorder.Body.String())
			}
			if fake.calls != 1 {
				t.Fatalf("expected exactly one upstream call, got %d", fake.calls)
			}
			if fake.lastBody != body {
				t.Fatalf("upstream body = %q, want %q", fake.lastBody, body)
			}
		})
	}
}

func TestRegisterProxyInjectsAudience(t *testing.T) {
	const audience = "https://localhost/mcp"
	tests := []struct {
		name         string
		method       string
		path         string
		body         string
		wantAudience []any
		wantVerbatim bool // upstream body must be byte-identical to the request
	}{
		{
			name:         "POST without audience gets the MCP audience",
			method:       http.MethodPost,
			path:         "/oauth2/register",
			body:         `{"client_name":"claude","redirect_uris":["https://claude.ai/cb"]}`,
			wantAudience: []any{audience},
		},
		{
			name:         "POST with empty audience array gets the MCP audience",
			method:       http.MethodPost,
			path:         "/oauth2/register",
			body:         `{"client_name":"claude","audience":[]}`,
			wantAudience: []any{audience},
		},
		{
			// Client entries are preserved, but ours must be appended:
			// Hydra re-checks the granted audience against this allowlist
			// at refresh time (issue #271 spike).
			name:         "client-supplied audience is preserved and ours appended",
			method:       http.MethodPost,
			path:         "/oauth2/register",
			body:         `{"client_name":"claude","audience":["https://other.example/api"]}`,
			wantAudience: []any{"https://other.example/api", audience},
		},
		{
			name:         "audience already containing ours is forwarded verbatim",
			method:       http.MethodPost,
			path:         "/oauth2/register",
			body:         `{"client_name":"claude","audience":["` + audience + `"]}`,
			wantAudience: []any{audience},
			wantVerbatim: true,
		},
		{
			name:         "PUT without audience gets the MCP audience",
			method:       http.MethodPut,
			path:         "/oauth2/register/abc-123",
			body:         `{"client_name":"claude","redirect_uris":["https://claude.ai/cb"]}`,
			wantAudience: []any{audience},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newFakeHydra(http.StatusCreated, "application/json", `{"client_id":"abc"}`)
			defer fake.server.Close()
			handler := newTestRegisterHandlerWithAudience(fake, audience)

			request := httptest.NewRequest(test.method, "http://example.test"+test.path, strings.NewReader(test.body))
			request.RemoteAddr = "192.0.2.1:1234"
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusCreated {
				t.Fatalf("status = %d, want %d; body: %s", recorder.Code, http.StatusCreated, recorder.Body.String())
			}
			var forwarded map[string]any
			if err := json.Unmarshal([]byte(fake.lastBody), &forwarded); err != nil {
				t.Fatalf("upstream body is not JSON: %v; body: %s", err, fake.lastBody)
			}
			if !reflect.DeepEqual(forwarded["audience"], test.wantAudience) {
				t.Fatalf("upstream audience = %v, want %v", forwarded["audience"], test.wantAudience)
			}
			if forwarded["client_name"] != "claude" {
				t.Fatalf("client_name was not preserved: %v", forwarded["client_name"])
			}
			if test.wantVerbatim && fake.lastBody != test.body {
				t.Fatalf("body with client-supplied audience was rewritten\ngot:  %s\nwant: %s", fake.lastBody, test.body)
			}
		})
	}

	t.Run("no configured audience leaves the body untouched", func(t *testing.T) {
		fake := newFakeHydra(http.StatusCreated, "application/json", `{"client_id":"abc"}`)
		defer fake.server.Close()
		handler := newTestRegisterHandler(fake, 100)

		body := `{"client_name":"claude","redirect_uris":["https://claude.ai/cb"]}`
		request := httptest.NewRequest(http.MethodPost, "http://example.test/oauth2/register", strings.NewReader(body))
		request.RemoteAddr = "192.0.2.1:1234"
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)

		if recorder.Code != http.StatusCreated {
			t.Fatalf("status = %d, want %d", recorder.Code, http.StatusCreated)
		}
		if fake.lastBody != body {
			t.Fatalf("body was rewritten without configured audience\ngot:  %s\nwant: %s", fake.lastBody, body)
		}
	})
}

func TestResolveMCPAudience(t *testing.T) {
	tests := []struct {
		name        string
		resourceURL string
		fqdn        string
		want        string
	}{
		{name: "explicit resource url wins", resourceURL: "https://example.edu/mcp", fqdn: "other.edu", want: "https://example.edu/mcp"},
		{name: "derived from fqdn", resourceURL: "", fqdn: "example.edu", want: "https://example.edu/mcp"},
		{name: "unset disables injection", resourceURL: "", fqdn: "", want: ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("MCP_RESOURCE_URL", test.resourceURL)
			t.Setenv("FQDN", test.fqdn)
			if got := resolveMCPAudience(); got != test.want {
				t.Fatalf("resolveMCPAudience() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestRegisterProxyBodyTooLarge(t *testing.T) {
	fake := newFakeHydra(http.StatusCreated, "application/json", `{}`)
	defer fake.server.Close()
	handler := newTestRegisterHandler(fake, 100)

	big := `{"client_name":"` + strings.Repeat("a", registerMaxBodyBytes+1) + `"}`
	request := httptest.NewRequest(http.MethodPost, "http://example.test/oauth2/register", strings.NewReader(big))
	request.RemoteAddr = "192.0.2.1:1234"
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusRequestEntityTooLarge)
	}
	if fake.calls != 0 {
		t.Fatalf("oversized payload reached Hydra (%d calls)", fake.calls)
	}
}

func TestRegisterProxyManagementPassthrough(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		path       string
		body       string
		wantMethod string
	}{
		{
			name:       "GET client by id forwards auth header",
			method:     http.MethodGet,
			path:       "/oauth2/register/abc-123",
			wantMethod: http.MethodGet,
		},
		{
			name:       "DELETE client by id",
			method:     http.MethodDelete,
			path:       "/oauth2/register/abc-123",
			wantMethod: http.MethodDelete,
		},
		{
			name:       "PUT client by id with valid metadata",
			method:     http.MethodPut,
			path:       "/oauth2/register/abc-123",
			body:       `{"redirect_uris":["https://example.com/cb"]}`,
			wantMethod: http.MethodPut,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newFakeHydra(http.StatusOK, "application/json", `{"client_id":"abc-123","contacts":null}`)
			defer fake.server.Close()
			handler := newTestRegisterHandler(fake, 100)

			request := httptest.NewRequest(test.method, "http://example.test"+test.path, strings.NewReader(test.body))
			request.RemoteAddr = "192.0.2.1:1234"
			request.Header.Set("Authorization", "Bearer ory_at_registration_token")
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusOK {
				t.Fatalf("status = %d, want %d; body: %s", recorder.Code, http.StatusOK, recorder.Body.String())
			}
			if fake.lastMethod != test.wantMethod {
				t.Fatalf("upstream method = %q, want %q", fake.lastMethod, test.wantMethod)
			}
			if fake.lastPath != test.path {
				t.Fatalf("upstream path = %q, want %q", fake.lastPath, test.path)
			}
			if fake.lastAuth != "Bearer ory_at_registration_token" {
				t.Fatalf("Authorization header not forwarded; got %q", fake.lastAuth)
			}
			// 2xx management responses are cleaned too.
			mustJSONEqual(t, recorder.Body.Bytes(), `{"client_id":"abc-123"}`)
		})
	}
}

func TestRegisterProxyMethodAndPathRules(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		path       string
		wantStatus int
	}{
		{name: "GET on register root", method: http.MethodGet, path: "/oauth2/register", wantStatus: http.StatusMethodNotAllowed},
		{name: "DELETE on register root", method: http.MethodDelete, path: "/oauth2/register", wantStatus: http.StatusMethodNotAllowed},
		{name: "POST on client id", method: http.MethodPost, path: "/oauth2/register/abc", wantStatus: http.StatusMethodNotAllowed},
		{name: "trailing slash only", method: http.MethodGet, path: "/oauth2/register/", wantStatus: http.StatusNotFound},
		{name: "nested path", method: http.MethodGet, path: "/oauth2/register/abc/def", wantStatus: http.StatusNotFound},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newFakeHydra(http.StatusOK, "application/json", `{}`)
			defer fake.server.Close()
			handler := newTestRegisterHandler(fake, 100)

			request := httptest.NewRequest(test.method, "http://example.test"+test.path, nil)
			request.RemoteAddr = "192.0.2.1:1234"
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)

			if recorder.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d", recorder.Code, test.wantStatus)
			}
			if fake.calls != 0 {
				t.Fatalf("invalid request reached Hydra (%d calls)", fake.calls)
			}
		})
	}
}

func TestRegisterProxyRateLimits(t *testing.T) {
	fake := newFakeHydra(http.StatusCreated, "application/json", `{"client_id":"abc"}`)
	defer fake.server.Close()
	handler := newTestRegisterHandler(fake, 2)

	makeRequest := func(remoteAddr string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, "http://example.test/oauth2/register",
			strings.NewReader(`{"redirect_uris":["https://example.com/cb"]}`))
		request.RemoteAddr = remoteAddr
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder
	}

	for i := 0; i < 2; i++ {
		if recorder := makeRequest("192.0.2.1:1234"); recorder.Code != http.StatusCreated {
			t.Fatalf("request %d status = %d, want %d", i+1, recorder.Code, http.StatusCreated)
		}
	}
	if recorder := makeRequest("192.0.2.1:1234"); recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("third request status = %d, want %d", recorder.Code, http.StatusTooManyRequests)
	}
	// A different client IP is not affected.
	if recorder := makeRequest("192.0.2.2:1234"); recorder.Code != http.StatusCreated {
		t.Fatalf("other-IP request status = %d, want %d", recorder.Code, http.StatusCreated)
	}
	if fake.calls != 3 {
		t.Fatalf("upstream calls = %d, want 3", fake.calls)
	}
}
