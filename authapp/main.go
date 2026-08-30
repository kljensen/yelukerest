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

	// Sessions live in PostgreSQL (issue #365). Required, not optional with a
	// fallback: an in-memory fallback is exactly the bug being fixed, and it
	// fails invisibly -- CAS re-establishes the session with a silent redirect,
	// so nobody would notice authapp had quietly stopped persisting anything.
	// This is authapp's only direct database connection; everything else goes
	// through PostgREST.
	var sessionDatabaseURL = os.Getenv("AUTHAPP_DB_URL")
	if sessionDatabaseURL == "" {
		log.Panicln("AUTHAPP_DB_URL environment variable not set")
	}
	// Bounds connecting AND the check that the table is really readable and
	// writable, so a half-provisioned database stops the container here instead
	// of failing every request later.
	sessionDBContext, cancelSessionDBContext := context.WithTimeout(context.Background(), 10*time.Second)
	sessionDB, err := openSessionDatabase(sessionDBContext, sessionDatabaseURL)
	cancelSessionDBContext()
	if err != nil {
		log.Panicf("session store is unusable: %v", err)
	}
	defer sessionDB.Close()

	sessionManager := newSessionManager(casConfig.IsDevelopment, newSessionStore(sessionDB, sessionCleanupInterval))

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
	// withOptionalSession, not getSessionMiddleware: the OpenAPI document is served
	// to signed-out visitors too, describing the anonymous role's view of the API.
	getOpenAPI := withOptionalSession(sessionManager, getOpenAPIHandler(fetchJWTConfig))
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
	// /oauth2/register is public and unauthenticated, and every call
	// that gets through writes a client row in Hydra's database, so the
	// limit is what stops a stranger from filling that table. The old
	// 10/min was also below ordinary use: sixty students connecting at
	// once share a handful of campus NAT addresses, and Claude registers
	// two clients per connect attempt, so one class is ~120 registrations
	// from one address before anyone retries a screen that looks stuck.
	// 300 absorbs the class with a retry apiece.
	//
	// A per-minute ceiling alone only shapes the burst: 300/min sustained
	// is 432,000 client rows a day from one address, and the cleanup we
	// have (bin/prune-hydra-clients.sh by hand, a doctor.sh warning at
	// 500) notices that afterwards rather than preventing it. So the
	// route carries a second, hourly ceiling as well. Both apply; a
	// request has to clear each.
	registerLimiter := newRateLimiter(dcrRateLimitPerMinute(), time.Minute)
	registerHourlyLimiter := newRateLimiter(dcrRateLimitPerHour(), time.Hour)
	registerProxy := getRegisterProxyHandler(registerProxyConfig{
		HydraPublicURL: envOrDefault("HYDRA_PUBLIC_INTERNAL_URL", "http://hydra:4444"),
		MCPAudience:    mcpAudience,
	}, registerLimiter, registerHourlyLimiter)
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
	// These are public and unauthenticated too; the limit bounds a client
	// stuck in a loop pounding Hydra's admin API with challenge lookups.
	// One authorization costs three requests here (login GET, consent
	// GET, consent POST), so a sixty-student class arriving together is
	// ~180 from one campus address, and students retry. 600 clears that
	// with room and is still an order of magnitude under what a script
	// can generate, which is the case worth catching.
	oauthLimit := oauthRateLimitPerMinute()
	oauthLimiter := newRateLimiter(oauthLimit, time.Minute)
	mux.Handle(oauthLoginPath, rateLimitMiddleware(oauthLimiter, getOAuthLoginHandler(oauthConfig, sessionManager)))
	mux.Handle(oauthConsentPath, rateLimitMiddleware(oauthLimiter, getOAuthConsentHandler(oauthConfig, sessionManager)))
	// The consent stylesheet gets its own bucket of the same size. It is
	// a constant string served from memory, and letting a page's CSS
	// fetch spend the quota its own authorization needs is backwards.
	oauthStylesheetLimiter := newRateLimiter(oauthLimit, time.Minute)
	mux.Handle(oauthStylesheetPath, rateLimitMiddleware(oauthStylesheetLimiter, getOAuthStylesheetHandler()))
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
	if err := http.ListenAndServe(":"+port, sessionManager.LoadAndSave(mux)); err != nil {
		log.Fatal(err)
	}
}

// newSessionManager builds the session manager over the given store.
//
// The store is a parameter with no default on purpose. scs.New() falls back to
// an in-memory store when none is set, which is how every container recreate
// came to sign out everyone who was logged in (issue #365); making the caller
// name a store means that fallback cannot be reached by omission.
func newSessionManager(isDevelopment bool, store scs.Store) *scs.SessionManager {
	sessionManager := scs.New()
	sessionManager.Store = store
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

// Defaults for the public rate limits, raised in issue #330 so a whole
// class connecting at once cannot trip them. All are overridable from the
// environment: an operator watching a flood needs to be able to pull them
// down, and the end-to-end suite raises the OAuth one because it drives
// dozens of authorizations from one address in a few minutes. The
// per-minute sizing arguments live where the limiters are built, in main.
//
// Every limiter here is a sliding log over its own window, not a fixed
// window that resets on the clock, so a caller cannot double its
// allowance by straddling a boundary.
const (
	defaultDCRRateLimitPerMinute   = 300
	defaultOAuthRateLimitPerMinute = 600
	// The hourly companion to the DCR burst allowance. A class of sixty
	// costs ~120 registrations (two per connect attempt); assume every
	// student retries once and a second section meets in the same hour
	// and the honest worst case is ~480. 1200 clears that 2.5x over and
	// still caps one address at 28,800 client rows a day rather than the
	// 432,000 the per-minute limit allows on its own.
	defaultDCRRateLimitPerHour = 1200
)

func dcrRateLimitPerMinute() int {
	return envIntOrDefault("DCR_RATE_LIMIT_PER_MINUTE", defaultDCRRateLimitPerMinute)
}

func dcrRateLimitPerHour() int {
	return envIntOrDefault("DCR_RATE_LIMIT_PER_HOUR", defaultDCRRateLimitPerHour)
}

func oauthRateLimitPerMinute() int {
	return envIntOrDefault("OAUTH_RATE_LIMIT_PER_MINUTE", defaultOAuthRateLimitPerMinute)
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

// withOptionalSession attaches the netid when the caller has a session and
// otherwise lets the request through unchanged. It is the counterpart to
// getSessionMiddleware, for the one endpoint that has a meaningful answer for a
// visitor who has not logged in.
func withOptionalSession(sessionManager *scs.SessionManager, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		netid := sessionManager.GetString(r.Context(), "netid")
		if netid == "" {
			next.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), "netid", netid)))
	})
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
