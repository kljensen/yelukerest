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

	if !limiter.Allow("sub:user:1", now) {
		t.Fatal("first request was rejected")
	}
	if !limiter.Allow("sub:user:1", now.Add(time.Second)) {
		t.Fatal("second request was rejected")
	}
	if limiter.Allow("sub:user:1", now.Add(2*time.Second)) {
		t.Fatal("third request was allowed")
	}
	if !limiter.Allow("sub:user:2", now.Add(2*time.Second)) {
		t.Fatal("request for a different subject was rejected")
	}
	if !limiter.Allow("sub:user:1", now.Add(2*time.Minute)) {
		t.Fatal("request after window was rejected")
	}
}

func TestSubjectRateLimitMiddlewareFallsBackToClientIP(t *testing.T) {
	// Without a verified token in the context, the limiter keys on client IP.
	limiter := newRateLimiter(1, time.Minute)
	var callCount int
	handler := subjectRateLimitMiddleware(limiter, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodPost, "http://example.test/mcp", nil)
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
}

func TestRequestClientKey(t *testing.T) {
	tests := []struct {
		name         string
		remoteAddr   string
		forwardedFor string
		want         string
	}{
		{
			name:       "remote addr",
			remoteAddr: "192.0.2.1:12345",
			want:       "192.0.2.1",
		},
		{
			name:         "forwarded for wins",
			remoteAddr:   "10.0.0.1:12345",
			forwardedFor: "203.0.113.9",
			want:         "203.0.113.9",
		},
		{
			name:         "forwarded for takes first hop",
			remoteAddr:   "10.0.0.1:12345",
			forwardedFor: "203.0.113.9, 10.0.0.2",
			want:         "203.0.113.9",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "http://example.test/mcp", nil)
			req.RemoteAddr = tt.remoteAddr
			if tt.forwardedFor != "" {
				req.Header.Set("X-Forwarded-For", tt.forwardedFor)
			}

			if got := requestClientKey(req); got != tt.want {
				t.Fatalf("requestClientKey = %q, want %q", got, tt.want)
			}
		})
	}
}
