package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/alexedwards/scs/v2"
)

func main() {
	var authValidatePath string = "/auth/validate"
	var loginPath string = "/auth/login"
	var logoutPath string = "/auth/logout"

	// Get configuration from the environment
	var postgrestHost = os.Getenv("POSTGREST_HOST")
	if postgrestHost == "" {
		log.Panicln("POSTGREST_HOST environment variable not set")
	}

	var postgrestPort = os.Getenv("POSTGREST_PORT")
	if postgrestPort == "" {
		log.Panicln("POSTGREST_PORT environment variable not set")
	}

	var authappJWT = os.Getenv("AUTHAPP_JWT")
	if authappJWT == "" {
		log.Panicln("AUTHAPP_JWT environment variable not set")
	}
	var jwtIssuer = envOrDefault("JWT_ISSUER", "yelukerest")
	var jwtAudience = envOrDefault("JWT_AUDIENCE", "yelukerest-postgrest")
	if err := validateAuthappJWT(authappJWT, jwtIssuer, jwtAudience, time.Now()); err != nil {
		log.Panicf("AUTHAPP_JWT is invalid: %v", err)
	}

	var port = os.Getenv("PORT")
	if port == "" {
		log.Panicln("PORT environment variable not set")
	}

	casURI := os.Getenv("CAS_URI")
	if !isValidCASURI(casURI) {
		log.Panicln("CAS_URI environment variable not set or invalid")
	}
	casValidationURI := os.Getenv("CAS_VALIDATION_URI")
	if casValidationURI == "" {
		casValidationURI = casURI
	} else if !isValidCASURI(casValidationURI) {
		log.Panicln("CAS_VALIDATION_URI environment variable is invalid")
	}

	casConfig := CASConfig{
		RemoteURI:           casURI,
		RemoteValidationURI: casValidationURI,
		ReturnPath:          authValidatePath,
		IsDevelopment:       developmentEnabled(os.Getenv("DEVELOPMENT")),
	}
	sessionManager := newSessionManager(casConfig.IsDevelopment)

	// Set up the JWT stuff
	fetchJWTConfig := FetchJWTConfig{
		PostgrestHost: postgrestHost,
		PostgrestPort: postgrestPort,
		AuthappJWT:    os.Getenv("AUTHAPP_JWT"),
	}

	// Set up the routes
	mux := http.NewServeMux()

	// Add login
	loginHandler := getLoginHandler(casConfig)
	mux.HandleFunc(loginPath, loginHandler)

	// Add logout
	logoutHandler := getLogoutHandler(sessionManager)
	mux.HandleFunc(logoutPath, logoutHandler)

	// Add validate
	validateHandler := getValidateHandler(casConfig, fetchJWTConfig, sessionManager)
	mux.HandleFunc(authValidatePath, validateHandler)

	// Add the user details endpoints
	getMe := getSessionMiddleware(sessionManager, getMeHandler(fetchJWTConfig))
	jwtRateLimiter := newRateLimiter(60, time.Minute)
	getJWT := getSessionMiddleware(sessionManager, rateLimitMiddleware(jwtRateLimiter, getJWTHandler(fetchJWTConfig)))
	getOpenAPI := getSessionMiddleware(sessionManager, getOpenAPIHandler(fetchJWTConfig))
	// Personal access token exchange (issue #317). Deliberately NOT behind
	// getSessionMiddleware: the caller presents a token precisely because they
	// have no browser session. The limit is tighter than /auth/jwt because this
	// is the one endpoint reachable with a stolen long-lived credential, and a
	// legitimate client needs at most one exchange an hour.
	apiTokenRateLimiter := newRateLimiter(20, time.Minute)
	exchangeAPIToken := rateLimitMiddlewareKeyed(
		apiTokenRateLimiter,
		apiTokenRateLimitKey,
		exchangeAPITokenHandler(fetchJWTConfig),
	)

	mux.Handle("/auth/me", getMe)
	mux.Handle("/auth/jwt", getJWT)
	mux.Handle("/auth/token", exchangeAPIToken)
	mux.Handle("/auth/api.json", getOpenAPI)

	// Proxy Hydra's Dynamic Client Registration endpoints, cleaning
	// null/empty optional fields out of responses that break strict
	// MCP clients (ory/hydra#4044, issue #272), injecting the MCP
	// audience allowlist so token refresh works (issue #271 spike),
	// and hardening the registration surface (rate limit,
	// redirect_uri validation).
	mcpAudience := resolveMCPAudience()
	if mcpAudience == "" {
		log.Println("warning: MCP_RESOURCE_URL and FQDN are unset; DCR audience injection is disabled and Hydra token refresh will fail for MCP clients")
	}
	registerLimiter := newRateLimiter(10, time.Minute)
	registerProxy := getRegisterProxyHandler(registerProxyConfig{
		HydraPublicURL: envOrDefault("HYDRA_PUBLIC_INTERNAL_URL", "http://hydra:4444"),
		MCPAudience:    mcpAudience,
	}, registerLimiter)
	mux.Handle("/oauth2/register", registerProxy)
	mux.Handle("/oauth2/register/", registerProxy)

	// Hydra's delegated login and consent handlers (issue #273). The
	// paths are fixed by hydra.yml's urls.login / urls.consent. The
	// admin API these talk to is reachable only on the internal compose
	// network; operators running Hydra elsewhere override
	// HYDRA_ADMIN_URL. It must never be published or proxied by Caddy.
	oauthConfig := newOAuthFlowConfig(
		envOrDefault("HYDRA_ADMIN_URL", "http://hydra:4445"),
		mcpAudience,
		loginPath,
		fetchJWTConfig,
	)
	// One authorization costs three requests (login GET, consent GET,
	// consent POST), so 60/min leaves ample headroom for retries while
	// bounding a challenge-probing loop. The end-to-end suite drives
	// dozens of authorizations from one address in a couple of minutes,
	// which is nothing like real traffic, so the ceiling is configurable
	// and raised for the test stack rather than tuned down for production.
	oauthLimiter := newRateLimiter(envIntOrDefault("OAUTH_RATE_LIMIT_PER_MINUTE", 60), time.Minute)
	mux.Handle(oauthLoginPath, rateLimitMiddleware(oauthLimiter, getOAuthLoginHandler(oauthConfig, sessionManager)))
	mux.Handle(oauthConsentPath, rateLimitMiddleware(oauthLimiter, getOAuthConsentHandler(oauthConfig, sessionManager)))
	mux.Handle(oauthStylesheetPath, rateLimitMiddleware(oauthLimiter, getOAuthStylesheetHandler()))
	// Connected applications (issue #277): session-authenticated, so an
	// application can never disconnect another on the user's behalf. Shares
	// the OAuth limiter because it is the same browser-facing surface.
	mux.Handle(connectedAppsPath, rateLimitMiddleware(oauthLimiter, getConnectedAppsHandler(oauthConfig, fetchJWTConfig, sessionManager)))

	// In development, add endpoints for a mock CAS server.
	if casConfig.IsDevelopment {
		mux.HandleFunc("/cas/login", casLoginHandler)
		mux.HandleFunc("/cas/serviceValidate", casServiceValidateHandler)
	}

	log.Println("Starting server on...", port)
	err := http.ListenAndServe(":"+port, sessionManager.LoadAndSave(mux))
	if err != nil {
		log.Fatal(err)
	}
}

func newSessionManager(isDevelopment bool) *scs.SessionManager {
	sessionManager := scs.New()
	sessionManager.Lifetime = 24 * time.Hour
	sessionManager.Cookie.HttpOnly = true
	sessionManager.Cookie.SameSite = http.SameSiteLaxMode
	sessionManager.Cookie.Secure = !isDevelopment
	return sessionManager
}

func developmentEnabled(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "0", "false", "no", "off":
		return false
	default:
		return true
	}
}

// resolveMCPAudience returns the MCP resource URL injected as the
// audience allowlist during dynamic client registration: explicit
// MCP_RESOURCE_URL when set (matching mcpapp's configuration),
// otherwise derived from FQDN, otherwise empty (injection disabled).
func resolveMCPAudience() string {
	if value := strings.TrimSpace(os.Getenv("MCP_RESOURCE_URL")); value != "" {
		return value
	}
	if fqdn := strings.TrimSpace(os.Getenv("FQDN")); fqdn != "" {
		return "https://" + fqdn + "/mcp"
	}
	return ""
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

func envOrDefault(name string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}

func getLogoutHandler(sessionManager *scs.SessionManager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionManager.Destroy(r.Context())
		http.Redirect(w, r, "/", http.StatusFound)
	}
}

func getSessionMiddleware(sessionManager *scs.SessionManager, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		netid := sessionManager.GetString(r.Context(), "netid")
		if netid == "" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		// set the netid in the context
		ctx := context.WithValue(r.Context(), "netid", netid)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
