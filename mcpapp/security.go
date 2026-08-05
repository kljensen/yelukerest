package main

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
)

func setNoStoreHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Expires", "0")
}

// noStoreMiddleware sets no-store headers on every response, including 401s
// produced by the bearer-token middleware further down the chain.
func noStoreMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		setNoStoreHeaders(w)
		next.ServeHTTP(w, r)
	})
}

type rateLimiter struct {
	mu       sync.Mutex
	limit    int
	window   time.Duration
	requests map[string][]time.Time
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	return &rateLimiter{
		limit:    limit,
		window:   window,
		requests: make(map[string][]time.Time),
	}
}

func (l *rateLimiter) Allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := now.Add(-l.window)
	var recent []time.Time
	for _, requestTime := range l.requests[key] {
		if requestTime.After(cutoff) {
			recent = append(recent, requestTime)
		}
	}
	if len(recent) >= l.limit {
		l.requests[key] = recent
		return false
	}

	recent = append(recent, now)
	l.requests[key] = recent
	return true
}

// subjectRateLimitMiddleware limits requests per verified token subject. It
// runs after auth.RequireBearerToken, so the subject comes from the verified
// token in the request context — never from client-controlled headers. The
// client IP is a defense-in-depth fallback only.
func subjectRateLimitMiddleware(limiter *rateLimiter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := "ip:" + requestClientKey(r)
		if info := auth.TokenInfoFromContext(r.Context()); info != nil && info.UserID != "" {
			key = "sub:" + info.UserID
		}
		if !limiter.Allow(key, time.Now()) {
			http.Error(w, "Too Many Requests", http.StatusTooManyRequests)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ipRateLimitMiddleware limits requests per client IP before any token
// verification runs, so unauthenticated clients cannot spend unbounded
// server CPU on signature checks. It is a coarser outer gate; the
// per-subject limiter still applies to authenticated traffic.
func ipRateLimitMiddleware(limiter *rateLimiter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !limiter.Allow("preauth:"+requestClientKey(r), time.Now()) {
			http.Error(w, "Too Many Requests", http.StatusTooManyRequests)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func requestClientKey(r *http.Request) string {
	forwardedFor := strings.TrimSpace(r.Header.Get("X-Forwarded-For"))
	if forwardedFor != "" {
		clientIP, _, _ := strings.Cut(forwardedFor, ",")
		clientIP = strings.TrimSpace(clientIP)
		if clientIP != "" {
			return clientIP
		}
	}

	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil && host != "" {
		return host
	}
	return r.RemoteAddr
}
