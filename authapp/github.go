package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The GitHub client behind self-serve assignment repositories (ADR 0006,
// issue #393). Every call authapp makes to GitHub goes through here, so there
// is one place that sets the API version, bounds the wait, classifies the
// failure, and keeps the credential out of everything a caller might log or
// return. The base URL is configurable so tests run against httptest servers;
// nothing in this package ever contacts api.github.com under `go test`.

const (
	githubDefaultBaseURL = "https://api.github.com"
	// githubAPIVersion pins the REST API date so a breaking change on
	// GitHub's side is opted into by editing this line, not discovered in
	// production.
	githubAPIVersion = "2022-11-28"
	// githubRequestTimeout bounds one HTTP exchange, including the wait
	// for headers and the body read. Template generation is the slowest
	// call here and normally answers well within this.
	githubRequestTimeout = 15 * time.Second
	// githubMaxResponseBody caps what is read of a reply. A repository
	// object is a few kilobytes; anything past this is not a reply this
	// client knows how to use.
	githubMaxResponseBody = 1 << 20
	// githubTokenRefreshMargin is how long before an installation token's
	// expiry the cache stops trusting it. GitHub tokens last an hour; five
	// minutes covers clock skew between the two sides and a slow request
	// that starts just before expiry.
	githubTokenRefreshMargin = 5 * time.Minute
	// githubAppJWTLifetime is the validity of the App JWT used to mint an
	// installation token. GitHub allows at most ten minutes; this is short
	// because the JWT is used once, immediately.
	githubAppJWTLifetime = 5 * time.Minute
	// githubAppJWTBackdate is subtracted from the JWT's issued-at, which
	// GitHub recommends so a clock a little ahead of theirs does not make
	// the JWT "issued in the future".
	githubAppJWTBackdate = 60 * time.Second
)

// githubTokenSource yields the bearer token for the next request. The two
// implementations are a static token (development, tests, and small
// deployments that accept a long-lived credential) and a GitHub App
// installation, which mints short-lived tokens and caches them in memory.
type githubTokenSource interface {
	Token(ctx context.Context) (string, error)
}

// githubStaticTokenSource returns the same token forever.
type githubStaticTokenSource struct {
	token string
}

func (s githubStaticTokenSource) Token(context.Context) (string, error) {
	return s.token, nil
}

// githubAppTokenSource mints installation access tokens from a GitHub App's
// private key: a JWT signed with the key proves we are the App, and
// POST /app/installations/{id}/access_tokens exchanges it for a token scoped
// to one installation that lasts an hour. The token is cached until shortly
// before it expires.
type githubAppTokenSource struct {
	baseURL        string
	appID          string
	installationID string
	privateKey     *rsa.PrivateKey
	httpClient     *http.Client
	now            func() time.Time

	// mu guards the cache and the in-flight refresh. It is never held
	// across the network call: a caller who finds the cache stale either
	// starts one refresh or waits on the one already running, and every
	// waiter sees that refresh's result, success or failure, so a burst of
	// callers costs one mint and a failing GitHub is asked once, not once
	// per caller.
	mu        sync.Mutex
	token     string
	expiresAt time.Time
	inflight  *githubMint
}

// githubMint is one refresh in progress. done is closed when it finishes
// and the fields are read only after that.
type githubMint struct {
	done      chan struct{}
	token     string
	expiresAt time.Time
	err       error
}

func newGitHubAppTokenSource(baseURL, appID, installationID string, privateKey *rsa.PrivateKey) *githubAppTokenSource {
	return &githubAppTokenSource{
		baseURL:        strings.TrimRight(baseURL, "/"),
		appID:          appID,
		installationID: installationID,
		privateKey:     privateKey,
		httpClient:     newGitHubHTTPClient(),
		now:            time.Now,
	}
}

func (s *githubAppTokenSource) Token(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", classifyGitHubTransportError("mint installation token", err)
	}
	s.mu.Lock()
	if s.token != "" && s.now().Add(githubTokenRefreshMargin).Before(s.expiresAt) {
		token := s.token
		s.mu.Unlock()
		return token, nil
	}
	mint := s.inflight
	if mint == nil {
		mint = &githubMint{done: make(chan struct{})}
		s.inflight = mint
		go s.refresh(mint)
	}
	s.mu.Unlock()

	select {
	case <-mint.done:
		return mint.token, mint.err
	case <-ctx.Done():
		// The refresh carries on for the callers still waiting on it; this
		// caller just stops waiting.
		return "", classifyGitHubTransportError("mint installation token", ctx.Err())
	}
}

// refresh runs one mint and publishes its result to every waiter. It is
// detached from any caller's context on purpose: the first caller giving up
// must not abort the refresh a dozen others are waiting on. The HTTP
// client's timeout bounds it instead.
func (s *githubAppTokenSource) refresh(mint *githubMint) {
	token, expiresAt, err := s.mint(context.Background())
	s.mu.Lock()
	if err == nil {
		s.token, s.expiresAt = token, expiresAt
	}
	s.inflight = nil
	s.mu.Unlock()
	mint.token, mint.expiresAt, mint.err = token, expiresAt, err
	close(mint.done)
}

// mint performs one installation-token exchange.
func (s *githubAppTokenSource) mint(ctx context.Context) (string, time.Time, error) {
	appJWT, err := signGitHubAppJWT(s.privateKey, s.appID, s.now())
	if err != nil {
		return "", time.Time{}, err
	}
	endpoint := s.baseURL + "/app/installations/" + url.PathEscape(s.installationID) + "/access_tokens"
	ctx, cancel := context.WithTimeout(ctx, githubRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, nil)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("github app token request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+appJWT)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", githubAPIVersion)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", time.Time{}, classifyGitHubTransportError("mint installation token", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, githubMaxResponseBody))
	if err != nil {
		return "", time.Time{}, classifyGitHubTransportError("mint installation token", err)
	}
	if resp.StatusCode != http.StatusCreated {
		return "", time.Time{}, classifyGitHubResponse("mint installation token", resp, body, s.now())
	}
	var minted struct {
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.Unmarshal(body, &minted); err != nil || minted.Token == "" || minted.ExpiresAt.IsZero() {
		return "", time.Time{}, &githubError{Kind: githubErrServer, Operation: "mint installation token", Status: resp.StatusCode, RequestID: resp.Header.Get("X-GitHub-Request-Id")}
	}
	return minted.Token, minted.ExpiresAt, nil
}

// signGitHubAppJWT builds the RS256 JWT GitHub requires from an App. The
// standard library is enough: the header and claims are fixed, and the
// signature is PKCS#1 v1.5 over SHA-256, which is what RS256 means.
func signGitHubAppJWT(key *rsa.PrivateKey, appID string, now time.Time) (string, error) {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, err := json.Marshal(map[string]any{
		"iat": now.Add(-githubAppJWTBackdate).Unix(),
		"exp": now.Add(githubAppJWTLifetime).Unix(),
		"iss": appID,
	})
	if err != nil {
		return "", err
	}
	signingInput := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("signing github app jwt: %w", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

// parseGitHubAppPrivateKey reads the PEM GitHub hands out when a private key
// is generated for an App. GitHub issues PKCS#1 ("RSA PRIVATE KEY"); PKCS#8
// is accepted too because that is what a key converted with openssl looks
// like.
func parseGitHubAppPrivateKey(pemBytes []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("no PEM block found")
	}
	switch block.Type {
	case "RSA PRIVATE KEY":
		return x509.ParsePKCS1PrivateKey(block.Bytes)
	case "PRIVATE KEY":
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return nil, err
		}
		key, ok := parsed.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("PKCS#8 key is not RSA")
		}
		return key, nil
	default:
		return nil, fmt.Errorf("unsupported PEM block type %q", block.Type)
	}
}

// githubErrorKind is the classification a caller acts on. The HTTP status
// and request id stay on the error for logs; the kind is what the handlers
// map to a response.
type githubErrorKind string

const (
	githubErrNotFound     githubErrorKind = "not_found"
	githubErrRateLimited  githubErrorKind = "rate_limited"
	githubErrUnauthorized githubErrorKind = "unauthorized"
	// githubErrConflict covers 409 and 422: the request was understood and
	// refused for a reason about state, such as a repository name already
	// taken or a template that is not a template.
	githubErrConflict githubErrorKind = "conflict"
	// githubErrServer is a 5xx, and also any status this client did not
	// expect for the call, including a redirect it refused to follow.
	githubErrServer  githubErrorKind = "server_error"
	githubErrTimeout githubErrorKind = "timeout"
	// githubErrCancelled is the caller's own context ending. It is not a
	// GitHub failure and a handler should not count it as one.
	githubErrCancelled githubErrorKind = "cancelled"
	// githubErrNetwork is a transport failure that is not a timeout: refused
	// connection, reset, DNS. For a POST it is as ambiguous as a timeout,
	// because the request may or may not have been delivered.
	githubErrNetwork githubErrorKind = "network"
)

// githubError is what every method returns on failure. It carries nothing
// GitHub said: the response body is untrusted text that, in the worst case,
// echoes a header back, so it is read for classification and dropped. What
// remains -- operation, kind, status, request id, wait -- is safe to log, to
// return to a client, and to marshal. The transport cause, when there is
// one, is reachable through errors.Is for context errors and never printed.
type githubError struct {
	Kind      githubErrorKind
	Operation string
	Status    int
	RequestID string
	// RetryAfter is set for rate limits when GitHub said how long to wait.
	RetryAfter time.Duration

	cause error
}

func (e *githubError) Unwrap() error { return e.cause }

func (e *githubError) Error() string {
	var b strings.Builder
	b.WriteString("github ")
	b.WriteString(e.Operation)
	b.WriteString(": ")
	b.WriteString(string(e.Kind))
	if e.Status != 0 {
		fmt.Fprintf(&b, " (status %d", e.Status)
		if e.RequestID != "" {
			fmt.Fprintf(&b, ", request %s", e.RequestID)
		}
		b.WriteString(")")
	}
	if e.RetryAfter > 0 {
		fmt.Fprintf(&b, " retry after %s", e.RetryAfter.Round(time.Second))
	}
	return b.String()
}

// githubErrorKindOf reports the classification of an error from this
// client, or "" for any other error.
func githubErrorKindOf(err error) githubErrorKind {
	var ghErr *githubError
	if errors.As(err, &ghErr) {
		return ghErr.Kind
	}
	return ""
}

// classifyGitHubTransportError classifies an error from before a response
// was fully read. The cause is kept so errors.Is(err, context.Canceled) and
// errors.Is(err, context.DeadlineExceeded) still hold for callers that
// distinguish their own deadline from GitHub's slowness.
func classifyGitHubTransportError(operation string, err error) *githubError {
	kind := githubErrNetwork
	var netErr net.Error
	switch {
	case errors.Is(err, context.Canceled):
		kind = githubErrCancelled
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &netErr) && netErr.Timeout():
		kind = githubErrTimeout
	}
	return &githubError{Kind: kind, Operation: operation, cause: err}
}

// classifyGitHubResponse turns a non-success reply into a githubError.
//
// GitHub signals a rate limit several ways and the accounting headers
// alone are not one of them: X-RateLimit-Reset rides on every response,
// limited or not. What counts is a 429; or a 403 with a Retry-After, with
// the remaining quota at zero, or whose body names a secondary rate limit
// (the one on content creation, which template generation can trip). Any
// other 403 is a permission problem.
func classifyGitHubResponse(operation string, resp *http.Response, body []byte, now time.Time) *githubError {
	ghErr := &githubError{
		Operation: operation,
		Status:    resp.StatusCode,
		RequestID: resp.Header.Get("X-GitHub-Request-Id"),
	}
	retryAfter, hasRetryAfter := githubRetryAfter(resp.Header, now)
	switch {
	case resp.StatusCode == http.StatusTooManyRequests,
		resp.StatusCode == http.StatusForbidden && (hasRetryAfter || resp.Header.Get("X-RateLimit-Remaining") == "0"):
		ghErr.Kind = githubErrRateLimited
		ghErr.RetryAfter = retryAfter
	case resp.StatusCode == http.StatusForbidden && githubMentionsSecondaryLimit(body):
		ghErr.Kind = githubErrRateLimited
		// GitHub's own guidance when it gives no Retry-After for a secondary
		// limit is to wait at least a minute.
		ghErr.RetryAfter = time.Minute
	case resp.StatusCode == http.StatusUnauthorized, resp.StatusCode == http.StatusForbidden:
		ghErr.Kind = githubErrUnauthorized
	case resp.StatusCode == http.StatusNotFound, resp.StatusCode == http.StatusGone:
		ghErr.Kind = githubErrNotFound
	case resp.StatusCode == http.StatusConflict, resp.StatusCode == http.StatusUnprocessableEntity:
		ghErr.Kind = githubErrConflict
	default:
		ghErr.Kind = githubErrServer
	}
	return ghErr
}

// githubRetryAfter derives a wait from Retry-After (seconds) or, failing
// that, X-RateLimit-Reset (a Unix timestamp). Only Retry-After counts as
// evidence of a limit, which is the boolean; the reset header is consulted
// for the length of the wait once something else has established that the
// response is a limit. A reset already in the past becomes a one-second
// wait rather than zero so a caller never spins.
func githubRetryAfter(h http.Header, now time.Time) (wait time.Duration, hasRetryAfter bool) {
	if seconds, err := strconv.Atoi(strings.TrimSpace(h.Get("Retry-After"))); err == nil && seconds >= 0 {
		return time.Duration(seconds) * time.Second, true
	}
	if reset, err := strconv.ParseInt(strings.TrimSpace(h.Get("X-RateLimit-Reset")), 10, 64); err == nil && reset > 0 {
		wait := time.Unix(reset, 0).Sub(now)
		if wait < time.Second {
			wait = time.Second
		}
		return wait, false
	}
	return 0, false
}

// githubMentionsSecondaryLimit reports whether a 403's body is GitHub's
// secondary-rate-limit refusal. The body is read for this one bit and
// otherwise discarded; nothing from it is kept.
func githubMentionsSecondaryLimit(body []byte) bool {
	var payload struct {
		Message          string `json:"message"`
		DocumentationURL string `json:"documentation_url"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return false
	}
	text := strings.ToLower(payload.Message + " " + payload.DocumentationURL)
	return strings.Contains(text, "secondary rate limit") || strings.Contains(text, "secondary-rate-limit")
}

// githubClient is the small surface the provisioning handlers use. The
// receiver methods are the whole vocabulary; a later issue that needs a new
// call adds a method here rather than reaching for http directly.
type githubClient struct {
	baseURL    string
	tokens     githubTokenSource
	httpClient *http.Client
	now        func() time.Time
}

func newGitHubClient(baseURL string, tokens githubTokenSource) *githubClient {
	return &githubClient{
		baseURL:    strings.TrimRight(baseURL, "/"),
		tokens:     tokens,
		httpClient: newGitHubHTTPClient(),
		now:        time.Now,
	}
}

// newGitHubHTTPClient refuses to follow redirects. The default client
// follows them, and on a 307 or 308 Go re-sends the body, which for a POST
// or PUT is exactly the replay this client promises never to make. The API
// does not redirect a well-formed request, so a redirect is reported as an
// unexpected status and the caller decides.
func newGitHubHTTPClient() *http.Client {
	return &http.Client{
		Timeout: githubRequestTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// githubUser is the slice of a user object provisioning cares about. The id
// is the identity; the login is what the student typed and can change.
type githubUser struct {
	ID    int64  `json:"id"`
	Login string `json:"login"`
}

// githubRepo is the slice of a repository object provisioning cares about.
// CreatedAt and TemplateFullName are what the ambiguous-generate recovery
// in issue #395 checks before adopting a repository it did not see created.
type githubRepo struct {
	ID               int64
	FullName         string
	HTMLURL          string
	DefaultBranch    string
	CreatedAt        time.Time
	TemplateFullName string
}

// githubRepoJSON is the wire shape; githubRepo is what callers get so the
// nested template object does not leak into the rest of the code.
type githubRepoJSON struct {
	ID            int64     `json:"id"`
	FullName      string    `json:"full_name"`
	HTMLURL       string    `json:"html_url"`
	DefaultBranch string    `json:"default_branch"`
	CreatedAt     time.Time `json:"created_at"`
	Template      *struct {
		FullName string `json:"full_name"`
	} `json:"template_repository"`
}

func (j githubRepoJSON) repo() githubRepo {
	r := githubRepo{ID: j.ID, FullName: j.FullName, HTMLURL: j.HTMLURL, DefaultBranch: j.DefaultBranch, CreatedAt: j.CreatedAt}
	if j.Template != nil {
		r.TemplateFullName = j.Template.FullName
	}
	return r
}

// githubMembershipState is a person's standing in an organization or team.
type githubMembershipState string

const (
	githubMembershipActive  githubMembershipState = "active"
	githubMembershipPending githubMembershipState = "pending"
	githubMembershipNone    githubMembershipState = "none"
)

// githubCollaboratorResult distinguishes a grant that took effect from one
// that only produced an invitation. GitHub answers 204 when the person can
// push right away (an organization member) and 201 when it created an
// invitation they still have to accept, and a caller must not report the
// second as done.
type githubCollaboratorResult string

const (
	githubCollaboratorGranted githubCollaboratorResult = "granted"
	githubCollaboratorInvited githubCollaboratorResult = "invited"
)

// GetUser resolves a login to an account. A renamed login answers 404 here,
// so a caller comparing against a stored numeric id sees the mismatch as
// "not found" rather than as somebody else's account.
func (c *githubClient) GetUser(ctx context.Context, login string) (githubUser, error) {
	var user githubUser
	_, err := c.do(ctx, "get user", http.MethodGet, "/users/"+url.PathEscape(login), nil, &user, http.StatusOK)
	return user, err
}

// GetOrgMembership reports whether the login is an active member, has a
// pending invitation, or is neither. GitHub answers 404 for a non-member;
// that is a state, not an error, so it is folded in.
func (c *githubClient) GetOrgMembership(ctx context.Context, org, login string) (githubMembershipState, error) {
	var membership struct {
		State string `json:"state"`
	}
	_, err := c.do(ctx, "get org membership", http.MethodGet,
		"/orgs/"+url.PathEscape(org)+"/memberships/"+url.PathEscape(login), nil, &membership, http.StatusOK)
	if githubErrorKindOf(err) == githubErrNotFound {
		return githubMembershipNone, nil
	}
	if err != nil {
		return "", err
	}
	return parseGitHubMembershipState(membership.State), nil
}

// GenerateFromTemplate creates a repository in org from a template
// repository. GitHub returns the repository object as soon as it exists,
// before the template's contents have been copied into it; use
// GetDefaultBranchHead to learn when they have. This is never retried by the
// client: a timeout leaves it unknown whether the repository was created, and
// the caller resolves that by looking the name up, not by posting again.
func (c *githubClient) GenerateFromTemplate(ctx context.Context, templateFullName, org, name string, private bool) (githubRepo, error) {
	templateOwner, templateRepo, ok := strings.Cut(templateFullName, "/")
	if !ok || templateOwner == "" || templateRepo == "" {
		return githubRepo{}, &githubError{Kind: githubErrConflict, Operation: "generate from template"}
	}
	body := map[string]any{
		"owner":   org,
		"name":    name,
		"private": private,
	}
	var created githubRepoJSON
	_, err := c.do(ctx, "generate from template", http.MethodPost,
		"/repos/"+url.PathEscape(templateOwner)+"/"+url.PathEscape(templateRepo)+"/generate", body, &created, http.StatusCreated)
	if err != nil {
		return githubRepo{}, err
	}
	if created.ID == 0 {
		return githubRepo{}, &githubError{Kind: githubErrServer, Operation: "generate from template", Status: http.StatusCreated}
	}
	return created.repo(), nil
}

// AddCollaborator grants the login the given permission ("push" for a
// student) on org/repo and reports whether it took effect or only produced
// an invitation. Repeating it for someone who already holds the permission
// is a 204, so it is safe to call again after an interrupted run.
func (c *githubClient) AddCollaborator(ctx context.Context, org, repo, login, permission string) (githubCollaboratorResult, error) {
	body := map[string]string{"permission": permission}
	status, err := c.do(ctx, "add collaborator", http.MethodPut,
		"/repos/"+url.PathEscape(org)+"/"+url.PathEscape(repo)+"/collaborators/"+url.PathEscape(login),
		body, nil, http.StatusNoContent, http.StatusCreated)
	if err != nil {
		return "", err
	}
	if status == http.StatusCreated {
		return githubCollaboratorInvited, nil
	}
	return githubCollaboratorGranted, nil
}

// GetRepo looks a repository up by name. A 404 is returned as a not-found
// error rather than folded into a value, because for the callers here a
// missing repository is the interesting case and they want the error's kind.
func (c *githubClient) GetRepo(ctx context.Context, org, name string) (githubRepo, error) {
	var found githubRepoJSON
	_, err := c.do(ctx, "get repo", http.MethodGet, "/repos/"+url.PathEscape(org)+"/"+url.PathEscape(name), nil, &found, http.StatusOK)
	if err != nil {
		return githubRepo{}, err
	}
	return found.repo(), nil
}

// GetDefaultBranchHead returns the commit at the tip of the default branch,
// which is the readiness signal for a generated repository: while GitHub is
// still copying the template's contents, the repository exists but has no
// commits, and this answers 409 ("Git Repository is empty"). That is
// ready=false with no error. A 404 is returned as a not_found error rather
// than folded in, because it is ambiguous -- GitHub answers 404 both for a
// repository that does not exist and for one this credential cannot see --
// and the caller knows how long ago it generated the repository, which is
// what decides whether 404 is "still appearing" or "gone".
func (c *githubClient) GetDefaultBranchHead(ctx context.Context, org, repo string) (sha string, ready bool, err error) {
	var commit struct {
		SHA string `json:"sha"`
	}
	_, err = c.do(ctx, "get default branch head", http.MethodGet,
		"/repos/"+url.PathEscape(org)+"/"+url.PathEscape(repo)+"/commits/HEAD", nil, &commit, http.StatusOK)
	if githubErrorKindOf(err) == githubErrConflict {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if commit.SHA == "" {
		return "", false, nil
	}
	return commit.SHA, true, nil
}

// SetOrgMembership invites the login to the organization as an ordinary
// member, using the course credential. For someone not yet a member GitHub
// creates a pending membership they must accept (issue #399 does that with
// the student's own token); for an existing member it answers with their
// current state and changes nothing.
func (c *githubClient) SetOrgMembership(ctx context.Context, org, login string) (githubMembershipState, error) {
	var membership struct {
		State string `json:"state"`
	}
	_, err := c.do(ctx, "set org membership", http.MethodPut,
		"/orgs/"+url.PathEscape(org)+"/memberships/"+url.PathEscape(login),
		map[string]string{"role": "member"}, &membership, http.StatusOK)
	if err != nil {
		return "", err
	}
	return parseGitHubMembershipState(membership.State), nil
}

// AddTeamMembership adds the login to a team as a member. An organization
// member is added immediately (state active); a non-member gets a pending
// team membership alongside an organization invitation.
func (c *githubClient) AddTeamMembership(ctx context.Context, org, teamSlug, login string) (githubMembershipState, error) {
	var membership struct {
		State string `json:"state"`
	}
	_, err := c.do(ctx, "add team membership", http.MethodPut,
		"/orgs/"+url.PathEscape(org)+"/teams/"+url.PathEscape(teamSlug)+"/memberships/"+url.PathEscape(login),
		map[string]string{"role": "member"}, &membership, http.StatusOK)
	if err != nil {
		return "", err
	}
	return parseGitHubMembershipState(membership.State), nil
}

// GetAuthenticatedUser resolves the account behind the client's own
// credential. It exists for the join flow (issue #399), where the client is
// built around a student's transient user token and this is how the
// platform learns which GitHub account authorized it; the id, not the
// login, is what gets linked.
func (c *githubClient) GetAuthenticatedUser(ctx context.Context) (githubUser, error) {
	var user githubUser
	_, err := c.do(ctx, "get authenticated user", http.MethodGet, "/user", nil, &user, http.StatusOK)
	return user, err
}

// AcceptOrgMembership accepts the caller's own pending invitation to org.
// This is the one call that must be made with the student's token rather
// than the course credential: only the invitee can accept, so the client
// this runs on is built around their token (issue #399). GitHub documents
// two successes: 200 with the membership as it now stands, and 202 with
// nothing, meaning the acceptance was queued. confirmed reports which; on
// a 202 the caller re-reads the membership rather than assuming.
func (c *githubClient) AcceptOrgMembership(ctx context.Context, org string) (state githubMembershipState, confirmed bool, err error) {
	var membership struct {
		State string `json:"state"`
	}
	status, err := c.do(ctx, "accept org membership", http.MethodPatch,
		"/user/memberships/orgs/"+url.PathEscape(org),
		map[string]string{"state": "active"}, &membership, http.StatusOK, http.StatusAccepted)
	if err != nil {
		return "", false, err
	}
	if status != http.StatusOK {
		return githubMembershipPending, false, nil
	}
	return parseGitHubMembershipState(membership.State), true, nil
}

func parseGitHubMembershipState(state string) githubMembershipState {
	switch state {
	case "active":
		return githubMembershipActive
	case "pending":
		return githubMembershipPending
	default:
		return githubMembershipNone
	}
}

// do performs one request and decodes a successful reply into out. A reply
// whose status is not one of okStatuses becomes a classified githubError.
// GET requests are replayed once on a 5xx because they are safe to repeat;
// nothing else is, because a POST or PUT that timed out may already have
// taken effect and repeating it is how one student ends up with two
// repositories.
func (c *githubClient) do(ctx context.Context, operation, method, path string, body any, out any, okStatuses ...int) (int, error) {
	var encoded []byte
	if body != nil {
		var err error
		encoded, err = json.Marshal(body)
		if err != nil {
			return 0, fmt.Errorf("github %s: encoding request: %w", operation, err)
		}
	}
	status, err := c.once(ctx, operation, method, path, encoded, out, okStatuses)
	if method == http.MethodGet && ctx.Err() == nil && isGitHub5xx(err) {
		status, err = c.once(ctx, operation, method, path, encoded, out, okStatuses)
	}
	return status, err
}

func isGitHub5xx(err error) bool {
	var ghErr *githubError
	return errors.As(err, &ghErr) && ghErr.Kind == githubErrServer && ghErr.Status >= 500
}

func (c *githubClient) once(ctx context.Context, operation, method, path string, encoded []byte, out any, okStatuses []int) (int, error) {
	token, err := c.tokens.Token(ctx)
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(ctx, githubRequestTimeout)
	defer cancel()
	var reader io.Reader
	if encoded != nil {
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, reader)
	if err != nil {
		return 0, fmt.Errorf("github %s: building request: %w", operation, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", githubAPIVersion)
	if encoded != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return 0, classifyGitHubTransportError(operation, err)
	}
	defer resp.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(resp.Body, githubMaxResponseBody))
	if err != nil {
		return resp.StatusCode, classifyGitHubTransportError(operation, err)
	}
	ok := false
	for _, s := range okStatuses {
		if resp.StatusCode == s {
			ok = true
			break
		}
	}
	if !ok {
		return resp.StatusCode, classifyGitHubResponse(operation, resp, responseBody, c.now())
	}
	if out != nil && len(responseBody) > 0 {
		if err := json.Unmarshal(responseBody, out); err != nil {
			return resp.StatusCode, &githubError{Kind: githubErrServer, Operation: operation, Status: resp.StatusCode, RequestID: resp.Header.Get("X-GitHub-Request-Id")}
		}
	}
	return resp.StatusCode, nil
}

// githubProvisioner is what the provisioning handlers (issues #395, #396)
// receive: the client plus the two organization facts every call needs. It
// is nil when provisioning is not configured, and the handlers are expected
// to answer "unavailable" rather than to dereference it.
type githubProvisioner struct {
	client           *githubClient
	org              string
	studentsTeamSlug string
	// join is the student-authorized join App (issue #399), nil when it is
	// not configured. It rides on the provisioner because it is meaningless
	// without one: joining the organization only matters on the way to a
	// repository, and the invitation and team add are made with the
	// provisioner's credential.
	join *githubJoinApp
}

// githubProvisionerFromEnv reads the provisioning configuration. It returns
// (nil, reason, nil) when provisioning is deliberately off, which is any
// configuration that is simply incomplete: no organization, or no credential.
// It returns an error for a configuration that is contradictory or half
// done, because someone who set two of the three App variables, or both a
// static token and an App, meant to enable provisioning and would otherwise
// find out only when a student clicked.
func githubProvisionerFromEnv(getenv func(string) string, readFile func(string) ([]byte, error)) (*githubProvisioner, string, error) {
	trimmed := func(name string) string { return strings.TrimSpace(getenv(name)) }
	org := trimmed("GITHUB_PROVISIONER_ORG")
	staticToken := trimmed("GITHUB_PROVISIONER_TOKEN")
	appID := trimmed("GITHUB_PROVISIONER_APP_ID")
	installationID := trimmed("GITHUB_PROVISIONER_INSTALLATION_ID")
	keyFile := trimmed("GITHUB_PROVISIONER_PRIVATE_KEY_FILE")

	appVarsSet := 0
	for _, v := range []string{appID, installationID, keyFile} {
		if v != "" {
			appVarsSet++
		}
	}
	if appVarsSet != 0 && appVarsSet != 3 {
		return nil, "", errors.New("GitHub App configuration is incomplete: set all of GITHUB_PROVISIONER_APP_ID, GITHUB_PROVISIONER_INSTALLATION_ID, and GITHUB_PROVISIONER_PRIVATE_KEY_FILE, or none of them")
	}
	if staticToken != "" && appVarsSet == 3 {
		return nil, "", errors.New("both GITHUB_PROVISIONER_TOKEN and the GitHub App variables are set; choose one credential")
	}
	hasCredential := staticToken != "" || appVarsSet == 3

	var missing []string
	if org == "" {
		missing = append(missing, "GITHUB_PROVISIONER_ORG")
	}
	if !hasCredential {
		missing = append(missing, "a credential (GITHUB_PROVISIONER_TOKEN, or GITHUB_PROVISIONER_APP_ID, GITHUB_PROVISIONER_INSTALLATION_ID, and GITHUB_PROVISIONER_PRIVATE_KEY_FILE)")
	}
	if len(missing) > 0 {
		return nil, "GitHub provisioning disabled: " + strings.Join(missing, " and ") + " not set", nil
	}

	baseURL := trimmed("GITHUB_PROVISIONER_API_BASE_URL")
	if baseURL == "" {
		baseURL = githubDefaultBaseURL
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return nil, "", fmt.Errorf("GITHUB_PROVISIONER_API_BASE_URL %q is not an http(s) URL", baseURL)
	}

	var tokens githubTokenSource
	if staticToken != "" {
		tokens = githubStaticTokenSource{token: staticToken}
	} else {
		pemBytes, err := readFile(keyFile)
		if err != nil {
			return nil, "", fmt.Errorf("reading GITHUB_PROVISIONER_PRIVATE_KEY_FILE: %w", err)
		}
		key, err := parseGitHubAppPrivateKey(pemBytes)
		if err != nil {
			return nil, "", fmt.Errorf("GITHUB_PROVISIONER_PRIVATE_KEY_FILE is not a usable RSA private key: %w", err)
		}
		tokens = newGitHubAppTokenSource(baseURL, appID, installationID, key)
	}
	return &githubProvisioner{
		client:           newGitHubClient(baseURL, tokens),
		org:              org,
		studentsTeamSlug: trimmed("GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG"),
	}, "", nil
}
