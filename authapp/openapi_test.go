package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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

func TestOpenAPIEndpointRequiresSession(t *testing.T) {
	sessionManager := newSessionManager(true)
	var calledNext bool
	protected := sessionManager.LoadAndSave(getSessionMiddleware(sessionManager, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calledNext = true
	})))
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/api.json", nil)
	recorder := httptest.NewRecorder()

	protected.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusUnauthorized)
	}
	if calledNext {
		t.Fatal("protected handler was called without a session")
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
