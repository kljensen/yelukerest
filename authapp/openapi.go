package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func postgRESTOpenAPIURL(config FetchJWTConfig) string {
	endpoint := url.URL{
		Scheme: "http",
		Host:   net.JoinHostPort(config.PostgrestHost, config.PostgrestPort),
		Path:   "/",
	}
	return endpoint.String()
}

func fetchOpenAPI(jwt string, config FetchJWTConfig) (map[string]interface{}, error, int) {
	req, err := http.NewRequest("GET", postgRESTOpenAPIURL(config), nil)
	if err != nil {
		return nil, fmt.Errorf("error creating request: %v", err), http.StatusInternalServerError
	}
	// An empty JWT is the signed-out case, not a mistake. PostgREST then applies
	// its anonymous role and returns the public surface of the API, which is what
	// a visitor who has not logged in is entitled to see. Sending "Bearer " with
	// nothing after it would instead be rejected as a malformed token.
	if jwt != "" {
		req.Header.Set("Authorization", "Bearer "+jwt)
	}

	client := &http.Client{
		Timeout: 5 * time.Second,
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("postgrest unavailable: %v", err), http.StatusBadGateway
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("error reading response: %v", err), http.StatusInternalServerError
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected postgrest status %s", resp.Status), http.StatusBadGateway
	}

	var data map[string]interface{}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, fmt.Errorf("error parsing openapi response: %v", err), http.StatusBadGateway
	}

	return data, nil, http.StatusOK
}

// courseTitle names this deployment in the OpenAPI document. PostgREST titles
// its document "PostgREST API", which tells a student nothing about whose API
// they are looking at, and the platform runs more than one course, so the name
// cannot be baked into the schema either -- a COMMENT ON SCHEMA would title
// every deployment the same. It is deployment configuration, so it arrives the
// same way the web client's title does, from ELMCLIENT_COURSE_TITLE.
func courseTitle() string {
	return strings.TrimSpace(os.Getenv("COURSE_TITLE"))
}

func enrichOpenAPI(data map[string]interface{}, r *http.Request) map[string]interface{} {
	if title := courseTitle(); title != "" {
		info, ok := data["info"].(map[string]interface{})
		if !ok || info == nil {
			info = map[string]interface{}{}
			data["info"] = info
		}
		// The version stays as PostgREST reported it: it describes the server
		// actually answering, and replacing it with a course name would lose
		// that without gaining anything.
		info["title"] = title + " API"
	}
	data["host"] = getRequestHost(r)
	data["basePath"] = "/rest/"
	data["schemes"] = []string{requestScheme(r)}
	data["securityDefinitions"] = map[string]interface{}{
		"jwt": map[string]interface{}{
			"name": "Authorization",
			"type": "apiKey",
			"in":   "header",
		},
	}
	data["security"] = []map[string][]interface{}{
		{"jwt": {}},
	}
	data["responses"] = map[string]interface{}{
		"UnauthorizedError": map[string]interface{}{
			"description": "JWT authorization is missing, invalid, or insufficient",
		},
	}
	return data
}

func requestScheme(r *http.Request) string {
	if forwardedProto := strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")); forwardedProto != "" {
		if beforeComma, _, found := strings.Cut(forwardedProto, ","); found {
			return strings.TrimSpace(beforeComma)
		}
		return forwardedProto
	}
	if r.URL.Scheme != "" {
		return r.URL.Scheme
	}
	if r.TLS != nil {
		return "https"
	}
	return "http"
}

// getOpenAPIHandler serves the OpenAPI document behind the "API" link.
//
// The session is optional here, unlike every other endpoint authapp exposes.
// The document describes the endpoints the caller may actually use, so it is
// fetched with the caller's own JWT when there is one -- and with none at all
// when there is not, which gives the anonymous role's view: meetings,
// ui_elements, platform_version. That is a true and useful answer.
//
// Requiring a session here instead produced a page that could only fail. The
// "API" link is in the navigation for everyone, signed in or not, and following
// it without a session reached Swagger UI's bare "Failed to load API
// definition." -- a message from a library that knows nothing about this course
// and cannot say that logging in would help.
func getOpenAPIHandler(config FetchJWTConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		setNoStoreHeaders(w)
		log.Println("Triggered the getOpenAPIHandler")

		// No netid means no session, and the anonymous document below.
		jwt := ""
		if netID, ok := r.Context().Value("netid").(string); ok && netID != "" {
			var err error
			var statusCode int
			jwt, err, statusCode = fetchUserJWT(netID, config)
			if err != nil {
				log.Printf("Error fetching JWT: %v", err)
				http.Error(w, http.StatusText(statusCode), statusCode)
				return
			}
		}

		data, err, statusCode := fetchOpenAPI(jwt, config)
		if err != nil {
			log.Printf("Error fetching OpenAPI: %v", err)
			http.Error(w, http.StatusText(statusCode), statusCode)
			return
		}

		encodedData, err := json.Marshal(enrichOpenAPI(data, r))
		if err != nil {
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Write(encodedData)
	}
}
