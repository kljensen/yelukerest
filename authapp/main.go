package main

import (
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/alexedwards/scs/v2"
)

var sessionManager *scs.SessionManager
var casURI string
var authValidatePath string = "/auth/validate"
var loginPath string = "/auth/login"

func main() {

	var port = os.Getenv("PORT")
	if port == "" {
		log.Panicln("PORT environment variable not set")
	}

	casURI = os.Getenv("CAS_URI")
	if !isValidCASURI() {
		log.Panicln("CAS_URI environment variable not set or invalid")
	}
	casValidationURI := os.Getenv("CAS_VALIDATION_URI")
	if casValidationURI == "" {
		casValidationURI = casURI
	}

	// Initialize a new session manager and configure the session lifetime.
	// Notice that there is no session secret because we are using an in-memory
	// store and it is set automatically. But, everything is lost on restart.
	sessionManager = scs.New()
	sessionManager.Lifetime = 24 * time.Hour

	mux := http.NewServeMux()
	mux.HandleFunc("/put", putHandler)
	mux.HandleFunc("/get", getHandler)
	config := CASConfig{
		RemoteURI:           casURI,
		RemoteValidationURI: casValidationURI,
		ReturnPath:          authValidatePath,
	}
	loginHandler := getLoginHandler(config)
	mux.HandleFunc(loginPath, loginHandler)
	validateHandler := getValidateHandler(config)
	mux.HandleFunc(authValidatePath, validateHandler)

	// In development, run the mock CAS server, acting
	// like we are Yale's CAS for testing purposes.
	isDevelopment := os.Getenv("DEVELOPMENT") != ""
	if isDevelopment {
		// Routes for the MockCAS server
		mux.HandleFunc("/cas/login", login)
		mux.HandleFunc("/cas/serviceValidate", serviceValidate)
	}

	// Wrap your handlers with the LoadAndSave() middleware.
	log.Println("Starting server on...", port)
	err := http.ListenAndServe(":"+port, sessionManager.LoadAndSave(mux))
	if err != nil {
		log.Fatal(err)
	}
}

func putHandler(w http.ResponseWriter, r *http.Request) {
	// Store a new key and value in the session data.
	sessionManager.Put(r.Context(), "message", "Hello from a session!")
}

func getHandler(w http.ResponseWriter, r *http.Request) {
	// Use the GetString helper to retrieve the string value associated with a
	// key. The zero value is returned if the key does not exist.
	msg := sessionManager.GetString(r.Context(), "message")
	io.WriteString(w, msg)
}
