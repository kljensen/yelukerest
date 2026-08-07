package main

// Token exchange: a verified Hydra access token becomes an internal
// PostgREST/MCP credential (issue #274, ADR 0001 "Hydra tokens never reach
// PostgREST").
//
// The exchange calls api.issue_user_jwt_for_mcp through PostgREST with
// mcpapp's own service credential (MCPAPP_JWT, role=app app_name=mcpapp —
// distinct from authapp's, so either can be revoked alone). The database
// mints a ~10 minute dual-audience user JWT and writes an append-only mint
// audit row naming the external issuer/subject/jti/client in the same
// transaction.
//
// Only the netid from verified token claims and the mapped scopes are sent;
// nothing from the request body or query string ever reaches this call.
//
// Caching: minting is a database round trip plus an audit row per call, so
// results are cached per (netid, OAuth client, scopes). Two rules bound the
// cache, the second from the issue #266 review:
//
//   - A cached entry lives at most until min(internal exp, outer token exp),
//     minus a safety margin and a small jitter.
//   - An entry is never served past the *presenting* token's expiry, even if
//     it was minted under a longer-lived one.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// exchangeRPCPath is the PostgREST route for the minting function.
	exchangeRPCPath = "/rpc/issue_user_jwt_for_mcp"
	// exchangeSafetyMargin retires a cached internal token before it actually
	// expires, so a token handed to a tool has time to complete its request.
	exchangeSafetyMargin = 60 * time.Second
	// exchangeMaxJitter spreads re-mints of tokens issued at the same moment.
	exchangeMaxJitter = 15 * time.Second
	// exchangeMaxCacheEntries bounds the cache; entries are pruned when it is
	// reached so a stream of distinct subjects cannot grow it without limit.
	exchangeMaxCacheEntries = 4096
	// exchangeMaxScopes matches the cardinality cap in
	// api.issue_user_jwt_for_mcp.
	exchangeMaxScopes = 16
)

// externalRef is the verified external-token identity recorded in the mint
// audit row. It grants nothing.
type externalRef struct {
	Issuer   string
	Subject  string
	JTI      string
	ClientID string
	// IssuedAt is the token's iat as a Unix timestamp, or zero when absent.
	// The database compares it against any recorded disconnect for this
	// (user, client) pair, so a reconnection mints again while the grant the
	// user cut off does not (issue #277).
	IssuedAt int64
}

// exchangeRequest is everything the exchange needs about one caller.
type exchangeRequest struct {
	netID    string
	scopes   []string
	external externalRef
	// outerExp is the presented access token's expiry. No internal credential
	// is served for this request after it.
	outerExp time.Time
}

// mintedToken is one internal credential plus the database's authoritative
// answer about who the caller is.
type mintedToken struct {
	token     string
	userID    string
	netID     string
	role      string
	expiresAt time.Time
}

type exchangeCacheEntry struct {
	minted mintedToken
	// notAfter is the last instant this entry may be served.
	notAfter time.Time
}

type tokenExchanger struct {
	postgrest  *postgrestClient
	serviceJWT string
	now        func() time.Time
	// jitter is injectable so tests are deterministic.
	jitter func() time.Duration

	mu    sync.Mutex
	cache map[string]exchangeCacheEntry
}

func newTokenExchanger(postgrest *postgrestClient, serviceJWT string) *tokenExchanger {
	return &tokenExchanger{
		postgrest:  postgrest,
		serviceJWT: serviceJWT,
		now:        time.Now,
		jitter: func() time.Duration {
			return time.Duration(rand.Int63n(int64(exchangeMaxJitter)))
		},
		cache: make(map[string]exchangeCacheEntry),
	}
}

// exchangeCacheKey identifies one cache entry. The OAuth client is part of the
// key on top of (netid, scopes): reusing one client's credential for another
// would leave the mint-audit row naming only the first client, and knowing
// which client reached which student's data is exactly what the audit trail
// is for. The extra cost is one mint per client per TTL.
//
// Components are length-prefixed so no component's contents can be arranged to
// look like a different tuple.
func exchangeCacheKey(netID string, clientID string, issuedAt int64, scopes []string) string {
	// issuedAt is part of the identity, not decoration. Keyed by
	// (user, client, scopes) alone, the cache would serve the credential
	// minted for a NEW grant to a token from the old one after a disconnect
	// and reconnect — and a cache hit never reaches the database, so it never
	// meets the revocation check (issue #277). Keying on the token's
	// issued-at keeps each grant's credentials to itself, while still saving
	// a mint on every request across that token's life, which is the point of
	// the cache.
	//
	// Every component stays length-prefixed so no value containing the
	// separators can impersonate a different tuple.
	joined := strings.Join(scopes, " ")
	return fmt.Sprintf("%d:%s|%d:%s|%d:%d|%d:%s",
		len(netID), netID,
		len(clientID), clientID,
		len(strconv.FormatInt(issuedAt, 10)), issuedAt,
		len(joined), joined)
}

// exchangeCacheKeyPrefix is the prefix every entry for one netid shares.
func exchangeCacheKeyPrefix(netID string) string {
	return fmt.Sprintf("%d:%s|", len(netID), netID)
}

// tokenFor returns an internal credential for one verified caller, minting a
// new one when nothing usable is cached.
func (e *tokenExchanger) tokenFor(ctx context.Context, request exchangeRequest) (mintedToken, error) {
	if request.netID == "" {
		return mintedToken{}, errors.New("the access token carries no netid, so no course credential can be issued")
	}
	if len(request.scopes) == 0 {
		return mintedToken{}, errors.New("the access token granted no yelukerest scopes, so no course credential can be issued")
	}
	if len(request.scopes) > exchangeMaxScopes {
		return mintedToken{}, fmt.Errorf("the access token granted more than %d scopes", exchangeMaxScopes)
	}
	if e.serviceJWT == "" {
		return mintedToken{}, errors.New("OAuth token exchange is not configured on this deployment (the MCP service credential is missing); ask the operator to set MCPAPP_JWT")
	}

	now := e.now()
	key := exchangeCacheKey(request.netID, request.external.ClientID, request.external.IssuedAt, request.scopes)
	if entry, ok := e.lookup(key); ok && now.Before(entry.notAfter) && now.Before(request.outerExp) {
		return entry.minted, nil
	}

	if !now.Before(request.outerExp) {
		return mintedToken{}, errors.New("the access token has expired; re-authenticate and retry")
	}

	minted, err := e.mint(ctx, request)
	if err != nil {
		return mintedToken{}, err
	}
	// The mint is a network round trip: re-read the clock so a token that
	// expired while it was in flight cannot still reach PostgREST.
	if after := e.now(); !after.Before(request.outerExp) {
		return mintedToken{}, errors.New("the access token expired while the credential was being issued; re-authenticate and retry")
	}
	e.store(key, minted, request.outerExp, now)
	return minted, nil
}

func (e *tokenExchanger) lookup(key string) (exchangeCacheEntry, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	entry, ok := e.cache[key]
	return entry, ok
}

// store caches a freshly minted token. The entry's life is the shorter of the
// internal token's own expiry and the presented token's expiry, less a safety
// margin and jitter; an entry that would already be dead is not cached at all.
func (e *tokenExchanger) store(key string, minted mintedToken, outerExp time.Time, now time.Time) {
	if minted.expiresAt.IsZero() {
		// The minted token's exp could not be read; caching it would mean
		// caching something with an unknown lifetime.
		return
	}
	notAfter := minted.expiresAt
	if !outerExp.IsZero() && outerExp.Before(notAfter) {
		notAfter = outerExp
	}
	notAfter = notAfter.Add(-(exchangeSafetyMargin + e.jitter()))
	if !notAfter.After(now) {
		return
	}

	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.cache) >= exchangeMaxCacheEntries {
		for cached, entry := range e.cache {
			if !entry.notAfter.After(now) {
				delete(e.cache, cached)
			}
		}
		if len(e.cache) >= exchangeMaxCacheEntries {
			// Still full of live entries: drop everything rather than grow
			// without bound. The cost is re-minting, never a wrong answer.
			e.cache = make(map[string]exchangeCacheEntry, exchangeMaxCacheEntries)
		}
	}
	e.cache[key] = exchangeCacheEntry{minted: minted, notAfter: notAfter}
}

// forget drops every cached credential for one netid, across clients and
// scope sets. It is the hook the revocation work (issue #275) needs.
func (e *tokenExchanger) forget(netID string) {
	prefix := exchangeCacheKeyPrefix(netID)
	e.mu.Lock()
	defer e.mu.Unlock()
	for key := range e.cache {
		if strings.HasPrefix(key, prefix) {
			delete(e.cache, key)
		}
	}
}

// mintResult is the single row api.issue_user_jwt_for_mcp returns.
type mintResult struct {
	JWT    string `json:"jwt"`
	UserID int    `json:"user_id"`
	NetID  string `json:"netid"`
	Role   string `json:"role"`
}

// mint performs the audited minting call. Upstream response bodies are mapped
// to short, actionable messages; they are never echoed to MCP clients.
func (e *tokenExchanger) mint(ctx context.Context, request exchangeRequest) (mintedToken, error) {
	external := map[string]string{}
	for key, value := range map[string]string{
		"iss":       request.external.Issuer,
		"sub":       request.external.Subject,
		"jti":       request.external.JTI,
		"client_id": request.external.ClientID,
	} {
		if value != "" {
			external[key] = value
		}
	}
	// The database compares this against any recorded disconnect for the
	// same (user, client), so a token issued after the user reconnected the
	// application still mints while the one they cut off does not. Sent as
	// text because p_external is a jsonb of strings; the function casts it.
	if request.external.IssuedAt > 0 {
		external["iat"] = strconv.FormatInt(request.external.IssuedAt, 10)
	}
	payload, err := json.Marshal(map[string]any{
		"p_netid":    request.netID,
		"p_scopes":   request.scopes,
		"p_external": external,
	})
	if err != nil {
		return mintedToken{}, errors.New("could not build the credential request")
	}

	headers := http.Header{}
	// Ask PostgREST for the single row as an object rather than an array.
	headers.Set("Accept", "application/vnd.pgrst.object+json")
	status, body, err := e.postgrest.do(ctx, e.serviceJWT, http.MethodPost, exchangeRPCPath, nil, payload, headers)
	if err != nil {
		return mintedToken{}, err
	}
	if status != http.StatusOK {
		return mintedToken{}, mintStatusError(status, body)
	}

	var result mintResult
	if err := json.Unmarshal(body, &result); err != nil {
		return mintedToken{}, errors.New("the course API returned an unreadable credential response")
	}
	if result.JWT == "" {
		return mintedToken{}, errors.New("your account is not authorized for MCP access")
	}

	minted := mintedToken{
		token: result.JWT,
		netID: result.NetID,
		role:  result.Role,
	}
	if result.UserID > 0 {
		minted.userID = strconv.Itoa(result.UserID)
	}
	// The internal token's own exp bounds how long it may be cached. It is
	// read, not trusted for authorization: PostgREST verifies the signature.
	if claims, err := decodeJWTClaims(jwtPayloadSegment(result.JWT)); err == nil {
		if exp, err := numericDateClaim(claims, "exp"); err == nil {
			minted.expiresAt = time.Unix(exp, 0)
		}
	}
	return minted, nil
}

func mintStatusError(status int, body []byte) error {
	switch status {
	case http.StatusNotFound, http.StatusNotAcceptable:
		// No row: the netid is unknown to the course database.
		return errors.New("your account is not enrolled in this course app")
	case http.StatusForbidden:
		// insufficient_privilege covers several refusals, and telling them
		// apart matters to the person reading the answer. A disconnected
		// application is the one they can fix themselves, and "not permitted
		// by course policy" would send them to the registrar instead of to
		// the reconnect button. The database's own message is matched rather
		// than echoed, so nothing from upstream reaches an MCP client.
		if bytes.Contains(body, []byte("this application was disconnected")) {
			return errors.New("you disconnected this application from your course account; reconnect it to continue")
		}
		// The role is not mintable for MCP, or the service credential is not
		// app_name=mcpapp.
		return errors.New("MCP access is not permitted for your account by course policy")
	case http.StatusUnauthorized:
		return errors.New("the MCP service credential was rejected by the course API; ask the operator to check MCPAPP_JWT")
	case http.StatusBadRequest:
		return errors.New("the course API rejected the credential request parameters")
	default:
		return fmt.Errorf("the course API returned HTTP %d while issuing a credential", status)
	}
}

// jwtPayloadSegment returns a JWT's claims segment, or "" when the string is
// not shaped like a JWT.
func jwtPayloadSegment(token string) string {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return ""
	}
	return parts[1]
}

// ---- scope mapping ----

// externalScopeMap translates OAuth scopes granted at consent into the
// granular scope names authorizeScope and api.issue_user_jwt_for_mcp
// understand. Scopes outside this table (openid, offline_access, profile, or
// anything a client invents) are dropped: they grant nothing here, and
// passing them through would waste the database's 16-scope budget.
var externalScopeMap = map[string][]string{
	"course:read":       {"course:read"},
	"grades:read":       {"grades:read"},
	"submissions:read":  {"submissions:read"},
	"submissions:write": {"submissions:write"},
	// The coarse names remain valid for hand-written clients.
	"read":  {"course:read", "grades:read", "submissions:read"},
	"write": {"submissions:write"},
}

// mapExternalScopes maps granted OAuth scopes to internal scopes, preserving
// first-seen order and dropping duplicates. An empty result means the token
// grants no MCP access at all (see authorizeScope).
func mapExternalScopes(granted []string) []string {
	mapped := make([]string, 0, len(granted))
	seen := make(map[string]bool, len(granted))
	for _, scope := range granted {
		for _, internal := range externalScopeMap[strings.TrimSpace(scope)] {
			if seen[internal] {
				continue
			}
			seen[internal] = true
			mapped = append(mapped, internal)
		}
	}
	if len(mapped) == 0 {
		return nil
	}
	if len(mapped) > exchangeMaxScopes {
		mapped = mapped[:exchangeMaxScopes]
	}
	return mapped
}
