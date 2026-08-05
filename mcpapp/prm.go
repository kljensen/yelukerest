package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
)

// protectedResourceMetadata is the RFC 9728 OAuth protected resource metadata
// document. Phase 0 (issue #265): authorization_servers may be empty until the
// Hydra authorization server is wired up.
type protectedResourceMetadata struct {
	Resource               string   `json:"resource"`
	AuthorizationServers   []string `json:"authorization_servers"`
	BearerMethodsSupported []string `json:"bearer_methods_supported"`
}

func protectedResourceMetadataHandler(resourceURL string, authorizationServerURL string) http.Handler {
	servers := []string{}
	if authorizationServerURL != "" {
		servers = append(servers, authorizationServerURL)
	}
	body, err := json.Marshal(protectedResourceMetadata{
		Resource:               resourceURL,
		AuthorizationServers:   servers,
		BearerMethodsSupported: []string{"header"},
	})
	if err != nil {
		log.Panicf("cannot marshal protected resource metadata: %v", err)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// RFC 9728 metadata is public; browser-based MCP clients fetch it
		// cross-origin during OAuth discovery.
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD, OPTIONS")
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	})
}

// metadataURLForResource derives the protected-resource-metadata URL that 401
// responses advertise in WWW-Authenticate. Per RFC 9728, a resource with a
// path component (https://host/mcp) is described at the path-specific
// well-known URL (/.well-known/oauth-protected-resource/mcp).
func metadataURLForResource(resourceURL string) (string, error) {
	parsed, err := url.Parse(resourceURL)
	if err != nil {
		return "", fmt.Errorf("resource URL is not a URL: %w", err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("resource URL %q must be absolute", resourceURL)
	}
	metadata := url.URL{
		Scheme: parsed.Scheme,
		Host:   parsed.Host,
		Path:   protectedResourceMetadataPath + metadataPathSuffix(parsed.Path),
	}
	return metadata.String(), nil
}

// metadataPathSuffix returns the resource URL's path for appending to the
// well-known prefix ("" for a root resource, "/mcp" for https://host/mcp).
func metadataPathSuffix(resourcePath string) string {
	if resourcePath == "" || resourcePath == "/" {
		return ""
	}
	return strings.TrimSuffix(resourcePath, "/")
}
