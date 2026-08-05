package main

// Intent tokens (issues #267 and #268).
//
// A prepared write returns a short-lived, single-use, HMAC-signed intent
// token binding the caller and the exact change: subject, the jti of the
// access token used to prepare, the target (assignment/field or HTTP
// method/path), a SHA-256 of the content, an expiry, and a random nonce.
// Committing requires presenting the token again along with the same content,
// so an agent steered by injected instructions cannot perform a write the
// user never saw prepared, and a blind client retry cannot double-submit.
//
// The signing key is NOT the JWT secret itself: it is derived as
// HMAC-SHA256(JWT_SECRET, "mcp-intent-v1"), so a leaked intent token can
// never be replayed as (or confused with) a JWT, and vice versa. The token
// wire format is deliberately two base64url segments (payload.signature), not
// three, so it cannot even parse as a JWT.
//
// Single-use enforcement is an in-memory nonce set with TTL. This assumes a
// single mcpapp replica (true for this deployment: one container behind
// Caddy). The nonceStore interface is the seam where a shared store (e.g.
// Postgres or Redis) would drop in if mcpapp ever runs replicated.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"
)

const (
	// intentTokenTTL is how long a prepared change stays committable.
	intentTokenTTL = 5 * time.Minute

	// intentKeyDerivationLabel separates the intent-token key domain from the
	// JWT signing key domain.
	intentKeyDerivationLabel = "mcp-intent-v1"

	// Intent kinds. A token minted for one kind is never accepted by a tool
	// expecting another.
	intentKindSubmission = "submission_change"
	intentKindAPIRequest = "api_request"

	// intentExpectedCreate is the Expected sentinel for a change that creates
	// a new field submission rather than overwriting an existing one.
	intentExpectedCreate = "create"
)

// intentPayload is the signed content of an intent token.
type intentPayload struct {
	Kind      string `json:"kind"`
	Subject   string `json:"sub"`
	TokenJTI  string `json:"jti"`
	Nonce     string `json:"nonce"`
	ExpiresAt int64  `json:"exp"`
	// BodySHA256 is the hex SHA-256 of the prepared content: the submission
	// body for submission_change, the canonical query+body for api_request.
	BodySHA256 string `json:"body_sha256"`

	// submission_change fields.
	AssignmentSlug string `json:"assignment_slug,omitempty"`
	FieldSlug      string `json:"field_slug,omitempty"`
	// Expected is the updated_at the write must find (optimistic concurrency,
	// enforced by the DB's PT409 trigger) or intentExpectedCreate.
	Expected string `json:"expected,omitempty"`
	// SubmissionID is the existing assignment_submission row id, 0 when the
	// commit must create the submission row first.
	SubmissionID     int  `json:"submission_id,omitempty"`
	CreateSubmission bool `json:"create_submission,omitempty"`

	// api_request fields.
	Method string `json:"method,omitempty"`
	Path   string `json:"path,omitempty"`
}

// nonceStore enforces single use of intent tokens. Implementations must be
// safe for concurrent use.
type nonceStore interface {
	// consume marks nonce used until exp. It returns false when the nonce was
	// already consumed (and has not yet expired).
	consume(nonce string, exp time.Time) bool
}

// memoryNonceStore is the single-replica nonceStore (see the package comment
// for the replication caveat).
type memoryNonceStore struct {
	mu   sync.Mutex
	used map[string]time.Time
	now  func() time.Time
}

func newMemoryNonceStore(now func() time.Time) *memoryNonceStore {
	return &memoryNonceStore{used: make(map[string]time.Time), now: now}
}

func (s *memoryNonceStore) consume(nonce string, exp time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	// Opportunistic pruning keeps the map bounded by the number of tokens
	// minted per TTL window.
	for used, until := range s.used {
		if until.Before(now) {
			delete(s.used, used)
		}
	}
	if until, ok := s.used[nonce]; ok && until.After(now) {
		return false
	}
	s.used[nonce] = exp
	return true
}

// intentSigner mints and verifies intent tokens.
type intentSigner struct {
	key    []byte
	nonces nonceStore
	now    func() time.Time
}

// newIntentSigner derives the intent signing key from the shared JWT secret
// and label (see the package comment) and pairs it with an in-memory nonce
// store.
// The consumed-nonce set lives in memory, so a restart would otherwise forget
// which tokens were already spent and let a still-valid token be replayed. A
// per-process salt in the key derivation closes that: tokens minted before a
// restart stop verifying at all. The cost is that a restart invalidates
// in-flight prepares, which is harmless for a five-minute token.
func newIntentSigner(jwtSecret []byte, now func() time.Time) *intentSigner {
	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		log.Panicf("could not generate the intent-token process salt: %v", err)
	}
	mac := hmac.New(sha256.New, jwtSecret)
	mac.Write([]byte(intentKeyDerivationLabel))
	mac.Write(salt)
	return &intentSigner{
		key:    mac.Sum(nil),
		nonces: newMemoryNonceStore(now),
		now:    now,
	}
}

// mint signs payload for id, filling in the binding fields (subject, token
// jti), a fresh nonce, and the expiry. It returns the token and its expiry.
func (s *intentSigner) mint(payload intentPayload, id *identity) (string, time.Time, error) {
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return "", time.Time{}, errors.New("could not generate an intent token nonce")
	}
	exp := s.now().Add(intentTokenTTL)
	payload.Subject = id.Subject
	payload.TokenJTI = id.JTI
	payload.Nonce = hex.EncodeToString(nonce)
	payload.ExpiresAt = exp.Unix()

	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", time.Time{}, errors.New("could not encode the intent token")
	}
	segment := base64.RawURLEncoding.EncodeToString(encoded)
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte(segment))
	return segment + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), exp, nil
}

// errIntentTokenInvalid is the uniform rejection for tokens that fail
// signature, format, or binding checks. The message tells the agent how to
// recover without leaking which check failed.
var errIntentTokenInvalid = errors.New("the intent token is invalid for this caller; call the matching prepare tool to obtain a fresh one")

// verify checks a token's format, signature, kind, expiry, and binding to the
// presenting caller (subject and access-token jti). It does NOT consume the
// nonce; callers consume separately, immediately before performing the write.
func (s *intentSigner) verify(token string, kind string, id *identity) (*intentPayload, error) {
	segments := splitTwo(token)
	if segments == nil {
		return nil, errIntentTokenInvalid
	}
	signature, err := base64.RawURLEncoding.DecodeString(segments[1])
	if err != nil {
		return nil, errIntentTokenInvalid
	}
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte(segments[0]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return nil, errIntentTokenInvalid
	}
	decoded, err := base64.RawURLEncoding.DecodeString(segments[0])
	if err != nil {
		return nil, errIntentTokenInvalid
	}
	var payload intentPayload
	if err := json.Unmarshal(decoded, &payload); err != nil {
		return nil, errIntentTokenInvalid
	}
	if payload.Kind != kind {
		return nil, errIntentTokenInvalid
	}
	if payload.ExpiresAt <= s.now().Unix() {
		return nil, errors.New("the intent token expired; call the matching prepare tool again to obtain a fresh one")
	}
	if payload.Subject != id.Subject || payload.TokenJTI != id.JTI {
		// Bound to another user or another access token (e.g. a token that
		// leaked out of a different session).
		return nil, errIntentTokenInvalid
	}
	if payload.Nonce == "" {
		return nil, errIntentTokenInvalid
	}
	return &payload, nil
}

// consume burns the token's nonce. It must be called exactly once, after all
// other checks pass and immediately before the PostgREST write, so a replayed
// token gets a clean already-used error instead of a duplicate write.
func (s *intentSigner) consume(payload *intentPayload) error {
	if !s.nonces.consume(payload.Nonce, time.Unix(payload.ExpiresAt, 0)) {
		return errors.New("this intent token was already used; prepare the change again to obtain a fresh one")
	}
	return nil
}

// splitTwo splits a two-segment token, returning nil unless there is exactly
// one dot separating two non-empty segments.
func splitTwo(token string) []string {
	for i := 0; i < len(token); i++ {
		if token[i] == '.' {
			left, right := token[:i], token[i+1:]
			if left == "" || right == "" {
				return nil
			}
			for j := 0; j < len(right); j++ {
				if right[j] == '.' {
					return nil
				}
			}
			return []string{left, right}
		}
	}
	return nil
}

// sha256Hex returns the lowercase hex SHA-256 of s.
func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
