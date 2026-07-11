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
)

func testFetchJWTConfig(t *testing.T, handler http.HandlerFunc) FetchJWTConfig {
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

	return FetchJWTConfig{
		PostgrestHost: host,
		PostgrestPort: port,
		AuthappJWT:    "service-token",
	}
}

func TestIssueUserJWTURL(t *testing.T) {
	config := FetchJWTConfig{
		PostgrestHost: "postgrest",
		PostgrestPort: "3000",
	}

	got := issueUserJWTURL(config)

	if got != "http://postgrest:3000/rpc/issue_user_jwt" {
		t.Fatalf("issueUserJWTURL = %q", got)
	}
}

func TestUserInfoURL(t *testing.T) {
	config := FetchJWTConfig{
		PostgrestHost: "postgrest",
		PostgrestPort: "3000",
	}

	got := userInfoURL(config, "abc+123")
	parsedURL, err := url.Parse(got)
	if err != nil {
		t.Fatalf("parse userInfoURL: %v", err)
	}

	if parsedURL.Scheme != "http" || parsedURL.Host != "postgrest:3000" || parsedURL.Path != "/users" {
		t.Fatalf("userInfoURL = %q", got)
	}
	if got := parsedURL.Query().Get("netid"); got != "eq.abc+123" {
		t.Fatalf("netid query = %q", got)
	}
	selectList := parsedURL.Query().Get("select")
	if strings.Contains(selectList, "jwt") {
		t.Fatalf("select list includes jwt: %q", selectList)
	}
	if !strings.Contains(selectList, "team_nickname") {
		t.Fatalf("select list = %q", selectList)
	}
}

func TestFetchUserJWTInfoSendsServiceToken(t *testing.T) {
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.Method; got != http.MethodPost {
			t.Fatalf("method = %q", got)
		}
		if got := r.URL.Path; got != "/rpc/issue_user_jwt" {
			t.Fatalf("path = %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer service-token" {
			t.Fatalf("Authorization header = %q", got)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Fatalf("Content-Type header = %q", got)
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if got := body["requested_netid"]; got != "abc+123" {
			t.Fatalf("requested_netid = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(UserJWTInfo{
			JWT:   "header.payload.signature",
			NetID: "abc+123",
			Role:  "student",
		})
	})

	info, err, status := fetchUserJWTInfo("abc+123", config)
	if err != nil {
		t.Fatalf("fetchUserJWTInfo error = %v, status = %d", err, status)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want %d", status, http.StatusOK)
	}
	if info.JWT != "header.payload.signature" {
		t.Fatalf("JWT = %q", info.JWT)
	}
}

func TestGetJWTHandlerSetsNoStoreHeaders(t *testing.T) {
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(UserJWTInfo{
			JWT:   "header.payload.signature",
			NetID: "abc123",
			Role:  "student",
		})
	})
	handler := getJWTHandler(config)
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/jwt", nil)
	req = req.WithContext(context.WithValue(req.Context(), "netid", "abc123"))
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	assertNoStoreHeaders(t, recorder.Result())
}

func TestFetchUserInfoSendsServiceTokenWithoutMintingJWT(t *testing.T) {
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.Method; got != http.MethodGet {
			t.Fatalf("method = %q", got)
		}
		if got := r.URL.Path; got != "/users" {
			t.Fatalf("path = %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer service-token" {
			t.Fatalf("Authorization header = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "application/vnd.pgrst.object+json" {
			t.Fatalf("Accept header = %q", got)
		}
		if got := r.URL.Query().Get("netid"); got != "eq.abc+123" {
			t.Fatalf("netid query = %q", got)
		}
		if strings.Contains(r.URL.Query().Get("select"), "jwt") {
			t.Fatalf("select query includes jwt: %q", r.URL.Query().Get("select"))
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(UserJWTInfo{
			ID:    1,
			NetID: "abc+123",
			Role:  "student",
		})
	})

	info, err, status := fetchUserInfo("abc+123", config)
	if err != nil {
		t.Fatalf("fetchUserInfo error = %v, status = %d", err, status)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want %d", status, http.StatusOK)
	}
	if info.JWT != "" {
		t.Fatalf("JWT = %q, want empty", info.JWT)
	}
	if info.NetID != "abc+123" {
		t.Fatalf("NetID = %q", info.NetID)
	}
}

func TestGetMeHandlerUsesUserInfoEndpoint(t *testing.T) {
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Path; got == "/rpc/issue_user_jwt" {
			t.Fatalf("getMeHandler should not mint a JWT")
		}
		if got := r.URL.Path; got != "/users" {
			t.Fatalf("path = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(UserJWTInfo{
			ID:    1,
			NetID: "abc123",
			Role:  "student",
		})
	})

	handler := getMeHandler(config)
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/me", nil)
	req = req.WithContext(context.WithValue(req.Context(), "netid", "abc123"))
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
	if strings.Contains(recorder.Body.String(), "jwt") {
		t.Fatalf("response body includes jwt: %q", recorder.Body.String())
	}
	assertNoStoreHeaders(t, recorder.Result())
}

func TestFetchUserJWTInfoMapsPostgRESTStatuses(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
		wantStatus int
	}{
		{
			name:       "no rows",
			statusCode: http.StatusNotAcceptable,
			body:       `{"code":"PGRST116"}`,
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "service jwt rejected",
			statusCode: http.StatusUnauthorized,
			body:       `{"code":"PGRST301"}`,
			wantStatus: http.StatusBadGateway,
		},
		{
			name:       "malformed success body",
			statusCode: http.StatusOK,
			body:       `not json`,
			wantStatus: http.StatusBadGateway,
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
			config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tt.statusCode)
				_, _ = w.Write([]byte(tt.body))
			})

			_, err, status := fetchUserJWTInfo("abc123", config)
			if err == nil {
				t.Fatal("expected error")
			}
			if status != tt.wantStatus {
				t.Fatalf("status = %d, want %d", status, tt.wantStatus)
			}
		})
	}
}

func assertNoStoreHeaders(t *testing.T, response *http.Response) {
	t.Helper()

	if got := response.Header.Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
	if got := response.Header.Get("Pragma"); got != "no-cache" {
		t.Fatalf("Pragma = %q, want no-cache", got)
	}
	if got := response.Header.Get("Expires"); got != "0" {
		t.Fatalf("Expires = %q, want 0", got)
	}
}

func TestGetJWTHandlerDoesNotExposeUpstreamErrorBody(t *testing.T) {
	config := testFetchJWTConfig(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"detail":"internal table name"}`))
	})

	handler := getJWTHandler(config)
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/jwt", nil)
	req = req.WithContext(context.WithValue(req.Context(), "netid", "abc123"))
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusBadGateway)
	}
	if strings.Contains(recorder.Body.String(), "internal table name") {
		t.Fatalf("response body leaked upstream detail: %q", recorder.Body.String())
	}
}
