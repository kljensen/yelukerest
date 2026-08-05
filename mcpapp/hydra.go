package main

// Verification of Hydra-issued OAuth 2.1 access tokens (issue #274, ADR 0001
// phase 1).
//
// Hydra signs access tokens with an asymmetric key and publishes the public
// key set at <issuer>/.well-known/jwks.json. Two facts from the issue #271
// spike shape this file:
//
//   - The published key set contains BOTH the id-token and the access-token
//     signing keys, and a rotated key appears alongside the old one. Keys are
//     therefore selected by the JWT header's `kid`, never by "the first key".
//   - A token minted without an audience grant carries `"aud": []` — an empty
//     array that is present in the claims, not an absent claim. Audience
//     validation is never disabled (ADR caveats register), so a missing,
//     empty, or non-matching `aud` is rejected.
//
// Verified Hydra tokens are never forwarded anywhere: they are exchanged for
// an internal PostgREST credential (exchange.go). The two token domains stay
// disjoint, which is what makes a Hydra misconfiguration unable to produce a
// token PostgREST accepts.

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	// jwksFetchTimeout bounds one JWKS HTTP fetch.
	jwksFetchTimeout = 5 * time.Second
	// jwksMinRefreshInterval rate-limits network fetches triggered by an
	// unknown `kid`. Without it, tokens carrying random kids would let an
	// unauthenticated caller drive one upstream request per request.
	jwksMinRefreshInterval = 30 * time.Second

	// jwksMaxCacheAge bounds how long a cached key set is trusted without
	// re-consulting the authorization server. Without it, a key withdrawn
	// after a compromise would keep verifying tokens for the lifetime of
	// the process.
	jwksMaxCacheAge = 15 * time.Minute
	// jwksMaxBodyBytes bounds how much of a JWKS response is read.
	jwksMaxBodyBytes = 1 << 20
	// jwksMinRSABits rejects undersized RSA keys regardless of what the
	// authorization server publishes.
	jwksMinRSABits = 2048
)

// hydraConfig is the configuration for the OAuth access-token path. A nil
// *hydraConfig means the deployment accepts phase 0 internal tokens only.
type hydraConfig struct {
	// Issuer is the exact expected `iss` claim (Hydra's URLS_SELF_ISSUER,
	// e.g. https://example.com).
	Issuer string
	// JWKSURL is where the public key set is fetched. In the compose stack
	// this is the internal address (http://hydra:4444/.well-known/jwks.json)
	// so the fetch does not traverse Caddy's TLS.
	JWKSURL string
	// Audience is the canonical MCP resource URL that every access token must
	// name in `aud`.
	Audience string
}

// hydraAllowedAlgs is the signature-algorithm allow-list for the OAuth path.
// It is deliberately asymmetric-only: an HMAC alg here would mean verifying a
// caller-supplied token with a shared secret, which is the classic algorithm
// confusion attack. "none" is absent by construction.
var hydraAllowedAlgs = map[string]bool{
	"RS256": true, "RS384": true, "RS512": true,
	"PS256": true, "PS384": true, "PS512": true,
	"ES256": true, "ES384": true, "ES512": true,
}

// hydraAllowedTypes is the accepted set of JWT `typ` header values. RFC 9068
// spells access tokens "at+jwt"; Hydra v26 emits "JWT". An unrecognized type
// (notably an explicitly labelled id token) is refused.
var hydraAllowedTypes = map[string]bool{
	"":                   true,
	"jwt":                true,
	"application/jwt":    true,
	"at+jwt":             true,
	"application/at+jwt": true,
}

type hydraVerifier struct {
	config hydraConfig
	keys   *jwksCache
}

func newHydraVerifier(config hydraConfig, client *http.Client, now func() time.Time) *hydraVerifier {
	if client == nil {
		client = &http.Client{Timeout: jwksFetchTimeout}
	}
	if now == nil {
		now = time.Now
	}
	return &hydraVerifier{
		config: config,
		keys: &jwksCache{
			url:        config.JWKSURL,
			client:     client,
			minRefresh: jwksMinRefreshInterval,
			maxAge:     jwksMaxCacheAge,
			now:        now,
		},
	}
}

// verify checks one Hydra access token and returns the caller identity plus
// the external-token reference recorded in the mint audit trail. Error text is
// returned to the client in the 401 body, so it never contains token material.
func (v *hydraVerifier) verify(ctx context.Context, token string, now time.Time) (*identity, externalRef, error) {
	var noRef externalRef

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, noRef, errors.New("token must have three JWT segments")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, noRef, errors.New("token header is not base64url")
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
		Typ string `json:"typ"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, noRef, errors.New("token header is not JSON")
	}
	if !hydraAllowedAlgs[header.Alg] {
		return nil, noRef, errors.New("token alg is not an accepted OAuth signature algorithm")
	}
	if !hydraAllowedTypes[strings.ToLower(header.Typ)] {
		return nil, noRef, errors.New("token typ header is not an access token")
	}
	if header.Kid == "" {
		// The authorization server publishes several keys (id-token and
		// access-token) and rotation adds more, so a token without a kid
		// cannot be matched to a key without guessing.
		return nil, noRef, errors.New("token header has no kid")
	}

	key, err := v.keys.keyForKID(ctx, header.Kid)
	if err != nil {
		return nil, noRef, err
	}
	if key.alg != "" && key.alg != header.Alg {
		return nil, noRef, errors.New("token alg does not match the signing key")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, noRef, errors.New("token signature is not base64url")
	}
	if err := verifyAsymmetricSignature(header.Alg, key.key, parts[0]+"."+parts[1], signature); err != nil {
		return nil, noRef, err
	}

	claims, err := decodeJWTClaims(parts[1])
	if err != nil {
		return nil, noRef, err
	}

	if err := requireStringClaim(claims, "iss", v.config.Issuer); err != nil {
		return nil, noRef, err
	}
	if err := requireHydraAudience(claims, v.config.Audience); err != nil {
		return nil, noRef, err
	}
	// id tokens carry at_hash; access tokens never do. The audience check
	// above already refuses them (an id token's aud is the client id), but a
	// second, independent reason to refuse costs nothing.
	if _, present := claims["at_hash"]; present {
		return nil, noRef, errors.New("token is an id token, not an access token")
	}

	exp, err := numericDateClaim(claims, "exp")
	if err != nil {
		return nil, noRef, err
	}
	if exp <= now.Unix() {
		return nil, noRef, errors.New("token is expired")
	}
	// iat and nbf are optional here (the spec makes them so), but when the
	// authorization server sends them they are enforced with the same clock
	// skew allowance the internal path uses.
	if _, present := claims["iat"]; present {
		iat, err := numericDateClaim(claims, "iat")
		if err != nil {
			return nil, noRef, err
		}
		if iat > now.Add(clockSkewAllowance).Unix() {
			return nil, noRef, errors.New("token iat is in the future")
		}
	}
	if _, present := claims["nbf"]; present {
		nbf, err := numericDateClaim(claims, "nbf")
		if err != nil {
			return nil, noRef, err
		}
		if nbf > now.Add(clockSkewAllowance).Unix() {
			return nil, noRef, errors.New("token nbf is in the future")
		}
	}

	subject, err := nonEmptyStringClaim(claims, "sub")
	if err != nil {
		return nil, noRef, err
	}
	netID, err := hydraNetID(claims, subject)
	if err != nil {
		return nil, noRef, err
	}

	ref := externalRef{
		Issuer:   v.config.Issuer,
		Subject:  subject,
		JTI:      hydraStringClaim(claims, "jti"),
		ClientID: hydraClientID(claims),
	}

	id := &identity{
		// Subject is advisory only — it keys rate limiting and audit logs.
		// Every authorization decision downstream rides on the internal JWT
		// minted from netID by the database.
		Subject:   hydraSubjectLabel(claims, netID),
		UserID:    hydraUserID(claims),
		NetID:     netID,
		Role:      hydraStringClaim(claims, "role"),
		JTI:       ref.JTI,
		ExpiresAt: time.Unix(exp, 0),
		Scopes:    mapExternalScopes(hydraScopes(claims)),
		External:  true,
		// RawToken stays empty on purpose: a Hydra token must never be
		// forwarded to PostgREST. forwardableToken exchanges it instead.
	}
	return id, ref, nil
}

// requireHydraAudience enforces the strict audience rule from ADR 0001: the
// canonical MCP resource URL must appear in `aud`. A missing claim, an empty
// array, and an array without the resource are all refused.
func requireHydraAudience(claims map[string]any, want string) error {
	if want == "" {
		// Defensive: an unconfigured resource URL must not degrade into
		// "accept everything".
		return errors.New("this server has no configured MCP resource audience")
	}
	audience, present := claims["aud"]
	if !present {
		return errors.New("token missing aud claim")
	}
	switch typed := audience.(type) {
	case string:
		if typed == want {
			return nil
		}
	case []any:
		if len(typed) == 0 {
			return errors.New("token aud claim is empty; the authorization server granted no audience for this resource")
		}
		for _, item := range typed {
			if value, ok := item.(string); ok && value == want {
				return nil
			}
		}
	}
	return fmt.Errorf("token aud claim must include %q", want)
}

// hydraNetID resolves the course netid from verified claims. Hydra sets `sub`
// to the consented subject, which authapp sets to the netid, and duplicates
// identity claims both top-level and under `ext` (issue #271 finding 5).
// A subject of the form user:<id> is an internal-token shape and is never
// treated as a netid.
func hydraNetID(claims map[string]any, subject string) (string, error) {
	if netID := hydraStringClaim(claims, "netid"); netID != "" {
		return netID, nil
	}
	if _, isInternalShape := strings.CutPrefix(subject, "user:"); isInternalShape {
		return "", errors.New("token has no netid claim")
	}
	if subject == "" {
		return "", errors.New("token has no netid claim")
	}
	return subject, nil
}

// hydraStringClaim reads a string claim, falling back to the same name inside
// the `ext` object Hydra nests custom claims under.
func hydraStringClaim(claims map[string]any, key string) string {
	if value, ok := claims[key].(string); ok && value != "" {
		return value
	}
	if ext, ok := claims["ext"].(map[string]any); ok {
		if value, ok := ext[key].(string); ok {
			return value
		}
	}
	return ""
}

// hydraUserID reads the advisory user_id claim (top-level or under ext) as a
// decimal string. It is used only for PostgREST filters, and is replaced by
// the database's own answer once the token exchange runs.
func hydraUserID(claims map[string]any) string {
	for _, value := range []any{claims["user_id"], extClaim(claims, "user_id")} {
		switch typed := value.(type) {
		case json.Number:
			if _, err := typed.Int64(); err == nil {
				return typed.String()
			}
		case string:
			if isAllDigits(typed) {
				return typed
			}
		}
	}
	return ""
}

func extClaim(claims map[string]any, key string) any {
	ext, ok := claims["ext"].(map[string]any)
	if !ok {
		return nil
	}
	return ext[key]
}

// hydraSubjectLabel produces the rate-limiting and audit key. When the token
// carries a usable user_id it matches the phase 0 "user:<id>" shape so the
// same person is rate limited identically on both paths.
func hydraSubjectLabel(claims map[string]any, netID string) string {
	if userID := hydraUserID(claims); userID != "" {
		return "user:" + userID
	}
	return "netid:" + netID
}

// hydraClientID reports the OAuth client that presented the token, for the
// mint audit row. Hydra sets client_id; azp is the OIDC spelling.
func hydraClientID(claims map[string]any) string {
	if value := hydraStringClaim(claims, "client_id"); value != "" {
		return value
	}
	return hydraStringClaim(claims, "azp")
}

// hydraScopes extracts the granted scopes. Hydra v26 emits `scp` as a JSON
// array and authapp's consent handler additionally sets a space-delimited
// `scopes` claim (issue #271 finding 5); both forms are read.
func hydraScopes(claims map[string]any) []string {
	if scopes := scopesFromClaims(claims); len(scopes) > 0 {
		return scopes
	}
	for _, source := range []any{claims["scp"], extClaim(claims, "scp"), extClaim(claims, "scopes")} {
		switch typed := source.(type) {
		case string:
			if fields := strings.Fields(typed); len(fields) > 0 {
				return fields
			}
		case []any:
			scopes := make([]string, 0, len(typed))
			for _, item := range typed {
				if value, ok := item.(string); ok && value != "" {
					scopes = append(scopes, value)
				}
			}
			if len(scopes) > 0 {
				return scopes
			}
		}
	}
	return nil
}

// ---- JWKS cache ----

// jwksKey is one parsed public key from the authorization server's key set.
type jwksKey struct {
	kid string
	alg string // may be empty when the JWK does not declare one
	key any    // *rsa.PublicKey or *ecdsa.PublicKey
}

// jwksCache holds the authorization server's public keys. Refresh policy:
//
//   - Keys are fetched lazily; the first token verification populates the
//     cache.
//   - A `kid` that is not cached triggers one refetch, which is how key
//     rotation is picked up (the spike confirmed a new key is published
//     alongside the old, so no coordination is needed).
//   - Refetches are rate limited to one per jwksMinRefreshInterval and
//     serialized, so a flood of tokens carrying random kids cannot be turned
//     into a flood of upstream requests.
//   - A successful fetch REPLACES the key set, so a key withdrawn upstream
//     stops being accepted here.
type jwksCache struct {
	url        string
	client     *http.Client
	minRefresh time.Duration
	now        func() time.Time

	// maxAge bounds how long a cached key set is trusted without
	// re-consulting the authorization server, so a key withdrawn after a
	// compromise stops verifying tokens within one window rather than
	// living for the lifetime of the process.
	maxAge time.Duration

	// fetchMu serializes network fetches; mu guards the cached state.
	fetchMu sync.Mutex
	mu      sync.RWMutex
	keys    map[string]jwksKey
	// lastAttempt is when a fetch was last started, successful or not.
	lastAttempt time.Time
	// fetchedAt is when the cached key set was last installed.
	fetchedAt time.Time
}

// stale reports whether the cached key set is older than maxAge.
func (c *jwksCache) stale() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.maxAge <= 0 || c.fetchedAt.IsZero() {
		return false
	}
	return c.now().Sub(c.fetchedAt) >= c.maxAge
}

func (c *jwksCache) lookup(kid string) (jwksKey, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	key, ok := c.keys[kid]
	return key, ok
}

// mayFetch reports whether enough time has passed since the last attempt, and
// records this attempt. Failed attempts count too, so an unreachable
// authorization server is retried at the same bounded rate rather than once
// per inbound request. Callers must hold fetchMu.
func (c *jwksCache) mayFetch() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if !c.lastAttempt.IsZero() && now.Sub(c.lastAttempt) < c.minRefresh {
		return false
	}
	c.lastAttempt = now
	return true
}

// keyForKID returns the public key for a token's kid, refetching the key set
// once when the kid is unknown.
func (c *jwksCache) keyForKID(ctx context.Context, kid string) (jwksKey, error) {
	// A known kid is served from cache only while the set is fresh: past
	// maxAge the key set is re-fetched so withdrawn keys stop verifying.
	if key, ok := c.lookup(kid); ok && !c.stale() {
		return key, nil
	}

	c.fetchMu.Lock()
	defer c.fetchMu.Unlock()
	// A concurrent refresh may have installed the key while we waited.
	if key, ok := c.lookup(kid); ok && !c.stale() {
		return key, nil
	}
	if !c.mayFetch() {
		return jwksKey{}, errors.New("token was signed by an unknown key")
	}
	if err := c.fetch(ctx); err != nil {
		return jwksKey{}, err
	}
	if key, ok := c.lookup(kid); ok {
		return key, nil
	}
	return jwksKey{}, errors.New("token was signed by an unknown key")
}

func (c *jwksCache) fetch(ctx context.Context) error {
	if c.url == "" {
		return errors.New("this server has no configured authorization server key set")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
	if err != nil {
		return errors.New("could not build the authorization server key request")
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		// Deliberately generic: transport errors can embed internal URLs.
		return errors.New("the authorization server key set is unreachable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the authorization server key set returned HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, jwksMaxBodyBytes))
	if err != nil {
		return errors.New("could not read the authorization server key set")
	}

	keys, err := parseJWKS(body)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	// Replace rather than merge: a key withdrawn upstream must stop verifying.
	c.keys = keys
	c.fetchedAt = c.now()
	return nil
}

// jwkDocument is the subset of RFC 7517 this server understands.
type jwkDocument struct {
	Keys []struct {
		Kty string `json:"kty"`
		Kid string `json:"kid"`
		Alg string `json:"alg"`
		Use string `json:"use"`
		N   string `json:"n"`
		E   string `json:"e"`
		Crv string `json:"crv"`
		X   string `json:"x"`
		Y   string `json:"y"`
	} `json:"keys"`
}

// parseJWKS turns a JWKS document into usable public keys. Unusable entries
// (encryption keys, unsupported curves, undersized moduli, algorithms outside
// the allow-list) are skipped rather than failing the whole document, so one
// odd key upstream cannot take the server down.
func parseJWKS(body []byte) (map[string]jwksKey, error) {
	var document jwkDocument
	if err := json.Unmarshal(body, &document); err != nil {
		return nil, errors.New("the authorization server key set is not JSON")
	}
	keys := make(map[string]jwksKey, len(document.Keys))
	for _, entry := range document.Keys {
		if entry.Kid == "" || (entry.Use != "" && entry.Use != "sig") {
			continue
		}
		if entry.Alg != "" && !hydraAllowedAlgs[entry.Alg] {
			continue
		}
		var parsed any
		var err error
		switch entry.Kty {
		case "RSA":
			parsed, err = parseRSAJWK(entry.N, entry.E)
		case "EC":
			parsed, err = parseECJWK(entry.Crv, entry.X, entry.Y)
		default:
			continue
		}
		if err != nil {
			continue
		}
		keys[entry.Kid] = jwksKey{kid: entry.Kid, alg: entry.Alg, key: parsed}
	}
	if len(keys) == 0 {
		return nil, errors.New("the authorization server key set has no usable signing keys")
	}
	return keys, nil
}

func parseRSAJWK(modulus string, exponent string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(modulus)
	if err != nil {
		return nil, errors.New("RSA modulus is not base64url")
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(exponent)
	if err != nil {
		return nil, errors.New("RSA exponent is not base64url")
	}
	if len(nBytes)*8 < jwksMinRSABits {
		return nil, errors.New("RSA key is too small")
	}
	e := new(big.Int).SetBytes(eBytes)
	if !e.IsInt64() || e.Int64() < 3 || e.Int64() > 1<<31 {
		return nil, errors.New("RSA exponent is out of range")
	}
	return &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: int(e.Int64())}, nil
}

func parseECJWK(curveName string, x string, y string) (*ecdsa.PublicKey, error) {
	var curve elliptic.Curve
	switch curveName {
	case "P-256":
		curve = elliptic.P256()
	case "P-384":
		curve = elliptic.P384()
	case "P-521":
		curve = elliptic.P521()
	default:
		return nil, errors.New("unsupported EC curve")
	}
	xBytes, err := base64.RawURLEncoding.DecodeString(x)
	if err != nil {
		return nil, errors.New("EC x coordinate is not base64url")
	}
	yBytes, err := base64.RawURLEncoding.DecodeString(y)
	if err != nil {
		return nil, errors.New("EC y coordinate is not base64url")
	}
	key := &ecdsa.PublicKey{
		Curve: curve,
		X:     new(big.Int).SetBytes(xBytes),
		Y:     new(big.Int).SetBytes(yBytes),
	}
	if !curve.IsOnCurve(key.X, key.Y) {
		return nil, errors.New("EC point is not on the curve")
	}
	return key, nil
}

// ---- signature verification ----

// verifyAsymmetricSignature checks a JWS signature. It is reachable only for
// algorithms in hydraAllowedAlgs, and each branch asserts the key type, so a
// token cannot be verified with a key of the wrong kind.
func verifyAsymmetricSignature(alg string, key any, signingInput string, signature []byte) error {
	digest, cryptoHash, err := hashSigningInput(alg, signingInput)
	if err != nil {
		return err
	}
	invalid := errors.New("token signature is invalid")

	switch alg[:2] {
	case "RS":
		public, ok := key.(*rsa.PublicKey)
		if !ok {
			return errors.New("token alg does not match the signing key type")
		}
		if err := rsa.VerifyPKCS1v15(public, cryptoHash, digest, signature); err != nil {
			return invalid
		}
		return nil
	case "PS":
		public, ok := key.(*rsa.PublicKey)
		if !ok {
			return errors.New("token alg does not match the signing key type")
		}
		options := &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash, Hash: cryptoHash}
		if err := rsa.VerifyPSS(public, cryptoHash, digest, signature, options); err != nil {
			return invalid
		}
		return nil
	case "ES":
		public, ok := key.(*ecdsa.PublicKey)
		if !ok {
			return errors.New("token alg does not match the signing key type")
		}
		// JWS ECDSA signatures are the fixed-width R||S concatenation, not
		// the ASN.1 form ecdsa.VerifyASN1 expects.
		size := (public.Curve.Params().BitSize + 7) / 8
		if len(signature) != 2*size {
			return invalid
		}
		r := new(big.Int).SetBytes(signature[:size])
		s := new(big.Int).SetBytes(signature[size:])
		if !ecdsa.Verify(public, digest, r, s) {
			return invalid
		}
		return nil
	}
	return errors.New("token alg is not an accepted OAuth signature algorithm")
}

func hashSigningInput(alg string, signingInput string) ([]byte, crypto.Hash, error) {
	var hasher hash.Hash
	var cryptoHash crypto.Hash
	switch alg[2:] {
	case "256":
		hasher, cryptoHash = sha256.New(), crypto.SHA256
	case "384":
		hasher, cryptoHash = sha512.New384(), crypto.SHA384
	case "512":
		hasher, cryptoHash = sha512.New(), crypto.SHA512
	default:
		return nil, 0, errors.New("token alg is not an accepted OAuth signature algorithm")
	}
	hasher.Write([]byte(signingInput))
	return hasher.Sum(nil), cryptoHash, nil
}
