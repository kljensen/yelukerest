// Command mcpapp is the yelukerest MCP server (issue #265). It serves the MCP
// streamable HTTP endpoint at /mcp behind Caddy, validating internal
// MCP-audience bearer JWTs. Tools that read course data via PostgREST arrive
// in issue #266.
package main

import (
	"log"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	mcpPath                       = "/mcp"
	protectedResourceMetadataPath = "/.well-known/oauth-protected-resource"
	// sessionIdleTimeout bounds how long an idle stateful MCP session is
	// retained when a client never sends a DELETE.
	sessionIdleTimeout = 30 * time.Minute
)

// appConfig is everything needed to build the HTTP handler; separated from
// main so tests can build the same stack without touching the environment.
type appConfig struct {
	JWT                    mcpJWTConfig
	ResourceURL            string // canonical MCP resource URL, e.g. https://example.com/mcp
	MetadataURL            string // advertised in WWW-Authenticate on 401s
	AuthorizationServerURL string // Hydra public URL; may be empty in phase 0
	StatelessEnabled       bool
	RateLimit              int
	RateWindow             time.Duration
}

func main() {
	var port = os.Getenv("PORT")
	if port == "" {
		log.Panicln("PORT environment variable not set")
	}

	var jwtSecret = os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		log.Panicln("JWT_SECRET environment variable not set")
	}

	var postgrestHost = os.Getenv("POSTGREST_HOST")
	if postgrestHost == "" {
		log.Panicln("POSTGREST_HOST environment variable not set")
	}

	var postgrestPort = os.Getenv("POSTGREST_PORT")
	if postgrestPort == "" {
		log.Panicln("POSTGREST_PORT environment variable not set")
	}

	resourceURL := envOrDefault("MCP_RESOURCE_URL", "")
	if resourceURL == "" {
		fqdn := strings.TrimSpace(os.Getenv("FQDN"))
		if fqdn == "" {
			log.Panicln("MCP_RESOURCE_URL or FQDN environment variable must be set")
		}
		resourceURL = "https://" + fqdn + mcpPath
	}
	metadataURL, err := metadataURLForResource(resourceURL)
	if err != nil {
		log.Panicf("MCP resource URL is invalid: %v", err)
	}

	config := appConfig{
		JWT: mcpJWTConfig{
			Secret:   []byte(jwtSecret),
			Issuer:   envOrDefault("JWT_ISSUER", "yelukerest"),
			Audience: envOrDefault("JWT_MCP_AUDIENCE", "yelukerest-mcp"),
		},
		ResourceURL:            resourceURL,
		MetadataURL:            metadataURL,
		AuthorizationServerURL: strings.TrimSpace(os.Getenv("HYDRA_PUBLIC_URL")),
		// Stateless mode (SEP-2567, go-sdk StreamableHTTPOptions.Stateless):
		// no Mcp-Session-Id header; GET and DELETE return 405. Off by default
		// because current Claude/ChatGPT traffic is legacy-era.
		StatelessEnabled: boolEnabled(os.Getenv("MCP_STATELESS_ENABLED")),
		RateLimit:        120,
		RateWindow:       time.Minute,
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	deps := &toolDeps{
		logger:    logger,
		postgrest: newPostgRESTClient(postgrestHost, postgrestPort),
		intent:    newIntentSigner(config.JWT.Secret, time.Now),
	}

	mux := newMux(config, deps)
	log.Println("Starting mcpapp on port", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

// newMux wires the full HTTP stack: no-store headers, bearer-token
// verification (401s advertise the RFC 9728 metadata URL), per-subject rate
// limiting, and the MCP streamable HTTP handler.
//
// Protocol eras: go-sdk v1.7.0 negotiates per session. Legacy clients
// (2025-11-25 and earlier) get the version they request via `initialize`,
// capped at 2025-11-25; 2026-07-28 clients use the newer negotiation. No
// configuration is needed for dual-era support.
func newMux(config appConfig, deps *toolDeps) *http.ServeMux {
	server := newMCPServer(deps)
	mcpHandler := mcp.NewStreamableHTTPHandler(
		func(*http.Request) *mcp.Server { return server },
		&mcp.StreamableHTTPOptions{
			Stateless: config.StatelessEnabled,
			// Bound idle-session retention in stateful mode; otherwise an
			// authenticated client that never sends DELETE grows the
			// session map without limit.
			SessionTimeout: sessionIdleTimeout,
		},
	)

	requireBearer := auth.RequireBearerToken(
		newTokenVerifier(config.JWT),
		&auth.RequireBearerTokenOptions{ResourceMetadataURL: config.MetadataURL},
	)
	limiter := newRateLimiter(config.RateLimit, config.RateWindow)
	// The pre-auth limiter runs before signature verification so
	// unauthenticated clients cannot spend unbounded CPU; it is a few
	// multiples of the per-subject limit to stay invisible to NAT'd
	// classrooms of legitimate users.
	preAuthLimiter := newRateLimiter(config.RateLimit*4, config.RateWindow)

	prmHandler := protectedResourceMetadataHandler(config.ResourceURL, config.AuthorizationServerURL)
	mux := http.NewServeMux()
	mux.Handle(mcpPath, noStoreMiddleware(ipRateLimitMiddleware(preAuthLimiter, requireBearer(subjectRateLimitMiddleware(limiter, mcpHandler)))))
	// RFC 9728: serve the root document and the path-specific document for
	// resources with a path component (e.g. /.well-known/...-resource/mcp).
	mux.Handle(protectedResourceMetadataPath, prmHandler)
	if suffix := metadataPathSuffix(mcpPath); suffix != "" {
		mux.Handle(protectedResourceMetadataPath+suffix, prmHandler)
	}
	mux.HandleFunc("/healthz", healthHandler)
	return mux
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte("ok"))
}

func envOrDefault(name string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}

func boolEnabled(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "0", "false", "no", "off":
		return false
	default:
		return true
	}
}
