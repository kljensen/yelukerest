package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestSafeRedirectPath(t *testing.T) {
	tests := []struct {
		name string
		next string
		want string
	}{
		{name: "empty", next: "", want: "/"},
		{name: "path", next: "/dashboard", want: "/dashboard"},
		{name: "path with query", next: "/dashboard?tab=api", want: "/dashboard?tab=api"},
		{name: "relative path", next: "dashboard", want: "/"},
		{name: "external URL", next: "https://evil.example/dashboard", want: "/"},
		{name: "scheme relative URL", next: "//evil.example/dashboard", want: "/"},
		{name: "triple slash URL", next: "///evil.example/dashboard", want: "/"},
		{name: "backslash URL", next: `\evil.example\dashboard`, want: "/"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := safeRedirectPath(tt.next); got != tt.want {
				t.Fatalf("safeRedirectPath(%q) = %q, want %q", tt.next, got, tt.want)
			}
		})
	}
}

func TestLoginHandlerSanitizesNextInServiceURL(t *testing.T) {
	handler := getLoginHandler(CASConfig{
		RemoteURI:  "https://cas.example/login",
		ReturnPath: "/auth/validate",
	})
	req := httptest.NewRequest(http.MethodGet, "https://yeluke.example/auth/login?next=https://evil.example/app", nil)
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, req)

	location := recorder.Header().Get("Location")
	casURL, err := url.Parse(location)
	if err != nil {
		t.Fatalf("parse CAS redirect location: %v", err)
	}
	serviceURL, err := url.Parse(casURL.Query().Get("service"))
	if err != nil {
		t.Fatalf("parse CAS service URL: %v", err)
	}
	if got := serviceURL.Query().Get("next"); got != "" {
		t.Fatalf("service next = %q, want empty", got)
	}
}
