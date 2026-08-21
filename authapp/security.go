package main

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

func setNoStoreHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Expires", "0")
}

// rateLimiterSweepThreshold is the map size above which Allow sweeps expired
// keys. Below it the bookkeeping is not worth the scan.
const rateLimiterSweepThreshold = 1024

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
	// Evict keys whose windows have fully expired. Without this the map
	// grows without bound on public endpoints (the DCR proxy), where
	// clients can arrive from unlimited distinct addresses.
	l.evictExpired(cutoff)
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

// evictExpired drops keys with no requests inside the current window. It runs
// under the caller's lock. Sweeping is amortized: the map only ever holds keys
// seen within one window plus those added since the last sweep.
func (l *rateLimiter) evictExpired(cutoff time.Time) {
	if len(l.requests) < rateLimiterSweepThreshold {
		return
	}
	for key, times := range l.requests {
		if len(times) == 0 || !times[len(times)-1].After(cutoff) {
			delete(l.requests, key)
		}
	}
}

func rateLimitMiddleware(limiter *rateLimiter, next http.Handler) http.Handler {
	return rateLimitMiddlewareKeyed(limiter, requestClientKey, next)
}

// rateLimitMiddlewareKeyed is rateLimitMiddleware with the bucket key chosen by
// the caller. The client IP is the right key for endpoints reached from a
// browser, but not for ones a whole class calls from behind the same NAT.
func rateLimitMiddlewareKeyed(limiter *rateLimiter, key func(*http.Request) string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !limiter.Allow(key(r), time.Now()) {
			setNoStoreHeaders(w)
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
