package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Regression tests for the code-review findings on the initial scaffold:
// future-iat rejection, path-specific RFC 9728 metadata, CORS on the
// metadata document, and pre-auth IP rate limiting.

func TestVerifyMCPTokenRejectsFutureIAT(t *testing.T) {
	claims := validClaims()
	claims["iat"] = testNow.Add(10 * time.Minute).Unix()
	token := signTestToken(t, hs256Header(), claims, testSecret)
	if _, err := verifyMCPToken(token, testJWTConfig(), testNow); err == nil {
		t.Fatal("expected future-iat token to be rejected")
	}
}

func TestVerifyMCPTokenAllowsSmallIATSkew(t *testing.T) {
	claims := validClaims()
	claims["iat"] = testNow.Add(30 * time.Second).Unix()
	token := signTestToken(t, hs256Header(), claims, testSecret)
	if _, err := verifyMCPToken(token, testJWTConfig(), testNow); err != nil {
		t.Fatalf("expected 30s iat skew to be tolerated, got: %v", err)
	}
}

func TestMetadataURLForResourceIsPathSpecific(t *testing.T) {
	got, err := metadataURLForResource("https://example.com/mcp")
	if err != nil {
		t.Fatal(err)
	}
	want := "https://example.com/.well-known/oauth-protected-resource/mcp"
	if got != want {
		t.Fatalf("metadata URL = %q, want %q", got, want)
	}
}

func TestMetadataPathSuffix(t *testing.T) {
	cases := map[string]string{
		"":      "",
		"/":     "",
		"/mcp":  "/mcp",
		"/mcp/": "/mcp",
	}
	for in, want := range cases {
		if got := metadataPathSuffix(in); got != want {
			t.Errorf("metadataPathSuffix(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestProtectedResourceMetadataCORS(t *testing.T) {
	handler := protectedResourceMetadataHandler("https://example.com/mcp", "")

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/.well-known/oauth-protected-resource/mcp", nil))
	if rec.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatal("expected Access-Control-Allow-Origin: * on GET")
	}

	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodOptions, "/.well-known/oauth-protected-resource/mcp", nil))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS preflight status = %d, want 204", rec.Code)
	}
	if rec.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatal("expected Access-Control-Allow-Origin: * on OPTIONS")
	}
}

func TestIPRateLimitMiddlewareBlocksUnauthenticated(t *testing.T) {
	limiter := newRateLimiter(2, time.Minute)
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	handler := ipRateLimitMiddleware(limiter, next)

	for i := range 2 {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/mcp", nil)
		req.RemoteAddr = "203.0.113.9:1234"
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: status = %d, want 200", i, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/mcp", nil)
	req.RemoteAddr = "203.0.113.9:1234"
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("over-limit status = %d, want 429", rec.Code)
	}

	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/mcp", nil)
	req.RemoteAddr = "198.51.100.7:9999"
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("different-IP status = %d, want 200 (per-IP keying)", rec.Code)
	}
}
