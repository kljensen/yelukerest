package main

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
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

// The OAuth login handler bounces unauthenticated users through CAS,
// so the mock CAS service URL now carries a live Hydra login_challenge
// in its `next` parameter. It must not reach the log.
func TestMockCASDoesNotLogTheServiceQuery(t *testing.T) {
	var logs bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(previous) })

	service := "https://course.example/auth/validate?next=" +
		url.QueryEscape("/auth/oauth/login?login_challenge=super-secret-challenge")
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet,
		"https://course.example/cas/login?id=abc123&service="+url.QueryEscape(service), nil)

	casLoginHandler(recorder, request)

	if recorder.Code != http.StatusTemporaryRedirect {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusTemporaryRedirect)
	}
	if strings.Contains(logs.String(), "super-secret-challenge") {
		t.Fatalf("mock CAS logged the challenge:\n%s", logs.String())
	}
	if !strings.Contains(logs.String(), "https://course.example/auth/validate") {
		t.Fatalf("mock CAS log lost the service path:\n%s", logs.String())
	}
}

func TestURLWithoutQueryRedactsCASTicket(t *testing.T) {
	got := urlWithoutQuery("https://cas.example/validate?ticket=ST-secret&service=https%3A%2F%2Fcourse.example%2Fauth%2Fvalidate")

	if got != "https://cas.example/validate" {
		t.Fatalf("urlWithoutQuery = %q", got)
	}
}
