package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestProtectedResourceMetadataHandler(t *testing.T) {
	tests := []struct {
		name        string
		hydraURL    string
		wantServers []string
	}{
		{
			name:        "with authorization server",
			hydraURL:    "https://hydra.example.com",
			wantServers: []string{"https://hydra.example.com"},
		},
		{
			name:        "phase 0 without authorization server",
			hydraURL:    "",
			wantServers: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler := protectedResourceMetadataHandler("https://example.com/mcp", tt.hydraURL)
			req := httptest.NewRequest(http.MethodGet, "http://example.test"+protectedResourceMetadataPath, nil)
			recorder := httptest.NewRecorder()

			handler.ServeHTTP(recorder, req)

			if recorder.Code != http.StatusOK {
				t.Fatalf("status = %d", recorder.Code)
			}
			if got := recorder.Header().Get("Content-Type"); got != "application/json" {
				t.Fatalf("Content-Type = %q", got)
			}

			var metadata struct {
				Resource               string   `json:"resource"`
				AuthorizationServers   []string `json:"authorization_servers"`
				BearerMethodsSupported []string `json:"bearer_methods_supported"`
			}
			if err := json.Unmarshal(recorder.Body.Bytes(), &metadata); err != nil {
				t.Fatalf("decode body: %v", err)
			}
			if metadata.Resource != "https://example.com/mcp" {
				t.Fatalf("resource = %q", metadata.Resource)
			}
			if metadata.AuthorizationServers == nil {
				t.Fatal("authorization_servers is null, want an array")
			}
			if len(metadata.AuthorizationServers) != len(tt.wantServers) {
				t.Fatalf("authorization_servers = %v, want %v", metadata.AuthorizationServers, tt.wantServers)
			}
			for i, want := range tt.wantServers {
				if metadata.AuthorizationServers[i] != want {
					t.Fatalf("authorization_servers[%d] = %q, want %q", i, metadata.AuthorizationServers[i], want)
				}
			}
			if len(metadata.BearerMethodsSupported) != 1 || metadata.BearerMethodsSupported[0] != "header" {
				t.Fatalf("bearer_methods_supported = %v", metadata.BearerMethodsSupported)
			}
		})
	}
}

func TestProtectedResourceMetadataHandlerRejectsPost(t *testing.T) {
	handler := protectedResourceMetadataHandler("https://example.com/mcp", "")
	req := httptest.NewRequest(http.MethodPost, "http://example.test"+protectedResourceMetadataPath, nil)
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusMethodNotAllowed)
	}
}

func TestMetadataURLForResource(t *testing.T) {
	tests := []struct {
		name     string
		resource string
		want     string
		wantErr  bool
	}{
		{
			name:     "https resource",
			resource: "https://example.com/mcp",
			want:     "https://example.com/.well-known/oauth-protected-resource/mcp",
		},
		{
			name:     "resource with port",
			resource: "https://localhost:443/mcp",
			want:     "https://localhost:443/.well-known/oauth-protected-resource/mcp",
		},
		{
			name:     "relative resource",
			resource: "/mcp",
			wantErr:  true,
		},
		{
			name:     "empty resource",
			resource: "",
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := metadataURLForResource(tt.resource)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatalf("metadataURLForResource error = %v", err)
			}
			if got != tt.want {
				t.Fatalf("metadataURLForResource = %q, want %q", got, tt.want)
			}
		})
	}
}
