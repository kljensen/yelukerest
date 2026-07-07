package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
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
	req.Header.Set("Authorization", "Bearer "+jwt)

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
		return nil, fmt.Errorf("unexpected postgrest status %s: %s", resp.Status, string(body)), http.StatusBadGateway
	}

	var data map[string]interface{}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, fmt.Errorf("error parsing openapi response: %v", err), http.StatusBadGateway
	}

	return data, nil, http.StatusOK
}

func enrichOpenAPI(data map[string]interface{}, r *http.Request) map[string]interface{} {
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

func getOpenAPIHandler(config FetchJWTConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Println("Triggered the getOpenAPIHandler")

		netID, ok := r.Context().Value("netid").(string)
		if !ok || netID == "" {
			http.Error(w, "netid is nil", http.StatusUnauthorized)
			return
		}

		jwt, err, statusCode := fetchUserJWT(netID, config)
		if err != nil {
			log.Printf("Error fetching JWT: %v", err)
			http.Error(w, err.Error(), statusCode)
			return
		}

		data, err, statusCode := fetchOpenAPI(jwt, config)
		if err != nil {
			log.Printf("Error fetching OpenAPI: %v", err)
			http.Error(w, err.Error(), statusCode)
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
