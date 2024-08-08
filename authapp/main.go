package main

import (
	"context"
	"log"
	"net/http"
	"os"
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
		IsDevelopment:       os.Getenv("DEVELOPMENT") != "",
	}
	sessionManager := scs.New()
	sessionManager.Lifetime = 24 * time.Hour

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
	getJWT := getSessionMiddleware(sessionManager, getJWTHandler(fetchJWTConfig))
	mux.Handle("/auth/me", getMe)
	mux.Handle("/auth/jwt", getJWT)

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
