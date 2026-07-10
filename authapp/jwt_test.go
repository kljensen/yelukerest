package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
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
