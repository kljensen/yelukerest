// Command mcpapp is the yelukerest MCP server (issue #265). It serves the MCP
// streamable HTTP endpoint at /mcp behind Caddy, validating both internal
// MCP-audience bearer JWTs (phase 0) and Hydra-issued OAuth access tokens
// (phase 1, issue #274), which it exchanges for internal credentials.
//
// Environment:
//
//	PORT, JWT_SECRET, POSTGREST_HOST, POSTGREST_PORT   required
//	MCP_RESOURCE_URL or FQDN                           required; the canonical
//	                                                   resource URL, which is
//	                                                   also the audience every
//	                                                   OAuth token must carry
//	JWT_ISSUER, JWT_MCP_AUDIENCE                       internal token rules
//	HYDRA_PUBLIC_URL                                   authorization server;
//	                                                   unset disables the OAuth
//	                                                   path entirely
//	MCPAPP_JWT                                         role=app app_name=mcpapp
//	                                                   service credential, used
//	                                                   ONLY to call
//	                                                   api.issue_user_jwt_for_mcp
//	                                                   (./bin/jwt.sh
//	                                                   '{"role":"app","app_name":"mcpapp"}')
//	HYDRA_PUBLIC_INTERNAL_URL                          where the JWKS is
//	                                                   fetched (default
//	                                                   http://hydra:4444);
//	                                                   keeps the fetch off
//	                                                   Caddy's TLS
//	HYDRA_ISSUER, HYDRA_JWKS_URL                       overrides for the two
//	                                                   values derived above
//	MCP_STATELESS_ENABLED                              default true; "false"
//	                                                   falls back to the
//	                                                   stateful handler, which
//	                                                   speaks legacy protocol
//	                                                   versions only
//	MCP_RATE_LIMIT_PER_MINUTE                          per-subject request
//	                                                   ceiling (default 120)
package main

import (
	"log"
	"log/slog"
	"net/http"
	"os"
	"strconv"
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
	// Hydra configures the OAuth access-token path (issue #274). Nil means
	// the deployment accepts phase 0 internal bearer tokens only.
	Hydra            *hydraConfig
	StatelessEnabled bool
	RateLimit        int
	RateWindow       time.Duration
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

	authorizationServerURL := strings.TrimSpace(os.Getenv("HYDRA_PUBLIC_URL"))

	config := appConfig{
		JWT: mcpJWTConfig{
			Secret:   []byte(jwtSecret),
			Issuer:   envOrDefault("JWT_ISSUER", "yelukerest"),
			Audience: envOrDefault("JWT_MCP_AUDIENCE", "yelukerest-mcp"),
		},
		ResourceURL:            resourceURL,
		MetadataURL:            metadataURL,
		AuthorizationServerURL: authorizationServerURL,
		Hydra:                  hydraConfigFromEnv(authorizationServerURL, resourceURL),
		// Stateless (SEP-2567, go-sdk StreamableHTTPOptions.Stateless) is the
		// default, and it is what makes this server dual-era: the transport
		// accepts every legacy protocol version either way, but 2026-07-28 is
		// only offered when it is stateless (SupportsProtocolVersion in the
		// SDK). Each POST gets an ephemeral session, so no Mcp-Session-Id is
		// issued, GET and DELETE answer 405, and there is no per-session state
		// to leak. Legacy clients are unaffected: a server MAY decline to
		// assign a session, and none of our tools carry state between calls —
		// every one re-derives the caller from the bearer token.
		//
		// MCP_STATELESS_ENABLED=false restores the old stateful handler, which
		// speaks legacy only. It exists as a rollback, not as a supported mode.
		StatelessEnabled: envBoolOrDefault("MCP_STATELESS_ENABLED", true),
		// 120 requests per minute per token subject is generous for a human
		// working through a client and tight enough to bound a runaway agent.
		// The agent dogfood suite is neither: it runs several scenarios of
		// several trials each under ONE subject, where every trial is a model
		// deciding to call a handful of tools, so it brushes the ceiling in a
		// way real traffic does not. The limit is therefore configurable and
		// raised for the test stack rather than lowered for production.
		RateLimit:  envIntOrDefault("MCP_RATE_LIMIT_PER_MINUTE", 120),
		RateWindow: time.Minute,
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	postgrest := newPostgRESTClient(postgrestHost, postgrestPort)

	// MCPAPP_JWT is the role=app app_name=mcpapp service credential the
	// database requires to mint internal user JWTs (api.issue_user_jwt_for_mcp
	// admits nothing else). Operators mint it with
	// ./bin/jwt.sh '{"role":"app","app_name":"mcpapp"}'. Missing it is not
	// fatal — phase 0 bearer tokens keep working — but every OAuth caller will
	// fail at its first tool call, so say so loudly at startup.
	mcpappJWT := strings.TrimSpace(os.Getenv("MCPAPP_JWT"))
	if config.Hydra == nil {
		log.Println("HYDRA_PUBLIC_URL is not set: OAuth access tokens are not accepted; only internal MCP bearer tokens will work")
	} else {
		log.Printf("OAuth access tokens accepted: issuer=%s jwks=%s audience=%s",
			config.Hydra.Issuer, config.Hydra.JWKSURL, config.Hydra.Audience)
		if mcpappJWT == "" {
			log.Println("WARNING: MCPAPP_JWT is not set. OAuth access tokens will verify but cannot be exchanged for a course credential, so every tool call by an OAuth client will fail. Add MCPAPP_JWT to the mcpapp service environment (see docs/hydra.md).")
		}
	}

	deps := &toolDeps{
		logger:    logger,
		postgrest: postgrest,
		exchanger: newTokenExchanger(postgrest, mcpappJWT),
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
// hydraConfigFromEnv builds the OAuth access-token configuration, or returns
// nil when no authorization server is configured.
//
//   - HYDRA_ISSUER overrides the expected `iss`; it defaults to
//     HYDRA_PUBLIC_URL, which is Hydra's URLS_SELF_ISSUER (the bare domain
//     root, per hydra/hydra.yml).
//   - HYDRA_JWKS_URL overrides where keys are fetched. By default they come
//     from HYDRA_PUBLIC_INTERNAL_URL (http://hydra:4444 in compose) so the
//     fetch stays on the internal network and never traverses Caddy's TLS —
//     which, in development, is a certificate this container does not trust.
//   - The audience every access token must carry is the canonical MCP
//     resource URL. It is never widened or disabled (ADR 0001).
func hydraConfigFromEnv(authorizationServerURL string, resourceURL string) *hydraConfig {
	issuer := strings.TrimRight(envOrDefault("HYDRA_ISSUER", authorizationServerURL), "/")
	if issuer == "" {
		return nil
	}
	jwksURL := envOrDefault("HYDRA_JWKS_URL", "")
	if jwksURL == "" {
		base := strings.TrimRight(envOrDefault("HYDRA_PUBLIC_INTERNAL_URL", issuer), "/")
		jwksURL = base + "/.well-known/jwks.json"
	}
	return &hydraConfig{Issuer: issuer, JWKSURL: jwksURL, Audience: resourceURL}
}

func newMux(config appConfig, deps *toolDeps) *http.ServeMux {
	server := newMCPServer(deps)
	mcpHandler := mcp.NewStreamableHTTPHandler(
		func(*http.Request) *mcp.Server { return server },
		&mcp.StreamableHTTPOptions{
			Stateless: config.StatelessEnabled,
			// Only consulted by the stateful handler, where an authenticated
			// client that never sends DELETE would otherwise grow the session
			// map without limit. A stateless server retains nothing.
			SessionTimeout: sessionIdleTimeout,
		},
	)

	verifier := &bearerVerifier{internal: config.JWT}
	if config.Hydra != nil {
		verifier.hydra = newHydraVerifier(*config.Hydra, nil, time.Now)
		verifier.exchanger = deps.exchanger
	}
	requireBearer := auth.RequireBearerToken(
		newTokenVerifier(verifier),
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

// envIntOrDefault reads a positive integer from the environment, falling
// back when the variable is unset, empty, or not a positive number.
func envIntOrDefault(name string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		log.Printf("%s=%q is not a positive integer; using %d", name, value, fallback)
		return fallback
	}
	return parsed
}

// envBoolOrDefault reads a boolean from the environment, returning fallback
// when the variable is unset or empty. Unlike boolEnabled it can default to
// true, which is what a flag being flipped on needs.
func envBoolOrDefault(name string, fallback bool) bool {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return boolEnabled(value)
}

func boolEnabled(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "0", "false", "no", "off":
		return false
	default:
		return true
	}
}
