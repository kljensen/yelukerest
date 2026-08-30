package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/alexedwards/scs/v2/memstore"
)

func TestGetOpenAPIHandlerFetchesAndEnrichesSpec(t *testing.T) {
	var sawJWTLookup bool
	var sawOpenAPIRequest bool
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/rpc/issue_user_jwt":
			sawJWTLookup = true
			if got := r.Method; got != http.MethodPost {
				t.Fatalf("user jwt method = %q", got)
			}
			if got := r.Header.Get("Authorization"); got != "Bearer service-token" {
				t.Fatalf("issue_user_jwt Authorization header = %q", got)
			}
			var body map[string]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode user jwt body: %v", err)
			}
			if got := body["requested_netid"]; got != "abc123" {
				t.Fatalf("requested_netid = %q", got)
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(UserJWTInfo{
				JWT:   "user-token",
				NetID: "abc123",
			})
		case "/":
			sawOpenAPIRequest = true
			if got := r.Header.Get("Authorization"); got != "Bearer user-token" {
				t.Fatalf("openapi Authorization header = %q", got)
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{
				"swagger":"2.0",
				"info":{"title":"PostgREST API"},
				"paths":{"/students":{"get":{"responses":{"200":{"description":"OK"}}}}}
			}`))
		default:
			t.Fatalf("unexpected upstream path %q", r.URL.Path)
		}
	})

	handler := getOpenAPIHandler(config)
	req := httptest.NewRequest(http.MethodGet, "http://internal/auth/api.json", nil)
	req.Host = "example.test"
	req.Header.Set("X-Forwarded-Host", "course.example.edu")
	req.Header.Set("X-Forwarded-Proto", "https")
	req = req.WithContext(context.WithValue(req.Context(), "netid", "abc123"))
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Fatalf("Content-Type = %q", got)
	}
	assertNoStoreHeaders(t, recorder.Result())
	if !sawJWTLookup {
		t.Fatal("did not fetch user JWT")
	}
	if !sawOpenAPIRequest {
		t.Fatal("did not fetch OpenAPI spec")
	}

	var spec map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &spec); err != nil {
		t.Fatalf("parse response JSON: %v", err)
	}

	if got := spec["host"]; got != "course.example.edu" {
		t.Fatalf("host = %v", got)
	}
	if got := spec["basePath"]; got != "/rest/" {
		t.Fatalf("basePath = %v", got)
	}
	assertStringSlice(t, spec["schemes"], []string{"https"})

	securityDefinitions := spec["securityDefinitions"].(map[string]interface{})
	jwtDefinition := securityDefinitions["jwt"].(map[string]interface{})
	if got := jwtDefinition["name"]; got != "Authorization" {
		t.Fatalf("jwt name = %v", got)
	}
	if got := jwtDefinition["type"]; got != "apiKey" {
		t.Fatalf("jwt type = %v", got)
	}
	if got := jwtDefinition["in"]; got != "header" {
		t.Fatalf("jwt in = %v", got)
	}

	security := spec["security"].([]interface{})
	securityItem := security[0].(map[string]interface{})
	jwtScopes := securityItem["jwt"].([]interface{})
	if len(jwtScopes) != 0 {
		t.Fatalf("jwt scopes length = %d, want 0", len(jwtScopes))
	}

	responses := spec["responses"].(map[string]interface{})
	unauthorized := responses["UnauthorizedError"].(map[string]interface{})
	if got := unauthorized["description"]; got != "JWT authorization is missing, invalid, or insufficient" {
		t.Fatalf("UnauthorizedError description = %v", got)
	}
}

func TestGetOpenAPIHandlerMapsPostgRESTSpecFailure(t *testing.T) {
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/rpc/issue_user_jwt":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(UserJWTInfo{
				JWT: "user-token",
			})
		case "/":
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"code":"PGRST000"}`))
		default:
			t.Fatalf("unexpected upstream path %q", r.URL.Path)
		}
	})

	handler := getOpenAPIHandler(config)
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/api.json", nil)
	req = req.WithContext(context.WithValue(req.Context(), "netid", "abc123"))
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusBadGateway)
	}
	if strings.Contains(recorder.Body.String(), "PGRST000") {
		t.Fatalf("response body leaked upstream detail: %q", recorder.Body.String())
	}
}

func TestRequestSchemeUsesFirstForwardedProto(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/api.json", nil)
	req.Header.Set("X-Forwarded-Proto", "https, http")

	if got := requestScheme(req); got != "https" {
		t.Fatalf("requestScheme = %q, want %q", got, "https")
	}
}

func TestOpenAPIEndpointServesSignedOutVisitors(t *testing.T) {
	// The "API" link is in the navigation for everyone. It used to sit behind
	// getSessionMiddleware, so a signed-out visitor who followed it got a 401 and
	// Swagger UI rendered "Failed to load API definition." -- an error from a
	// library with no idea that logging in was the missing step.
	//
	// The document is still built per caller. Without a session there is simply no
	// JWT to build it with, and PostgREST answers as the anonymous role: meetings,
	// ui_elements, platform_version. That is the honest public view.
	sessionManager := newSessionManager(true, memstore.New())
	var sawNetID bool
	var sawContextValue bool
	open := sessionManager.LoadAndSave(withOptionalSession(sessionManager, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawNetID = true
		_, sawContextValue = r.Context().Value("netid").(string)
	})))
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/api.json", nil)
	recorder := httptest.NewRecorder()

	open.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if !sawNetID {
		t.Fatal("handler was not reached without a session")
	}
	if sawContextValue {
		t.Fatal("a netid was attached to a request that has no session")
	}
}

func TestOpenAPIWithoutSessionAsksPostgRESTAnonymously(t *testing.T) {
	// The Authorization header must be absent rather than "Bearer ": PostgREST
	// rejects a malformed token instead of falling back to the anonymous role.
	var sawAuthHeader bool
	var sawJWTLookup bool
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/rpc/issue_user_jwt":
			sawJWTLookup = true
			t.Fatal("fetched a user JWT for a request with no session")
		case "/":
			_, sawAuthHeader = r.Header["Authorization"]
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"swagger":"2.0","info":{"title":"PostgREST API"},"paths":{"/meetings":{}}}`))
		default:
			t.Fatalf("unexpected upstream path %q", r.URL.Path)
		}
	})

	handler := getOpenAPIHandler(config)
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/api.json", nil)
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	if sawAuthHeader {
		t.Fatal("sent an Authorization header for a signed-out request")
	}
	if sawJWTLookup {
		t.Fatal("looked up a JWT for a signed-out request")
	}
	if !strings.Contains(recorder.Body.String(), "/meetings") {
		t.Fatalf("anonymous document missing public paths: %q", recorder.Body.String())
	}
}

func assertStringSlice(t *testing.T, got interface{}, want []string) {
	t.Helper()

	gotSlice, ok := got.([]interface{})
	if !ok {
		t.Fatalf("value type = %T, want []interface{}", got)
	}
	if len(gotSlice) != len(want) {
		t.Fatalf("length = %d, want %d", len(gotSlice), len(want))
	}
	for i := range want {
		if gotSlice[i] != want[i] {
			t.Fatalf("value[%d] = %v, want %q", i, gotSlice[i], want[i])
		}
	}
}

func TestEnrichOpenAPITitlesTheDocumentWithTheCourse(t *testing.T) {
	// PostgREST calls its document "PostgREST API", which says nothing about
	// whose API a student is reading. The name is deployment configuration, not
	// schema: the platform serves more than one course from the same migrations,
	// so a COMMENT ON SCHEMA would give them all the same title.
	t.Setenv("COURSE_TITLE", "MGT656")
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/api.json", nil)

	data := enrichOpenAPI(map[string]interface{}{
		"info": map[string]interface{}{"title": "PostgREST API", "version": "16.2"},
	}, req)

	info, ok := data["info"].(map[string]interface{})
	if !ok {
		t.Fatalf("info missing: %#v", data)
	}
	if got := info["title"]; got != "MGT656 API" {
		t.Fatalf("title = %v, want %q", got, "MGT656 API")
	}
	// The version describes the server actually answering, so it survives.
	if got := info["version"]; got != "16.2" {
		t.Fatalf("version = %v, want %q", got, "16.2")
	}
}

func TestEnrichOpenAPILeavesTitleAloneWhenUnconfigured(t *testing.T) {
	t.Setenv("COURSE_TITLE", "")
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/api.json", nil)

	data := enrichOpenAPI(map[string]interface{}{
		"info": map[string]interface{}{"title": "PostgREST API"},
	}, req)

	info := data["info"].(map[string]interface{})
	if got := info["title"]; got != "PostgREST API" {
		t.Fatalf("title = %v, want it untouched", got)
	}
}
