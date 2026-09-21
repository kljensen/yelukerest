package main

// Self-serve repositories: the routes behind the repositories page (ADR
// 0006; issues #395 and #396, decoupled from submissions on 2026-09-21).
//
//	GET  /auth/repositories                  the page (repositoriespage.go)
//	GET  /auth/repositories.js               its script
//	POST /auth/repositories/{template_slug}  create, or resume creating
//	GET  /auth/repositories/{template_slug}  ask how far it has got
//
// A student creates a repository from a template (api.repository_templates)
// on their own page; an assignment consumes the URL they paste. Authapp
// orchestrates and decides nothing about eligibility. Whether the template
// exists and is active, whether the caller is a student on a team when the
// template is a team one, whether the template's assignment has closed, and
// whether an attempt or a repository already exists are answered by the
// service RPCs in migration 01a0bb0d; this file calls them through
// PostgREST as the app role and does the GitHub side in between. The
// attempt row is the checkpoint: every GitHub call happens outside any
// database transaction, each stage is recorded after the call that
// completes it, and a request that finds an attempt part-way resumes from
// its stage. There is no worker; the next request is the only actor.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexedwards/scs/v2"
)

const (
	// repositoriesPagePath is the page, and the prefix of the per-template
	// routes. join.go sends a student back here by default.
	repositoriesPagePath = "/auth/repositories"
	// provisioningReadinessCacheWindow is how long a stored readiness answer
	// stands in for asking GitHub again. The page polls every three seconds,
	// so concurrent polls, and two tabs, share one check per interval.
	provisioningReadinessCacheWindow = 3 * time.Second
	// provisioningAppearanceGrace bounds how long after an attempt was
	// claimed a generated repository may answer 404 (not yet visible) or 409
	// (contents still copying) before that stops being "copying" and becomes
	// an error. Template copies take seconds; ten minutes is far past any
	// copy that is going to finish.
	provisioningAppearanceGrace = 10 * time.Minute
	// provisioningPostsPerMinute is the per-student admission limit on the
	// POST. One click plus a few retries; a loop is what it stops.
	provisioningPostsPerMinute = 6
	// provisioningDatabaseTimeout bounds one PostgREST call.
	provisioningDatabaseTimeout = 10 * time.Second
	// provisioningCreatedAtSkew is the allowance when deciding whether a
	// repository found under our name was created after our attempt.
	// GitHub reports created_at to the second and its clock is not ours, so
	// a repository generated within the same second as the claim would
	// otherwise be refused as somebody else's.
	provisioningCreatedAtSkew = 5 * time.Second

	provisioningStageClaimed   = "claimed"
	provisioningStageGenerated = "generated"
	provisioningStageGranted   = "granted"
	provisioningStageFinalized = "finalized"
	provisioningStageFailed    = "failed"

	repositoryStateReady           = "ready"
	repositoryStateCopying         = "copying"
	repositoryStateNeedsGitHubLink = "needs_github_link"
	repositoryStateNeedsOrgJoin    = "needs_org_join"
)

// templateSlugPattern is the shape of a repository template slug (the
// database bounds it at 60 characters). A slug is the one caller-supplied
// value the per-template routes take, and it reaches a PostgREST filter and
// a redirect, so anything else is answered as a template that does not
// exist before either.
var templateSlugPattern = regexp.MustCompile(`^[a-z0-9-]{1,60}$`)

// provisioningHandler serves the per-template routes and the page. One per
// process; the mutex map and the provider cooldown are what make two
// requests in one process cooperate, and the attempt row is what makes two
// processes cooperate.
type provisioningHandler struct {
	github   *githubProvisioner
	db       FetchJWTConfig
	sessions *scs.SessionManager
	limiter  *rateLimiter
	now      func() time.Time

	// owners holds one *sync.Mutex per owner (template plus student or
	// team) that has had a mutating request. Two POSTs for the same owner
	// at once get the same attempt from the claim RPC; the second waits
	// here for the first and then re-reads the attempt, so it continues
	// from wherever the first got to instead of repeating its GitHub
	// calls. This is in-process only, which is enough for one authapp
	// replica; a second replica would still converge through the attempt
	// row, at the cost of a possible duplicate GitHub call that the
	// name-lookup reconciles. Entries are never removed: there is one per
	// owner per template, which is bounded by the roster.
	owners sync.Map

	// cooldownUntil is the deployment-wide provider cooldown. When GitHub
	// says it is rate limited, every request until then is refused with
	// the same wait instead of each one asking GitHub and being told again.
	cooldownMu    sync.Mutex
	cooldownUntil time.Time

	// checks holds one *sync.Mutex and one readinessMemo per repository
	// full name. The attempt row's last_checked_at already answers polls
	// that arrive after a check was recorded; these answer the polls that
	// arrive while one is in flight, so concurrent polls in one process
	// cost one GitHub call per cache window rather than one each.
	checkLocks sync.Map
	checks     sync.Map
}

// readinessMemo is the in-process copy of the last readiness answer.
type readinessMemo struct {
	at    time.Time
	ready bool
}

func newProvisioningHandler(github *githubProvisioner, db FetchJWTConfig, sessions *scs.SessionManager) *provisioningHandler {
	return &provisioningHandler{
		github:   github,
		db:       db,
		sessions: sessions,
		limiter:  newRateLimiter(provisioningPostsPerMinute, time.Minute),
		now:      time.Now,
	}
}

// registerProvisioningRoutes adds the routes when provisioning is
// configured and nothing otherwise, so a deployment without it answers 404
// from the mux rather than a handler explaining itself.
func registerProvisioningRoutes(mux *http.ServeMux, github *githubProvisioner, db FetchJWTConfig, sessions *scs.SessionManager) {
	if github == nil {
		return
	}
	handler := newProvisioningHandler(github, db, sessions)
	handler.register(mux)
}

func (h *provisioningHandler) register(mux *http.ServeMux) {
	mux.HandleFunc("GET "+repositoriesPagePath, h.servePage)
	mux.HandleFunc("GET "+repositoriesScriptPath, serveRepositoriesScript)
	mux.Handle(repositoriesPagePath+"/{template_slug}", h)
}

// ServeHTTP is the per-template routes. The POST answers JSON to the page's
// script and any other fetch, and sends a plain form post back to the page
// with the outcome in the query, so the page works without the script.
func (h *provisioningHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w)
	slug := r.PathValue("template_slug")
	switch r.Method {
	case http.MethodPost:
		reply := h.create(r, slug)
		if wantsProvisioningJSON(r) {
			writeProvisioningReply(w, reply)
			return
		}
		if reply.code == "unauthenticated" {
			http.Redirect(w, r, githubJoinLoginPath+"?"+url.Values{"next": {repositoriesPagePath}}.Encode(), http.StatusSeeOther)
			return
		}
		result := reply.state
		if result == "" {
			result = reply.code
		}
		http.Redirect(w, r, repositoriesPagePath+"?"+url.Values{"template": {slug}, "result": {result}}.Encode(), http.StatusSeeOther)
	case http.MethodGet:
		writeProvisioningReply(w, h.status(r, slug))
	default:
		w.Header().Set("Allow", "GET, POST")
		writeProvisioningReply(w, errorReply(http.StatusMethodNotAllowed, "method_not_allowed", false))
	}
}

// wantsProvisioningJSON tells the page's fetch (and any other script) from
// a form submission. A fetch says so with Accept, and browsers mark one
// with Sec-Fetch-Mode cors or same-origin; a form navigation says navigate
// and accepts text/html.
func wantsProvisioningJSON(r *http.Request) bool {
	if strings.Contains(r.Header.Get("Accept"), "application/json") {
		return true
	}
	switch r.Header.Get("Sec-Fetch-Mode") {
	case "cors", "same-origin":
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// The response envelope
// ---------------------------------------------------------------------------

// provisioningReply is what every step hands back when it has something to
// say to the client: either a state (ready, copying, needs_github_link,
// needs_org_join) or a structured error. A nil reply means "carry on".
type provisioningReply struct {
	status     int
	state      string
	repoURL    string
	joinURL    string
	code       string
	retryable  bool
	retryAfter time.Duration
}

func stateReply(status int, state string, repoURL string) *provisioningReply {
	return &provisioningReply{status: status, state: state, repoURL: repoURL}
}

func errorReply(status int, code string, retryable bool) *provisioningReply {
	return &provisioningReply{status: status, code: code, retryable: retryable}
}

func retryLaterReply(code string, wait time.Duration) *provisioningReply {
	return &provisioningReply{status: http.StatusTooManyRequests, code: code, retryable: true, retryAfter: wait}
}

func writeProvisioningReply(w http.ResponseWriter, reply *provisioningReply) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if reply.retryAfter > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(reply.retryAfter.Seconds()))))
	}
	w.WriteHeader(reply.status)
	var body any
	if reply.state != "" {
		var repoURL, joinURL *string
		if reply.repoURL != "" {
			repoURL = &reply.repoURL
		}
		if reply.joinURL != "" {
			joinURL = &reply.joinURL
		}
		// join_url is set on needs_org_join when the student-authorized
		// join flow (issue #399, join.go) is configured and the blocker is
		// the caller's own membership; null on needs_org_join means the
		// student has to be invited by hand.
		body = map[string]any{
			"state":    reply.state,
			"repo_url": repoURL,
			"join_url": joinURL,
		}
	} else {
		body = map[string]any{
			"error": map[string]any{"code": reply.code, "retryable": reply.retryable},
		}
	}
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("provisioning: writing response: %v", err)
	}
}

// ---------------------------------------------------------------------------
// PostgREST
// ---------------------------------------------------------------------------

// postgrestError is a non-2xx answer from PostgREST. For a RAISE in an RPC
// the Message is the stable code the migration promised (repository_conflict,
// needs_github_link, ...), which is what callers switch on; nothing else in
// the body is kept.
type postgrestError struct {
	Status  int
	Message string
	Code    string
}

func (e *postgrestError) Error() string {
	return fmt.Sprintf("postgrest %d %s %s", e.Status, e.Code, e.Message)
}

// postgrestRaised reports the stable code when err is an RPC's own RAISE
// (SQLSTATE P0001), and "" for anything else, so a transport failure or a
// refused credential is never mistaken for a business refusal.
func postgrestRaised(err error) string {
	var pgErr *postgrestError
	if errors.As(err, &pgErr) && pgErr.Code == "P0001" {
		return pgErr.Message
	}
	return ""
}

// postgrestRPC calls one RPC as the authapp service. With out set the single
// row is requested and decoded; without, the reply is discarded.
func postgrestRPC(ctx context.Context, config FetchJWTConfig, name string, args any, out any) error {
	body, err := json.Marshal(args)
	if err != nil {
		return fmt.Errorf("encoding %s arguments: %w", name, err)
	}
	return postgrestDo(ctx, config.AuthappJWT, http.MethodPost, postgrestRPCURL(config, name), body, out)
}

// postgrestSelect reads rows from an api view as the given bearer. The
// provisioning GET reads as the student, with a JWT minted for them, so the
// views' row-level security is the ownership check.
func postgrestSelect(ctx context.Context, config FetchJWTConfig, bearer string, resource string, query url.Values, out any) error {
	endpoint := url.URL{
		Scheme:   "http",
		Host:     net.JoinHostPort(config.PostgrestHost, config.PostgrestPort),
		Path:     "/" + resource,
		RawQuery: query.Encode(),
	}
	return postgrestDo(ctx, bearer, http.MethodGet, endpoint.String(), nil, out)
}

func postgrestDo(ctx context.Context, bearer string, method string, endpoint string, body []byte, out any) error {
	ctx, cancel := context.WithTimeout(ctx, provisioningDatabaseTimeout)
	defer cancel()
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return fmt.Errorf("building postgrest request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if out != nil && method == http.MethodPost {
		req.Header.Set("Accept", "application/vnd.pgrst.object+json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("postgrest unavailable: %w", err)
	}
	defer resp.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("reading postgrest response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		pgErr := &postgrestError{Status: resp.StatusCode}
		var payload struct {
			Message string `json:"message"`
			Code    string `json:"code"`
		}
		if json.Unmarshal(responseBody, &payload) == nil {
			pgErr.Message, pgErr.Code = payload.Message, payload.Code
		}
		return pgErr
	}
	if out != nil && len(responseBody) > 0 {
		if err := json.Unmarshal(responseBody, out); err != nil {
			return fmt.Errorf("decoding postgrest response: %w", err)
		}
	}
	return nil
}

// provisioningUser is the slice of api.users the handlers need. The GitHub
// fields are readable by the app role, which is why the user is looked up
// here rather than through fetchUserInfo.
type provisioningUser struct {
	ID               int        `json:"id"`
	NetID            string     `json:"netid"`
	Role             string     `json:"role"`
	TeamNickname     string     `json:"team_nickname"`
	GitHubUserID     int64      `json:"github_user_id"`
	GitHubLogin      string     `json:"github_login"`
	GitHubVerifiedAt *time.Time `json:"github_verified_at"`
}

const provisioningUserColumns = "id,netid,role,team_nickname,github_user_id,github_login,github_verified_at"

// provisioningAttempt is a row of api.claim_repository_provisioning's result,
// which is also the shape of api.repository_provisionings plus
// existing_repository_id. Nullable columns decode to their zero value.
type provisioningAttempt struct {
	ID                   int        `json:"id"`
	TemplateSlug         string     `json:"template_slug"`
	IsTeam               bool       `json:"is_team"`
	UserID               int        `json:"user_id"`
	TeamNickname         string     `json:"team_nickname"`
	InitiatedByUserID    int        `json:"initiated_by_user_id"`
	Provider             string     `json:"provider"`
	TemplateFullName     string     `json:"template_full_name"`
	DestinationName      string     `json:"destination_name"`
	ProviderRepoID       int64      `json:"provider_repo_id"`
	ProviderFullName     string     `json:"provider_full_name"`
	Stage                string     `json:"stage"`
	ErrorCode            string     `json:"error_code"`
	LastCheckedAt        *time.Time `json:"last_checked_at"`
	ReadyAt              *time.Time `json:"ready_at"`
	CreatedAt            time.Time  `json:"created_at"`
	UpdatedAt            time.Time  `json:"updated_at"`
	ExistingRepositoryID int        `json:"existing_repository_id"`
}

// provisioningRepository is a row of api.my_repositories: the caller's own
// (or their team's) repositories joined with their template. The status
// route reads one; the page lists them all.
type provisioningRepository struct {
	ID               int       `json:"id"`
	TemplateSlug     string    `json:"template_slug"`
	IsTeam           bool      `json:"is_team"`
	TeamNickname     string    `json:"team_nickname"`
	ProviderFullName string    `json:"provider_full_name"`
	RepoURL          string    `json:"repo_url"`
	Label            string    `json:"label"`
	AssignmentSlug   string    `json:"assignment_slug"`
	CreatedAt        time.Time `json:"created_at"`
}

// provisioningTemplate is a row of api.repository_templates as the page
// and the status route read it.
type provisioningTemplate struct {
	Slug             string `json:"slug"`
	Provider         string `json:"provider"`
	TemplateFullName string `json:"template_full_name"`
	Label            string `json:"label"`
	Description      string `json:"description"`
	IsTeam           bool   `json:"is_team"`
	AssignmentSlug   string `json:"assignment_slug"`
	IsActive         bool   `json:"is_active"`
}

// platformReply is the answer when PostgREST itself, rather than a rule in
// it, failed: the caller can try again.
func platformReply(operation string, err error) *provisioningReply {
	log.Printf("provisioning: %s: %v", operation, err)
	return errorReply(http.StatusBadGateway, "platform_unavailable", true)
}

func (h *provisioningHandler) lookupUser(ctx context.Context, netID string) (provisioningUser, *provisioningReply) {
	user, found, err := selectUserByNetID(ctx, h.db, netID)
	if err != nil {
		return provisioningUser{}, platformReply("looking up the user", err)
	}
	if !found {
		return provisioningUser{}, errorReply(http.StatusForbidden, "not_enrolled", false)
	}
	return user, nil
}

func (h *provisioningHandler) teamMembers(ctx context.Context, teamNickname string) ([]provisioningUser, *provisioningReply) {
	query := url.Values{}
	query.Set("team_nickname", "eq."+teamNickname)
	query.Set("select", provisioningUserColumns)
	query.Set("order", "id")
	var users []provisioningUser
	if err := postgrestSelect(ctx, h.db, h.db.AuthappJWT, "users", query, &users); err != nil {
		return nil, platformReply("reading the team", err)
	}
	return users, nil
}

// claim asks the database for the attempt to work on and maps each of the
// RPC's refusals to its status.
func (h *provisioningHandler) claim(ctx context.Context, slug string, userID int) (provisioningAttempt, *provisioningReply) {
	var attempt provisioningAttempt
	err := postgrestRPC(ctx, h.db, "claim_repository_provisioning", map[string]any{
		"p_template_slug": slug,
		"p_user_id":       userID,
	}, &attempt)
	if err == nil {
		return attempt, nil
	}
	switch code := postgrestRaised(err); code {
	case "template_not_found", "template_inactive":
		return attempt, errorReply(http.StatusNotFound, code, false)
	case "not_a_student", "no_team", "assignment_closed":
		return attempt, errorReply(http.StatusForbidden, code, false)
	case "needs_github_link":
		return attempt, h.selfServiceReply(repositoryStateNeedsGitHubLink)
	case "destination_name_too_long":
		return attempt, errorReply(http.StatusConflict, code, false)
	case "":
		return attempt, platformReply("claiming the attempt", err)
	default:
		return attempt, errorReply(http.StatusConflict, code, false)
	}
}

// record advances the attempt's stage. The repository identity travels with
// the claimed-to-generated transition only, as the RPC requires.
func (h *provisioningHandler) record(ctx context.Context, attempt *provisioningAttempt, stage string, repo githubRepo, errorCode string) *provisioningReply {
	args := map[string]any{"p_attempt_id": attempt.ID, "p_stage": stage}
	if stage == provisioningStageGenerated {
		args["p_provider_repo_id"] = repo.ID
		args["p_provider_full_name"] = repo.FullName
	}
	if stage == provisioningStageFailed {
		args["p_error_code"] = errorCode
	}
	var updated provisioningAttempt
	if err := postgrestRPC(ctx, h.db, "record_repository_provisioning", args, &updated); err != nil {
		return platformReply("recording stage "+stage, err)
	}
	*attempt = updated
	return nil
}

// fail records the failure on the attempt so the status route can show it,
// then answers with the reply. The next POST resumes the attempt from
// claimed, which is what "retry" means for every code recorded here.
func (h *provisioningHandler) fail(ctx context.Context, attempt *provisioningAttempt, reply *provisioningReply) *provisioningReply {
	if recordErr := h.record(ctx, attempt, provisioningStageFailed, githubRepo{}, reply.code); recordErr != nil {
		return recordErr
	}
	return reply
}

// ---------------------------------------------------------------------------
// GitHub failures, as the client sees them
// ---------------------------------------------------------------------------

// githubReply maps a client error to the response for it. Not-found and
// conflict are not mapped here because they mean different things at
// different steps; each step handles them before calling this.
func (h *provisioningHandler) githubReply(err error) *provisioningReply {
	var ghErr *githubError
	if !errors.As(err, &ghErr) {
		log.Printf("provisioning: unexpected error from the GitHub client: %v", err)
		return errorReply(http.StatusBadGateway, "github_unavailable", true)
	}
	switch ghErr.Kind {
	case githubErrRateLimited:
		wait := ghErr.RetryAfter
		if wait <= 0 {
			wait = time.Minute
		}
		h.setCooldown(h.now().Add(wait))
		log.Printf("provisioning: %v; refusing GitHub calls for %s", ghErr, wait.Round(time.Second))
		return retryLaterReply("github_rate_limited", wait)
	case githubErrUnauthorized:
		// The installation was removed, the key deleted, or a permission
		// dropped. Nobody but an operator can fix it, so it is not retryable
		// and it is the one thing here logged as an error.
		log.Printf("provisioning: ERROR GitHub refused the course credential: %v", ghErr)
		return errorReply(http.StatusBadGateway, "github_credential_rejected", false)
	default:
		log.Printf("provisioning: %v", ghErr)
		return errorReply(http.StatusBadGateway, "github_unavailable", true)
	}
}

func (h *provisioningHandler) setCooldown(until time.Time) {
	h.cooldownMu.Lock()
	defer h.cooldownMu.Unlock()
	if until.After(h.cooldownUntil) {
		h.cooldownUntil = until
	}
}

// cooldownReply is the refusal while the provider cooldown is in force, or
// nil when GitHub may be called.
func (h *provisioningHandler) cooldownReply() *provisioningReply {
	h.cooldownMu.Lock()
	until := h.cooldownUntil
	h.cooldownMu.Unlock()
	if wait := until.Sub(h.now()); wait > 0 {
		return retryLaterReply("github_rate_limited", wait)
	}
	return nil
}

// ---------------------------------------------------------------------------
// POST: create or resume
// ---------------------------------------------------------------------------

// isSameOriginRequest is the cross-site check for the POST. The session
// cookie is SameSite=Lax, which already keeps it off a cross-site POST in a
// current browser; this refuses the request outright rather than letting it
// arrive without a session and be told 401. Sec-Fetch-Site is what browsers
// say now; the Origin header is the fallback and must equal the request's
// own origin -- the scheme Caddy forwarded (getRequestScheme, as the CAS
// return URL uses) plus the host -- so an http origin cannot pass for the
// https site. A request that says neither is refused, because a browser
// always sends at least one on a POST and anything else is not the
// repositories page.
func isSameOriginRequest(r *http.Request) bool {
	switch r.Header.Get("Sec-Fetch-Site") {
	case "same-origin", "none":
		return true
	case "":
	default:
		return false
	}
	origin, err := url.Parse(r.Header.Get("Origin"))
	if err != nil || origin.Host == "" || origin.Path != "" {
		return false
	}
	return strings.EqualFold(origin.Scheme, getRequestScheme(r)) && strings.EqualFold(origin.Host, r.Host)
}

// create is the POST: create the caller's repository from the template, or
// resume creating it, and answer its state.
func (h *provisioningHandler) create(r *http.Request, slug string) *provisioningReply {
	netID := h.sessions.GetString(r.Context(), "netid")
	if netID == "" {
		return errorReply(http.StatusUnauthorized, "unauthenticated", false)
	}
	if !isSameOriginRequest(r) {
		return errorReply(http.StatusForbidden, "cross_site_request", false)
	}
	if !templateSlugPattern.MatchString(slug) {
		return errorReply(http.StatusNotFound, "template_not_found", false)
	}
	if !h.limiter.Allow("netid:"+netID, h.now()) {
		return retryLaterReply("too_many_requests", time.Minute)
	}
	// The body is ignored: the owner, template, and name all come from the
	// session and the database, never from the caller.
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 1<<16))

	ctx := r.Context()
	caller, reply := h.lookupUser(ctx, netID)
	if reply != nil {
		return reply
	}
	attempt, reply := h.claim(ctx, slug, caller.ID)
	if reply != nil {
		return reply
	}
	if attempt.Stage != provisioningStageFinalized {
		attempt, reply = h.advanceLocked(ctx, caller, slug, attempt)
		if reply != nil {
			return reply
		}
	}
	return h.readiness(ctx, readinessSubjectOf(attempt))
}

// advanceLocked runs the mutating stages under the owner's mutex. The
// attempt is claimed again once the lock is held: another request may have
// finished a stage, or all of them, while this one waited, and the claim
// RPC is the cheap, idempotent way to find out.
func (h *provisioningHandler) advanceLocked(ctx context.Context, caller provisioningUser, slug string, attempt provisioningAttempt) (provisioningAttempt, *provisioningReply) {
	key := attempt.TemplateSlug + "|"
	if attempt.IsTeam {
		key += "team:" + attempt.TeamNickname
	} else {
		key += "user:" + strconv.Itoa(attempt.UserID)
	}
	entry, _ := h.owners.LoadOrStore(key, &sync.Mutex{})
	mu := entry.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()

	attempt, reply := h.claim(ctx, slug, caller.ID)
	if reply != nil || attempt.Stage == provisioningStageFinalized {
		return attempt, reply
	}
	return h.advance(ctx, caller, attempt)
}

// advance takes the attempt from its current stage as far as finalized,
// stopping at the first thing that needs the student, staff, or a retry.
// Every unfinished attempt is validated in full first, whatever stage it
// resumes from: the roster, each owner's identity, and each owner's
// membership are re-read and re-checked before any GitHub mutation, because
// all of them can change between one click and the next. Grants are
// reconciled against the current roster at both the generated and the
// granted stage, which the idempotent collaborator PUT makes cheap, so a
// teammate who joined after generate gets push before finalize.
func (h *provisioningHandler) advance(ctx context.Context, caller provisioningUser, attempt provisioningAttempt) (provisioningAttempt, *provisioningReply) {
	owners, reply := h.ownersOf(ctx, caller, attempt)
	if reply != nil {
		return attempt, reply
	}
	if reply := h.validateOwners(ctx, caller, owners); reply != nil {
		return attempt, reply
	}
	if attempt.Stage == provisioningStageClaimed {
		if reply := h.checkTemplate(ctx, &attempt); reply != nil {
			return attempt, reply
		}
		if reply := h.acquireRepository(ctx, &attempt); reply != nil {
			return attempt, reply
		}
	}
	if attempt.Stage == provisioningStageGenerated || attempt.Stage == provisioningStageGranted {
		if reply := h.grant(ctx, caller, owners, &attempt); reply != nil {
			return attempt, reply
		}
	}
	if attempt.Stage == provisioningStageGranted {
		if reply := h.finalize(ctx, owners, &attempt); reply != nil {
			return attempt, reply
		}
	}
	return attempt, nil
}

// ownersOf lists who must end up with push: the caller alone for an
// individual template, the team's current roster for a team one, read
// fresh on every request so a roster change between stages is seen. The
// caller comes first so their own blocker is reported before a teammate's.
func (h *provisioningHandler) ownersOf(ctx context.Context, caller provisioningUser, attempt provisioningAttempt) ([]provisioningUser, *provisioningReply) {
	if !attempt.IsTeam {
		return []provisioningUser{caller}, nil
	}
	members, reply := h.teamMembers(ctx, attempt.TeamNickname)
	if reply != nil {
		return nil, reply
	}
	owners := []provisioningUser{caller}
	for _, member := range members {
		if member.ID != caller.ID {
			owners = append(owners, member)
		}
	}
	return owners, nil
}

// selfServiceReply is the answer when the caller's own GitHub identity or
// membership is what stands in the way. With the join flow configured
// (join.go) it names the landing page, which returns to the repositories
// page, and one authorization there settles both: the callback records the
// verified identity before it does anything about membership. Without it
// join_url is null and the student is on their own, as before.
func (h *provisioningHandler) selfServiceReply(state string) *provisioningReply {
	reply := stateReply(http.StatusOK, state, "")
	if h.github.join != nil {
		reply.joinURL = githubJoinURL(repositoriesPagePath)
	}
	return reply
}

// blockedReply is the answer when an owner cannot receive the repository
// yet. The caller is told what they themselves must do; a teammate's
// blocker is a conflict, because the caller cannot link or join on
// someone else's behalf and a "needs_org_join" would send them to fix the
// wrong account.
func (h *provisioningHandler) blockedReply(caller provisioningUser, owner provisioningUser, state string) *provisioningReply {
	if owner.ID == caller.ID {
		return h.selfServiceReply(state)
	}
	return errorReply(http.StatusConflict, "team_prerequisites_incomplete", true)
}

// validateOwners checks, for each owner, that the login on record resolves
// at GitHub to the account already linked (or, if none is linked yet, links
// it, unverified), and that the account is an active member of the
// organization. It creates nothing. The linked id is written back into the
// owner so finalize can name the account the grant went to. When the
// caller's own identity or membership is the blocker and the join flow is
// configured, the reply carries the join URL.
func (h *provisioningHandler) validateOwners(ctx context.Context, caller provisioningUser, owners []provisioningUser) *provisioningReply {
	for i := range owners {
		owner := &owners[i]
		if owner.GitHubLogin == "" {
			return h.blockedReply(caller, *owner, repositoryStateNeedsGitHubLink)
		}
		if reply := h.cooldownReply(); reply != nil {
			return reply
		}
		account, err := h.github.client.GetUser(ctx, owner.GitHubLogin)
		if githubErrorKindOf(err) == githubErrNotFound {
			// Renamed or deleted. The stored login no longer names an
			// account, and guessing which one it became is exactly the
			// silent rebinding this check exists to prevent.
			return h.blockedReply(caller, *owner, repositoryStateNeedsGitHubLink)
		}
		if err != nil {
			return h.githubReply(err)
		}
		if owner.GitHubUserID != 0 && owner.GitHubUserID != account.ID {
			return h.blockedReply(caller, *owner, repositoryStateNeedsGitHubLink)
		}
		if owner.GitHubUserID == 0 {
			err := postgrestRPC(ctx, h.db, "set_user_github_identity", map[string]any{
				"p_user_id":        owner.ID,
				"p_github_user_id": account.ID,
				"p_github_login":   account.Login,
				"p_verified":       false,
			}, nil)
			switch postgrestRaised(err) {
			case "":
				if err != nil {
					return platformReply("linking the GitHub account", err)
				}
			case "github_identity_taken", "github_identity_locked":
				return h.blockedReply(caller, *owner, repositoryStateNeedsGitHubLink)
			default:
				return platformReply("linking the GitHub account", err)
			}
			owner.GitHubUserID = account.ID
		}
		if reply := h.cooldownReply(); reply != nil {
			return reply
		}
		membership, err := h.github.client.GetOrgMembership(ctx, h.github.org, owner.GitHubLogin)
		if err != nil {
			return h.githubReply(err)
		}
		if membership != githubMembershipActive {
			return h.blockedReply(caller, *owner, repositoryStateNeedsOrgJoin)
		}
	}
	return nil
}

// checkTemplate refuses to generate from a template with no contents: the
// result would be empty forever and reported as copying until the grace
// ran out.
func (h *provisioningHandler) checkTemplate(ctx context.Context, attempt *provisioningAttempt) *provisioningReply {
	if reply := h.cooldownReply(); reply != nil {
		return reply
	}
	templateOwner, templateRepo, _ := strings.Cut(attempt.TemplateFullName, "/")
	_, ready, err := h.github.client.GetDefaultBranchHead(ctx, templateOwner, templateRepo)
	if githubErrorKindOf(err) == githubErrNotFound {
		return h.fail(ctx, attempt, errorReply(http.StatusBadGateway, "template_not_found", false))
	}
	if err != nil {
		return h.githubReply(err)
	}
	if !ready {
		return h.fail(ctx, attempt, errorReply(http.StatusBadGateway, "template_empty", false))
	}
	return nil
}

// acquireRepository gets the attempt a repository and records generated.
// The name is always looked up before anything is posted: a repository
// already there that was generated from our template after this attempt
// was claimed is ours -- an earlier click whose generate timed out after it
// landed -- and is adopted; one that is not ours is a conflict for staff;
// only a 404 leads to a generate. The generate itself is never repeated by
// this request: if it fails ambiguously the attempt is marked failed and
// the next click's lookup finds whatever landed.
func (h *provisioningHandler) acquireRepository(ctx context.Context, attempt *provisioningAttempt) *provisioningReply {
	if reply := h.cooldownReply(); reply != nil {
		return reply
	}
	found, err := h.github.client.GetRepo(ctx, h.github.org, attempt.DestinationName)
	switch githubErrorKindOf(err) {
	case "":
		notBefore := attempt.CreatedAt.Add(-provisioningCreatedAtSkew)
		if !strings.EqualFold(found.TemplateFullName, attempt.TemplateFullName) || found.CreatedAt.Before(notBefore) {
			log.Printf("provisioning: attempt %d: %s/%s exists and is not ours (template %q, created %s)",
				attempt.ID, h.github.org, attempt.DestinationName, found.TemplateFullName, found.CreatedAt.Format(time.RFC3339))
			return h.fail(ctx, attempt, errorReply(http.StatusConflict, "name_taken", false))
		}
		log.Printf("provisioning: attempt %d: adopted existing %s", attempt.ID, found.FullName)
		return h.record(ctx, attempt, provisioningStageGenerated, found, "")
	case githubErrNotFound:
	default:
		return h.githubReply(err)
	}

	if reply := h.cooldownReply(); reply != nil {
		return reply
	}
	repo, err := h.github.client.GenerateFromTemplate(ctx, attempt.TemplateFullName, h.github.org, attempt.DestinationName, true)
	switch githubErrorKindOf(err) {
	case "":
		return h.record(ctx, attempt, provisioningStageGenerated, repo, "")
	case githubErrTimeout, githubErrNetwork, githubErrServer:
		// Ambiguous: the repository may exist. Nothing more is done now;
		// the retry's lookup above decides.
		return h.fail(ctx, attempt, h.githubReply(err))
	case githubErrConflict:
		// The lookup just said the name was free, so this is GitHub
		// refusing the request itself, or a race with a repository that
		// appeared in between; the retry's lookup settles the second.
		return h.fail(ctx, attempt, errorReply(http.StatusBadGateway, "generate_rejected", true))
	case githubErrNotFound:
		// The template is not in the installation's repository list, or is
		// not marked as a template. docs/github-provisioning.md says so.
		return h.fail(ctx, attempt, errorReply(http.StatusBadGateway, "template_not_found", false))
	case githubErrUnauthorized:
		return h.fail(ctx, attempt, h.githubReply(err))
	default:
		return h.githubReply(err)
	}
}

// grant gives every current owner push. Repeating a grant for someone who
// already has it is a 204, so this runs on every resumed attempt and after
// a partial run alike. Granted is recorded once, on the way out of
// generated. A 201 means GitHub created an invitation instead, which
// cannot happen for an organization member; it is treated as a failure
// rather than as access, because it is not access.
func (h *provisioningHandler) grant(ctx context.Context, caller provisioningUser, owners []provisioningUser, attempt *provisioningAttempt) *provisioningReply {
	org, repoName, ok := strings.Cut(attempt.ProviderFullName, "/")
	if !ok {
		return h.fail(ctx, attempt, errorReply(http.StatusBadGateway, "repository_name_invalid", false))
	}
	for _, owner := range owners {
		if reply := h.cooldownReply(); reply != nil {
			return reply
		}
		result, err := h.github.client.AddCollaborator(ctx, org, repoName, owner.GitHubLogin, "push")
		switch githubErrorKindOf(err) {
		case "":
		case githubErrNotFound:
			return h.fail(ctx, attempt, errorReply(http.StatusBadGateway, "repository_not_visible", false))
		case githubErrUnauthorized:
			return h.fail(ctx, attempt, h.githubReply(err))
		default:
			return h.githubReply(err)
		}
		if result != githubCollaboratorGranted {
			return h.fail(ctx, attempt, errorReply(http.StatusConflict, "collaborator_not_member", false))
		}
	}
	if attempt.Stage == provisioningStageGranted {
		return nil
	}
	return h.record(ctx, attempt, provisioningStageGranted, githubRepo{}, "")
}

// finalize records the repository row and marks the attempt finalized, in
// one transaction. It writes no submission: the student pastes the URL into
// whatever assignment wants it. It is idempotent on the database side, so a
// lost response is answered by the next request calling it again.
func (h *provisioningHandler) finalize(ctx context.Context, owners []provisioningUser, attempt *provisioningAttempt) *provisioningReply {
	args := map[string]any{"p_attempt_id": attempt.ID}
	if !attempt.IsTeam && len(owners) > 0 && owners[0].GitHubUserID != 0 {
		args["p_provider_user_id"] = owners[0].GitHubUserID
	}
	err := postgrestRPC(ctx, h.db, "finalize_repository_provisioning", args, nil)
	switch code := postgrestRaised(err); code {
	case "":
		if err != nil {
			return platformReply("finalizing the attempt", err)
		}
	case "github_identity_mismatch":
		// The account the grant went to is not the one linked to the
		// student any more: the link has to be looked at again.
		if reply := h.fail(ctx, attempt, errorReply(http.StatusConflict, code, false)); reply.code != code {
			return reply
		}
		return h.selfServiceReply(repositoryStateNeedsGitHubLink)
	default:
		// repository_conflict and anything else the RPC raises: for staff,
		// and the code says which.
		return h.fail(ctx, attempt, errorReply(http.StatusConflict, code, false))
	}
	attempt.Stage = provisioningStageFinalized
	return nil
}

// ---------------------------------------------------------------------------
// Readiness
// ---------------------------------------------------------------------------

// readinessSubject is what the readiness check needs to know about a
// repository: where it is, when the attempt for it began, and what was last
// recorded. attemptID is 0 for a repository the old tooling recorded with no
// attempt, in which case there is nowhere to store the answer and GitHub is
// asked each time.
type readinessSubject struct {
	attemptID     int
	fullName      string
	createdAt     time.Time
	lastCheckedAt *time.Time
	readyAt       *time.Time
}

func readinessSubjectOf(attempt provisioningAttempt) readinessSubject {
	return readinessSubject{
		attemptID:     attempt.ID,
		fullName:      attempt.ProviderFullName,
		createdAt:     attempt.CreatedAt,
		lastCheckedAt: attempt.LastCheckedAt,
		readyAt:       attempt.ReadyAt,
	}
}

// readiness answers ready or copying for a finalized repository. Ready means
// the default branch has a commit, which is when GitHub has finished copying
// the template; it is remembered once seen. A check within the cache window
// of the last one is answered from the row. Absence is tolerated for the
// grace period after the attempt began and is an error after it.
func (h *provisioningHandler) readiness(ctx context.Context, subject readinessSubject) *provisioningReply {
	repoURL := "https://github.com/" + subject.fullName
	now := h.now()
	if subject.readyAt != nil {
		return stateReply(http.StatusOK, repositoryStateReady, repoURL)
	}
	if subject.lastCheckedAt != nil && now.Sub(*subject.lastCheckedAt) < provisioningReadinessCacheWindow {
		return stateReply(http.StatusAccepted, repositoryStateCopying, repoURL)
	}

	entry, _ := h.checkLocks.LoadOrStore(subject.fullName, &sync.Mutex{})
	mu := entry.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()

	withinGrace := now.Sub(subject.createdAt) < provisioningAppearanceGrace
	var ready bool
	if memo, ok := h.checks.Load(subject.fullName); ok && now.Sub(memo.(readinessMemo).at) < provisioningReadinessCacheWindow {
		ready = memo.(readinessMemo).ready
	} else {
		if reply := h.cooldownReply(); reply != nil {
			return reply
		}
		org, repoName, _ := strings.Cut(subject.fullName, "/")
		var err error
		_, ready, err = h.github.client.GetDefaultBranchHead(ctx, org, repoName)
		switch githubErrorKindOf(err) {
		case "":
		case githubErrNotFound:
			if !withinGrace {
				log.Printf("provisioning: %s still not visible %s after its attempt began", subject.fullName, provisioningAppearanceGrace)
				return errorReply(http.StatusBadGateway, "repository_not_visible", false)
			}
			ready = false
		default:
			return h.githubReply(err)
		}
		h.checks.Store(subject.fullName, readinessMemo{at: now, ready: ready})
		h.touch(ctx, subject.attemptID, ready)
	}
	if ready {
		return stateReply(http.StatusOK, repositoryStateReady, repoURL)
	}
	if !withinGrace {
		log.Printf("provisioning: %s still has no commits %s after its attempt began", subject.fullName, provisioningAppearanceGrace)
		return errorReply(http.StatusBadGateway, "template_copy_timed_out", false)
	}
	return stateReply(http.StatusAccepted, repositoryStateCopying, repoURL)
}

// touch records the check. A failure here costs one extra GitHub call on
// the next poll and nothing else, so it is logged and not reported.
func (h *provisioningHandler) touch(ctx context.Context, attemptID int, ready bool) {
	if attemptID == 0 {
		return
	}
	err := postgrestRPC(ctx, h.db, "touch_repository_provisioning_readiness", map[string]any{
		"p_attempt_id": attemptID,
		"p_ready":      ready,
	}, nil)
	if err != nil {
		log.Printf("provisioning: recording readiness for attempt %d: %v", attemptID, err)
	}
}

// ---------------------------------------------------------------------------
// GET: status
// ---------------------------------------------------------------------------

// studentReads is what the status route and the page need to read as the
// student: the JWT minted for them, under which the views' row-level
// security answers whose attempt and repository they may see, exactly as
// it does for the client's other reads.
func (h *provisioningHandler) studentReads(netID string) (*UserJWTInfo, *provisioningReply) {
	info, err, status := fetchUserJWTInfo(netID, h.db)
	if err != nil {
		if status == http.StatusForbidden {
			return nil, errorReply(http.StatusForbidden, "not_enrolled", false)
		}
		return nil, platformReply("minting the student's JWT", err)
	}
	return info, nil
}

// readAttempts reads the caller's attempts, for one template or for all.
func (h *provisioningHandler) readAttempts(ctx context.Context, userJWT string, slug string) ([]provisioningAttempt, *provisioningReply) {
	query := url.Values{}
	if slug != "" {
		query.Set("template_slug", "eq."+slug)
	}
	var attempts []provisioningAttempt
	if err := postgrestSelect(ctx, h.db, userJWT, "repository_provisionings", query, &attempts); err != nil {
		return nil, platformReply("reading the attempts", err)
	}
	return attempts, nil
}

// readRepositories reads the caller's repositories, for one template or
// for all, newest first.
func (h *provisioningHandler) readRepositories(ctx context.Context, userJWT string, slug string) ([]provisioningRepository, *provisioningReply) {
	query := url.Values{}
	if slug != "" {
		query.Set("template_slug", "eq."+slug)
	}
	query.Set("order", "created_at.desc")
	var repositories []provisioningRepository
	if err := postgrestSelect(ctx, h.db, userJWT, "my_repositories", query, &repositories); err != nil {
		return nil, platformReply("reading the repositories", err)
	}
	return repositories, nil
}

// readTemplates reads the active templates, for one slug or for all. Every
// role may read the view; whether the caller may use a template is the
// page's and the claim RPC's question.
func (h *provisioningHandler) readTemplates(ctx context.Context, userJWT string, slug string) ([]provisioningTemplate, *provisioningReply) {
	query := url.Values{}
	if slug != "" {
		query.Set("slug", "eq."+slug)
	}
	query.Set("is_active", "eq.true")
	query.Set("order", "slug")
	var templates []provisioningTemplate
	if err := postgrestSelect(ctx, h.db, userJWT, "repository_templates", query, &templates); err != nil {
		return nil, platformReply("reading the templates", err)
	}
	return templates, nil
}

// status is the GET. It reads, and only reads, as the student. The one
// write is the readiness timestamp, which is the service's own
// bookkeeping.
func (h *provisioningHandler) status(r *http.Request, slug string) *provisioningReply {
	ctx := r.Context()
	netID := h.sessions.GetString(ctx, "netid")
	if netID == "" {
		return errorReply(http.StatusUnauthorized, "unauthenticated", false)
	}
	if !templateSlugPattern.MatchString(slug) {
		return errorReply(http.StatusNotFound, "template_not_found", false)
	}
	info, reply := h.studentReads(netID)
	if reply != nil {
		return reply
	}
	if info.Role != "student" {
		return errorReply(http.StatusForbidden, "not_a_student", false)
	}
	attempts, reply := h.readAttempts(ctx, info.JWT, slug)
	if reply != nil {
		return reply
	}
	repositories, reply := h.readRepositories(ctx, info.JWT, slug)
	if reply != nil {
		return reply
	}

	// A recorded repository is authoritative whatever the attempt says,
	// including when there is no attempt because the old tooling made it.
	if len(repositories) > 0 {
		subject := readinessSubject{fullName: repositories[0].ProviderFullName, createdAt: repositories[0].CreatedAt}
		if len(attempts) > 0 {
			subject.attemptID = attempts[0].ID
			subject.lastCheckedAt = attempts[0].LastCheckedAt
			subject.readyAt = attempts[0].ReadyAt
		}
		return h.readiness(ctx, subject)
	}
	if len(attempts) == 0 {
		return h.notStartedReply(ctx, info.JWT, slug)
	}
	return h.attemptStateReply(ctx, attempts[0])
}

// attemptStateReply answers for an attempt with no repository recorded yet.
func (h *provisioningHandler) attemptStateReply(ctx context.Context, attempt provisioningAttempt) *provisioningReply {
	switch attempt.Stage {
	case provisioningStageFinalized:
		return h.readiness(ctx, readinessSubjectOf(attempt))
	case provisioningStageFailed:
		code := attempt.ErrorCode
		if code == "" {
			code = "provisioning_failed"
		}
		return errorReply(http.StatusConflict, code, true)
	default:
		// claimed, generated, granted: a request was interrupted between
		// checkpoints. GET never resumes it; the client repeats the POST,
		// which does.
		return errorReply(http.StatusConflict, "provisioning_interrupted", true)
	}
}

// notStartedReply distinguishes "nothing has been asked for yet" from "there
// is nothing to ask for", so the page can show a button for one and nothing
// for the other.
func (h *provisioningHandler) notStartedReply(ctx context.Context, userJWT string, slug string) *provisioningReply {
	templates, reply := h.readTemplates(ctx, userJWT, slug)
	if reply != nil {
		return reply
	}
	if len(templates) == 0 {
		return errorReply(http.StatusNotFound, "template_not_found", false)
	}
	return errorReply(http.StatusNotFound, "repository_not_started", false)
}
