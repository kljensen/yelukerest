package main

// Reverse proxy for Hydra's Dynamic Client Registration (DCR) endpoints
// (issue #272).
//
// Hydra's DCR responses include null-valued and empty-string optional
// fields ("contacts": null, "client_uri": "", ...) that strict-parser
// MCP clients (mcp-remote, Cursor, anything built on the TypeScript
// SDK) reject. Upstream bug: https://github.com/ory/hydra/issues/4044
// (fix PR #4050 unmerged). Until that ships, this proxy sits between
// Caddy and Hydra's public port for /oauth2/register and cleans the
// JSON responses. Delete this file when the upstream fix ships.
//
// The same choke point applies registration hardening: a per-IP rate
// limit, a request body cap, and redirect_uri count/length/scheme
// validation, so hostile registration payloads never reach Hydra.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	// registerMaxBodyBytes caps DCR request bodies. Caddy enforces the
	// same 64KB limit; this is belt-and-suspenders.
	registerMaxBodyBytes = 64 * 1024
	// registerMaxRedirectURIs caps how many redirect URIs a single
	// client registration may carry. Real MCP clients register one.
	registerMaxRedirectURIs = 10
	// registerMaxRedirectURILen caps individual redirect URI length.
	registerMaxRedirectURILen = 2000
	// registerMaxResponseBytes caps how much of Hydra's response is
	// buffered for cleaning. DCR responses are a few KB.
	registerMaxResponseBytes = 1 << 20
)

// The field lists below come from the issue #271 audience spike, which
// recorded exactly what Hydra v26.2.0 returns for a DCR client: null
// for contacts, skip_logout_consent, and thirteen *_lifespan fields;
// empty strings for owner and the optional URI fields; empty arrays
// for allowed_cors_origins (and audience when no allowlist is set);
// empty objects for jwks and metadata. Nulls are stripped wherever
// they appear; the empty-value rules are limited to these named
// optional fields so meaningful values like client_secret_expires_at
// (0) and scope survive untouched.

// emptyStringFields are optional client metadata fields removed when
// Hydra returns them as empty strings.
var emptyStringFields = map[string]bool{
	"owner":      true,
	"client_uri": true,
	"logo_uri":   true,
	"tos_uri":    true,
	"policy_uri": true,
}

// emptyArrayFields are optional client metadata fields removed when
// Hydra returns them as empty arrays. A non-empty audience (which the
// proxy injects at registration) is never stripped.
var emptyArrayFields = map[string]bool{
	"contacts":             true,
	"allowed_cors_origins": true,
	"audience":             true,
}

// emptyObjectFields are optional client metadata fields removed when
// Hydra returns them as empty objects.
var emptyObjectFields = map[string]bool{
	"jwks":     true,
	"metadata": true,
}

// hopByHopHeaders are never copied between the client and Hydra.
// Content-Length is recomputed on both legs (audience injection and
// response cleaning change body sizes).
var hopByHopHeaders = []string{
	"Content-Length",
	"Connection",
	"Keep-Alive",
	"Proxy-Authenticate",
	"Proxy-Authorization",
	"Proxy-Connection",
	"Te",
	"Trailer",
	"Transfer-Encoding",
	"Upgrade",
}

type registerProxyConfig struct {
	// HydraPublicURL is the internal base URL of Hydra's public API,
	// e.g. http://hydra:4444 (env HYDRA_PUBLIC_INTERNAL_URL).
	HydraPublicURL string
	// MCPAudience is the MCP resource URL (e.g. https://example.com/mcp)
	// injected as the client's audience allowlist at registration when
	// the client does not send one. Hydra re-validates granted
	// audiences against this allowlist at refresh time; a client
	// registered with an empty allowlist gets a working initial token
	// but every refresh fails with "Requested audience has not been
	// whitelisted" (issue #271 spike). Empty disables injection.
	MCPAudience string
	// Client overrides the upstream HTTP client (used by tests).
	Client *http.Client
}

// getRegisterProxyHandler returns the handler for /oauth2/register and
// /oauth2/register/{id}, wrapped in the given per-IP rate limiters. Every
// limiter must allow the request for it to reach Hydra, which is how one
// short window sized for a class arriving together is combined with a longer
// one that bounds sustained abuse. They are consulted in the order given and
// a limiter only counts requests the ones before it allowed, so a caller
// already being throttled per minute does not also burn the longer budget.
func getRegisterProxyHandler(config registerProxyConfig, limiters ...*rateLimiter) http.Handler {
	if config.Client == nil {
		config.Client = &http.Client{Timeout: 15 * time.Second}
	}
	config.HydraPublicURL = strings.TrimRight(config.HydraPublicURL, "/")
	var handler http.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveRegisterProxy(w, r, config)
	})
	for i := len(limiters) - 1; i >= 0; i-- {
		handler = rateLimitMiddleware(limiters[i], handler)
	}
	return handler
}

func serveRegisterProxy(w http.ResponseWriter, r *http.Request, config registerProxyConfig) {
	hydraBase := config.HydraPublicURL
	client := config.Client
	if !isValidRegisterRequest(w, r) {
		return
	}

	// Read (and cap) the request body. POST registers a client and PUT
	// updates one; both carry client metadata that must be validated.
	body, ok := readRegisterBody(w, r)
	if !ok {
		return
	}
	if r.Method == http.MethodPost || r.Method == http.MethodPut {
		payload, err := parseRegistrationPayload(body)
		if err == nil {
			err = validateRegistrationPayload(payload)
		}
		if err != nil {
			var regErr *registrationError
			if errors.As(err, &regErr) {
				writeRegistrationError(w, http.StatusBadRequest, regErr.Code, regErr.Description)
			} else {
				writeRegistrationError(w, http.StatusBadRequest, "invalid_client_metadata", err.Error())
			}
			return
		}
		body = injectRegistrationAudience(body, payload, config.MCPAudience)
	}

	upstreamURL := hydraBase + r.URL.EscapedPath()
	if r.URL.RawQuery != "" {
		upstreamURL += "?" + r.URL.RawQuery
	}
	upstreamRequest, err := http.NewRequestWithContext(r.Context(), r.Method, upstreamURL, bytes.NewReader(body))
	if err != nil {
		log.Println("register proxy: building upstream request failed:", err)
		writeRegistrationError(w, http.StatusBadGateway, "server_error", "could not reach registration service")
		return
	}
	copyProxyHeaders(upstreamRequest.Header, r.Header)

	response, err := client.Do(upstreamRequest)
	if err != nil {
		log.Println("register proxy: upstream request failed:", err)
		writeRegistrationError(w, http.StatusBadGateway, "server_error", "could not reach registration service")
		return
	}
	defer response.Body.Close()

	responseBody, err := io.ReadAll(io.LimitReader(response.Body, registerMaxResponseBytes))
	if err != nil {
		log.Println("register proxy: reading upstream response failed:", err)
		writeRegistrationError(w, http.StatusBadGateway, "server_error", "could not read registration response")
		return
	}

	// Clean successful JSON responses (ory/hydra#4044). Status codes
	// and non-2xx bodies pass through untouched.
	if response.StatusCode >= 200 && response.StatusCode < 300 && isJSONContentType(response.Header.Get("Content-Type")) && len(responseBody) > 0 {
		cleaned, err := cleanDCRResponseJSON(responseBody)
		if err != nil {
			// Fail open: an uncleanable body is passed through
			// unchanged rather than turned into an error.
			log.Println("register proxy: could not clean response JSON:", err)
		} else {
			responseBody = cleaned
		}
	}

	copyProxyHeaders(w.Header(), response.Header)
	w.Header().Del("Content-Length")
	w.WriteHeader(response.StatusCode)
	if _, err := w.Write(responseBody); err != nil {
		log.Println("register proxy: writing response failed:", err)
	}
}

// isValidRegisterRequest enforces the path/method surface: POST on
// /oauth2/register, and GET/PUT/DELETE on /oauth2/register/{id}.
func isValidRegisterRequest(w http.ResponseWriter, r *http.Request) bool {
	path := r.URL.Path
	if path == "/oauth2/register" {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writeRegistrationError(w, http.StatusMethodNotAllowed, "invalid_request", "method not allowed")
			return false
		}
		return true
	}

	remainder, found := strings.CutPrefix(path, "/oauth2/register/")
	if !found || remainder == "" || strings.Contains(remainder, "/") {
		writeRegistrationError(w, http.StatusNotFound, "invalid_request", "not found")
		return false
	}
	switch r.Method {
	case http.MethodGet, http.MethodPut, http.MethodDelete:
		return true
	default:
		w.Header().Set("Allow", "GET, PUT, DELETE")
		writeRegistrationError(w, http.StatusMethodNotAllowed, "invalid_request", "method not allowed")
		return false
	}
}

func readRegisterBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	if r.Body == nil {
		return nil, true
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, registerMaxBodyBytes))
	if err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeRegistrationError(w, http.StatusRequestEntityTooLarge, "invalid_client_metadata", "request body too large")
		} else {
			writeRegistrationError(w, http.StatusBadRequest, "invalid_request", "could not read request body")
		}
		return nil, false
	}
	return body, true
}

type registrationError struct {
	Code        string
	Description string
}

func (e *registrationError) Error() string {
	return e.Description
}

// parseRegistrationPayload decodes a registration body into a JSON
// object, rejecting anything that is not one.
func parseRegistrationPayload(body []byte) (map[string]any, error) {
	badPayload := &registrationError{Code: "invalid_client_metadata", Description: "request body must be a JSON object"}
	if len(bytes.TrimSpace(body)) == 0 {
		return nil, badPayload
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var payload map[string]any
	if err := decoder.Decode(&payload); err != nil || payload == nil {
		return nil, badPayload
	}
	return payload, nil
}

// validateRegistrationPayload rejects registration payloads with too
// many, too long, or non-https (excepting loopback http) redirect URIs
// before they reach Hydra.
func validateRegistrationPayload(payload map[string]any) error {
	rawURIs, present := payload["redirect_uris"]
	if !present || rawURIs == nil {
		return nil
	}
	uris, ok := rawURIs.([]any)
	if !ok {
		return &registrationError{Code: "invalid_redirect_uri", Description: "redirect_uris must be an array of strings"}
	}
	if len(uris) > registerMaxRedirectURIs {
		return &registrationError{
			Code:        "invalid_redirect_uri",
			Description: fmt.Sprintf("too many redirect_uris (max %d)", registerMaxRedirectURIs),
		}
	}
	for _, item := range uris {
		raw, ok := item.(string)
		if !ok {
			return &registrationError{Code: "invalid_redirect_uri", Description: "redirect_uris must be an array of strings"}
		}
		if len(raw) > registerMaxRedirectURILen {
			return &registrationError{
				Code:        "invalid_redirect_uri",
				Description: fmt.Sprintf("redirect_uri exceeds %d characters", registerMaxRedirectURILen),
			}
		}
		if err := validateRedirectURI(raw); err != nil {
			return err
		}
	}
	return nil
}

// injectRegistrationAudience ensures the MCP resource URL is present in the
// client's audience allowlist (see registerProxyConfig.MCPAudience). Hydra
// re-validates granted audiences against this allowlist at refresh time, so a
// client that registers its own audience list without ours would obtain a
// working first token and then fail every refresh (issue #271 spike). Any
// client-supplied entries are preserved. When the audience is already present
// the original request bytes are forwarded untouched.
func injectRegistrationAudience(body []byte, payload map[string]any, audience string) []byte {
	if audience == "" {
		return body
	}
	switch existing := payload["audience"].(type) {
	case []any:
		for _, item := range existing {
			if text, ok := item.(string); ok && text == audience {
				return body
			}
		}
		payload["audience"] = append(append([]any{}, existing...), audience)
	case string:
		if existing == audience {
			return body
		}
		if existing != "" {
			payload["audience"] = []string{existing, audience}
			break
		}
		payload["audience"] = []string{audience}
	default:
		payload["audience"] = []string{audience}
	}
	injected, err := json.Marshal(payload)
	if err != nil {
		// Cannot happen for a decoded JSON object; forward the
		// original body rather than fail the registration.
		log.Println("register proxy: audience injection failed:", err)
		return body
	}
	return injected
}

// validateRedirectURI allows https URIs, plus http URIs whose host is
// exactly localhost or 127.0.0.1 (native-app loopback flows). Host is
// compared after parsing, so http://localhost.evil.com is rejected.
func validateRedirectURI(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil {
		return &registrationError{Code: "invalid_redirect_uri", Description: "redirect_uri is not a valid URI"}
	}
	switch strings.ToLower(parsed.Scheme) {
	case "https":
		return nil
	case "http":
		host := strings.ToLower(parsed.Hostname())
		if host == "localhost" || host == "127.0.0.1" {
			return nil
		}
		return &registrationError{
			Code:        "invalid_redirect_uri",
			Description: "http redirect_uris are only allowed for localhost or 127.0.0.1",
		}
	default:
		return &registrationError{
			Code:        "invalid_redirect_uri",
			Description: "redirect_uri must use https (or http on localhost/127.0.0.1)",
		}
	}
}

func writeRegistrationError(w http.ResponseWriter, status int, code string, description string) {
	setNoStoreHeaders(w)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	payload := map[string]string{
		"error":             code,
		"error_description": description,
	}
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Println("register proxy: writing error response failed:", err)
	}
}

func isJSONContentType(contentType string) bool {
	mediaType, _, _ := strings.Cut(contentType, ";")
	mediaType = strings.ToLower(strings.TrimSpace(mediaType))
	return mediaType == "application/json" || strings.HasSuffix(mediaType, "+json")
}

// cleanDCRResponseJSON re-marshals a Hydra DCR response with the
// fields that break strict parsers removed (ory/hydra#4044):
//   - any null-valued object field, at any depth
//   - owner/client_uri/logo_uri/tos_uri/policy_uri when empty strings
//   - contacts/allowed_cors_origins/audience when empty arrays
//   - jwks/metadata when empty objects
//
// Everything else is preserved: meaningful zero values such as
// client_secret_expires_at (0) survive via json.Number, non-empty
// audience allowlists (which the proxy injects at registration) are
// kept, and unknown fields pass through.
func cleanDCRResponseJSON(body []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return json.Marshal(cleanDCRValue(value))
}

// opaqueFields hold client-controlled data that must pass through verbatim:
// cleaning inside them would silently mutate a client's own extension values
// (e.g. metadata: {"flag": null}).
var opaqueFields = map[string]bool{"metadata": true, "jwks": true}

func cleanDCRValue(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		result := make(map[string]any, len(typed))
		for key, item := range typed {
			if item == nil {
				continue
			}
			if text, ok := item.(string); ok && text == "" && emptyStringFields[key] {
				continue
			}
			if opaqueFields[key] {
				// Drop it only when Hydra emitted it entirely empty;
				// otherwise forward the client's data untouched.
				if object, ok := item.(map[string]any); ok && len(object) == 0 {
					continue
				}
				result[key] = item
				continue
			}
			cleaned := cleanDCRValue(item)
			if array, ok := cleaned.([]any); ok && len(array) == 0 && emptyArrayFields[key] {
				continue
			}
			if object, ok := cleaned.(map[string]any); ok && len(object) == 0 && emptyObjectFields[key] {
				continue
			}
			result[key] = cleaned
		}
		return result
	case []any:
		result := make([]any, 0, len(typed))
		for _, item := range typed {
			result = append(result, cleanDCRValue(item))
		}
		return result
	default:
		return value
	}
}

func copyProxyHeaders(destination http.Header, source http.Header) {
	for key, values := range source {
		if isHopByHopHeader(key) {
			continue
		}
		for _, item := range values {
			destination.Add(key, item)
		}
	}
}

func isHopByHopHeader(name string) bool {
	for _, header := range hopByHopHeaders {
		if strings.EqualFold(name, header) {
			return true
		}
	}
	return false
}
