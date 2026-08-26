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

// The classroom failure in issue #330: a sixty-student cohort behind a
// handful of campus NAT addresses used to exhaust both limiters within
// the first minute of the first class. These assert the shipped ceilings
// clear that burst and that an operator can change them without a build.
func TestRateLimitDefaultsAbsorbAClass(t *testing.T) {
	t.Setenv("DCR_RATE_LIMIT_PER_MINUTE", "")
	t.Setenv("OAUTH_RATE_LIMIT_PER_MINUTE", "")

	if got := dcrRateLimitPerMinute(); got != 300 {
		t.Fatalf("dcrRateLimitPerMinute() = %d, want 300", got)
	}
	if got := oauthRateLimitPerMinute(); got != 600 {
		t.Fatalf("oauthRateLimitPerMinute() = %d, want 600", got)
	}

	// 60 students, two client registrations per connect attempt.
	if want := 60 * 2; dcrRateLimitPerMinute() <= want {
		t.Fatalf("DCR default %d leaves no headroom over %d registrations", dcrRateLimitPerMinute(), want)
	}
	// 60 students, three limited requests per authorization: login GET,
	// consent GET, consent POST. The stylesheet has its own bucket.
	if want := 60 * 3; oauthRateLimitPerMinute() <= want {
		t.Fatalf("OAuth default %d leaves no headroom over %d requests", oauthRateLimitPerMinute(), want)
	}
}

func TestRateLimitsComeFromTheEnvironment(t *testing.T) {
	t.Setenv("DCR_RATE_LIMIT_PER_MINUTE", "1234")
	t.Setenv("OAUTH_RATE_LIMIT_PER_MINUTE", "4321")

	if got := dcrRateLimitPerMinute(); got != 1234 {
		t.Fatalf("dcrRateLimitPerMinute() = %d, want 1234", got)
	}
	if got := oauthRateLimitPerMinute(); got != 4321 {
		t.Fatalf("oauthRateLimitPerMinute() = %d, want 4321", got)
	}

	// A typo must not silently disable limiting.
	t.Setenv("DCR_RATE_LIMIT_PER_MINUTE", "lots")
	t.Setenv("OAUTH_RATE_LIMIT_PER_MINUTE", "0")
	if got := dcrRateLimitPerMinute(); got != defaultDCRRateLimitPerMinute {
		t.Fatalf("unparseable DCR limit = %d, want the default", got)
	}
	if got := oauthRateLimitPerMinute(); got != defaultOAuthRateLimitPerMinute {
		t.Fatalf("zero OAuth limit = %d, want the default", got)
	}
}
