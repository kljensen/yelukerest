package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestSetNoStoreHeaders(t *testing.T) {
	recorder := httptest.NewRecorder()

	setNoStoreHeaders(recorder)

	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
	if got := recorder.Header().Get("Pragma"); got != "no-cache" {
		t.Fatalf("Pragma = %q, want no-cache", got)
	}
	if got := recorder.Header().Get("Expires"); got != "0" {
		t.Fatalf("Expires = %q, want 0", got)
	}
}

func TestRateLimiter(t *testing.T) {
	limiter := newRateLimiter(2, time.Minute)
	now := time.Unix(1_700_000_000, 0)

	if !limiter.Allow("192.0.2.1", now) {
		t.Fatal("first request was rejected")
	}
	if !limiter.Allow("192.0.2.1", now.Add(time.Second)) {
		t.Fatal("second request was rejected")
	}
	if limiter.Allow("192.0.2.1", now.Add(2*time.Second)) {
		t.Fatal("third request was allowed")
	}
	if !limiter.Allow("192.0.2.1", now.Add(2*time.Minute)) {
		t.Fatal("request after window was rejected")
	}
}

func TestRateLimitMiddlewareReturns429(t *testing.T) {
	limiter := newRateLimiter(1, time.Minute)
	var callCount int
	handler := rateLimitMiddleware(limiter, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/jwt", nil)
	req.RemoteAddr = "192.0.2.1:12345"

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("first status = %d, want %d", recorder.Code, http.StatusNoContent)
	}

	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("second status = %d, want %d", recorder.Code, http.StatusTooManyRequests)
	}
	if callCount != 1 {
		t.Fatalf("callCount = %d, want 1", callCount)
	}
	if got := recorder.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
}

func TestRequestClientKey(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://example.test/auth/jwt", nil)
	req.RemoteAddr = "198.51.100.10:12345"

	if got := requestClientKey(req); got != "198.51.100.10" {
		t.Fatalf("requestClientKey without forwarded header = %q", got)
	}

	req.Header.Set("X-Forwarded-For", "203.0.113.9, 198.51.100.10")
	if got := requestClientKey(req); got != "203.0.113.9" {
		t.Fatalf("requestClientKey with forwarded header = %q", got)
	}
}
