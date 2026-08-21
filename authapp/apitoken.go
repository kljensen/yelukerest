package main

// Exchange a personal access token for a short-lived JWT (issue #317).
//
// This is the only endpoint in the personal-access-token feature that needs to
// live in authapp. Creating, listing and revoking tokens are ordinary PostgREST
// calls made with the caller's own JWT, guarded by row-level security. Only the
// exchange is different, because the caller presenting a token is not yet
// authenticated -- there is no session and no JWT to check -- so something has
// to hold the service credential that validates it.
//
// The long-lived token is never forwarded to PostgREST. It is traded here for
// the same one-hour JWT the browser receives, which is what limits the damage
// after a revocation to one hour rather than the token's four-month life.

import (
	"bytes"
	"encoding/base64"
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

// exchangeUserAPITokenURL is the PostgREST RPC that does the real work: it
// checks the presented secret against the stored hash, refuses revoked and
// expired tokens, records last_used_at, and mints a JWT carrying the token's
// scopes.
func exchangeUserAPITokenURL(config FetchJWTConfig) string {
	endpoint := url.URL{
		Scheme: "http",
		Host:   net.JoinHostPort(config.PostgrestHost, config.PostgrestPort),
		Path:   "/rpc/exchange_user_api_token",
	}
	return endpoint.String()
}

type apiTokenExchangeResult struct {
	JWT    string   `json:"jwt"`
	UserID int      `json:"user_id"`
	NetID  string   `json:"netid"`
	Role   string   `json:"role"`
	Scopes []string `json:"scopes"`
}

// apiTokenExchangeResponse is what the caller gets back. `expires_in` is
// included because a client -- often an AI assistant writing the caller's code
// -- should be able to schedule its own refresh rather than discovering expiry
// by way of a 401.
type apiTokenExchangeResponse struct {
	JWT       string   `json:"jwt"`
	TokenType string   `json:"token_type"`
	ExpiresIn int      `json:"expires_in"`
	Scopes    []string `json:"scopes"`
	NetID     string   `json:"netid"`
	Role      string   `json:"role"`
}

// bearerToken pulls the credential out of an Authorization header. Header only:
// a token in a query string lands in access logs, browser history and Referer
// headers, which is exactly the sort of leak this feature exists to avoid.
func bearerToken(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if header == "" {
		return ""
	}
	const prefix = "Bearer "
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}

func exchangeAPIToken(token string, config FetchJWTConfig) (*apiTokenExchangeResult, error, int) {
	requestBody, err := json.Marshal(map[string]string{"p_token": token})
	if err != nil {
		return nil, fmt.Errorf("error creating exchange request body: %v", err), http.StatusInternalServerError
	}

	req, err := http.NewRequest("POST", exchangeUserAPITokenURL(config), bytes.NewReader(requestBody))
	if err != nil {
		return nil, fmt.Errorf("error creating request: %v", err), http.StatusInternalServerError
	}

	req.Header.Set("Authorization", "Bearer "+config.AuthappJWT)
	req.Header.Set("Accept", "application/vnd.pgrst.object+json")
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("postgrest unavailable: %v", err), http.StatusBadGateway
	}
	defer resp.Body.Close()

	responseBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("error reading response: %v", err), http.StatusInternalServerError
	}

	if resp.StatusCode != http.StatusOK {
		switch resp.StatusCode {
		// The RPC returns no rows for every refusal -- unknown prefix, wrong
		// secret, revoked, expired -- and PostgREST turns "no rows" into 406 or
		// 404 when a single object was requested. They are deliberately not
		// distinguished here either: telling a caller which of those happened
		// would let someone probe for prefixes that exist.
		case http.StatusNotAcceptable, http.StatusNotFound:
			return nil, fmt.Errorf("token is not valid"), http.StatusUnauthorized
		case http.StatusUnauthorized:
			return nil, fmt.Errorf("authapp service token rejected by postgrest"), http.StatusBadGateway
		default:
			return nil, fmt.Errorf("unexpected postgrest status %s", resp.Status), http.StatusBadGateway
		}
	}

	var result apiTokenExchangeResult
	if err := json.Unmarshal(responseBody, &result); err != nil {
		return nil, fmt.Errorf("error decoding response: %v", err), http.StatusInternalServerError
	}
	if result.JWT == "" {
		return nil, fmt.Errorf("token is not valid"), http.StatusUnauthorized
	}
	return &result, nil, http.StatusOK
}

// expiresInFromJWT reads `exp` out of the minted token and returns the seconds
// remaining. Derived from the token rather than from configuration on purpose:
// the lifetime lives in a database setting (settings.get('jwt_lifetime')) that
// authapp does not read, so any constant here would be a second source of truth
// waiting to drift. Returns 0 if it cannot be determined, which a client should
// treat as "refresh on 401".
func expiresInFromJWT(token string, now time.Time) int {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return 0
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return 0
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Exp == 0 {
		return 0
	}
	remaining := claims.Exp - now.Unix()
	if remaining < 0 {
		return 0
	}
	return int(remaining)
}

// apiTokenRateLimitKey buckets the exchange limit per TOKEN rather than per IP.
//
// requestClientKey uses the client IP, which is wrong for this endpoint: a
// class sitting behind campus NAT shares one address, so one student's retry
// loop would lock out everyone else. Keying on the token prefix gives each
// credential its own bucket -- a legitimate client needs about one exchange an
// hour, so a tight limit is still generous -- and confines the effect of a
// misbehaving script to its owner.
//
// The prefix is the public half of the token, so using it as a map key does not
// put the secret in memory beyond the request. Callers with no well-formed
// token fall back to the IP bucket, which is what stops someone cycling made-up
// prefixes to get a fresh bucket each time.
func apiTokenRateLimitKey(r *http.Request) string {
	token := bearerToken(r)
	if prefix, _, found := strings.Cut(token, "_"); found {
		// "yk" plus the identifier half: yk_2be8b799
		if rest := token[len(prefix)+1:]; len(rest) > 8 {
			if id, _, ok := strings.Cut(rest, "_"); ok && len(id) == 8 {
				return "tok:" + prefix + "_" + id
			}
		}
	}
	return "ip:" + requestClientKey(r)
}

// exchangeAPITokenHandler serves POST /auth/token.
func exchangeAPITokenHandler(config FetchJWTConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		setNoStoreHeaders(w)

		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}

		token := bearerToken(r)
		if token == "" {
			// WWW-Authenticate so a well-behaved client, and an assistant
			// reading its output, can tell this is a credential problem rather
			// than a routing one.
			w.Header().Set("WWW-Authenticate", `Bearer realm="yelukerest", error="invalid_request"`)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		result, err, status := exchangeAPIToken(token, config)
		if err != nil {
			// Never log the token itself, and never echo it back. The whole
			// point of a credential that lives for months is that it must not
			// end up in a log file.
			log.Printf("API token exchange failed: %v", err)
			if status == http.StatusUnauthorized {
				w.Header().Set("WWW-Authenticate", `Bearer realm="yelukerest", error="invalid_token"`)
			}
			http.Error(w, http.StatusText(status), status)
			return
		}

		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if err := json.NewEncoder(w).Encode(apiTokenExchangeResponse{
			JWT:       result.JWT,
			TokenType: "Bearer",
			ExpiresIn: expiresInFromJWT(result.JWT, time.Now()),
			Scopes:    result.Scopes,
			NetID:     result.NetID,
			Role:      result.Role,
		}); err != nil {
			log.Printf("error writing API token exchange response: %v", err)
		}
	}
}
