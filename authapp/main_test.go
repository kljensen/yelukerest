package main

import (
	"net/http"
	"testing"
	"time"
)

func TestNewSessionManagerCookieSettings(t *testing.T) {
	tests := []struct {
		name         string
		development  bool
		wantSecure   bool
		wantSameSite http.SameSite
	}{
		{
			name:         "development",
			development:  true,
			wantSecure:   false,
			wantSameSite: http.SameSiteLaxMode,
		},
		{
			name:         "production",
			development:  false,
			wantSecure:   true,
			wantSameSite: http.SameSiteLaxMode,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sessionManager := newSessionManager(tt.development)

			if sessionManager.Lifetime != 24*time.Hour {
				t.Fatalf("Lifetime = %s, want 24h", sessionManager.Lifetime)
			}
			if sessionManager.Cookie.HttpOnly != true {
				t.Fatal("HttpOnly = false, want true")
			}
			if sessionManager.Cookie.SameSite != tt.wantSameSite {
				t.Fatalf("SameSite = %d, want %d", sessionManager.Cookie.SameSite, tt.wantSameSite)
			}
			if sessionManager.Cookie.Secure != tt.wantSecure {
				t.Fatalf("Secure = %v, want %v", sessionManager.Cookie.Secure, tt.wantSecure)
			}
		})
	}
}

func TestDevelopmentEnabled(t *testing.T) {
	tests := []struct {
		value string
		want  bool
	}{
		{value: "", want: false},
		{value: "0", want: false},
		{value: "false", want: false},
		{value: "FALSE", want: false},
		{value: " no ", want: false},
		{value: "off", want: false},
		{value: "1", want: true},
		{value: "true", want: true},
		{value: "yes", want: true},
	}

	for _, tt := range tests {
		t.Run(tt.value, func(t *testing.T) {
			if got := developmentEnabled(tt.value); got != tt.want {
				t.Fatalf("developmentEnabled(%q) = %v, want %v", tt.value, got, tt.want)
			}
		})
	}
}
