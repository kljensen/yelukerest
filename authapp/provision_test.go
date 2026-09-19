package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexedwards/scs/v2/memstore"
)

// The provisioning routes against two fakes: a PostgREST that implements the
// RPCs and views the handlers call over an in-memory store, and a GitHub
// whose answers each test scripts. Nothing here reaches a network.

const provisioningTestToken = "secret-github-token-do-not-leak"

// The fakeClock from github_test.go is shared by the handler and the fake
// PostgREST so "within three seconds of last_checked_at" means the same
// thing on both sides.

// ---------------------------------------------------------------------------
// Fake PostgREST
// ---------------------------------------------------------------------------

type fakeAssignment struct {
	isTeam   bool
	template string
	draft    bool
	closed   bool
}

type fakeRepositoryRow struct {
	ID               int       `json:"id"`
	AssignmentSlug   string    `json:"assignment_slug"`
	IsTeam           bool      `json:"is_team"`
	UserID           int       `json:"user_id"`
	TeamNickname     string    `json:"team_nickname"`
	Provider         string    `json:"provider"`
	ProviderRepoID   int64     `json:"provider_repo_id"`
	ProviderFullName string    `json:"provider_full_name"`
	ProviderUserID   *int64    `json:"provider_user_id"`
	CreatedAt        time.Time `json:"created_at"`
	UpdatedAt        time.Time `json:"updated_at"`
}

type fakePostgREST struct {
	t      *testing.T
	clock  *fakeClock
	server *httptest.Server
	config FetchJWTConfig

	mu           sync.Mutex
	users        map[int]*provisioningUser
	assignments  map[string]fakeAssignment
	attempts     map[int]*provisioningAttempt
	repositories []*fakeRepositoryRow
	// submissions is the URL field's body per owner ("slug|user|team"),
	// which finalize writes and refuses to overwrite.
	submissions map[string]string
	// verified records p_verified from the last set_user_github_identity
	// per user, standing in for github_verified_at.
	verified      map[int]bool
	nextAttemptID int
	nextRepoID    int
	finalizeCalls int
	rpcCalls      map[string]int
	// finalizeRaise, when set, is raised by the next finalize instead of
	// running it: for the refusals the handler cannot provoke through the
	// store because it always sends the row's own values.
	finalizeRaise string
}

func newFakePostgREST(t *testing.T, clock *fakeClock) *fakePostgREST {
	t.Helper()
	f := &fakePostgREST{
		t:             t,
		clock:         clock,
		users:         map[int]*provisioningUser{},
		assignments:   map[string]fakeAssignment{},
		attempts:      map[int]*provisioningAttempt{},
		submissions:   map[string]string{},
		verified:      map[int]bool{},
		nextAttemptID: 1,
		nextRepoID:    1,
		rpcCalls:      map[string]int{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /rpc/{name}", f.serveRPC)
	mux.HandleFunc("GET /{view}", f.serveView)
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	serverURL, _ := url.Parse(f.server.URL)
	host, port, _ := net.SplitHostPort(serverURL.Host)
	f.config = FetchJWTConfig{PostgrestHost: host, PostgrestPort: port, AuthappJWT: "service-token"}
	return f
}

func (f *fakePostgREST) raise(w http.ResponseWriter, code string) {
	writeJSON(w, http.StatusBadRequest, map[string]any{"code": "P0001", "message": code, "details": "raised by the fake"})
}

// userForBearer maps a bearer to the caller: the service, or a student whose
// JWT fetchUserJWTInfo minted here.
func (f *fakePostgREST) userForBearer(r *http.Request) (service bool, user *provisioningUser) {
	bearer := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if bearer == f.config.AuthappJWT {
		return true, nil
	}
	if netID, ok := strings.CutPrefix(bearer, "user-jwt-"); ok {
		for _, u := range f.users {
			if u.NetID == netID {
				return false, u
			}
		}
	}
	return false, nil
}

func (f *fakePostgREST) serveRPC(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	service, _ := f.userForBearer(r)
	if !service {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"message": "not the service"})
		return
	}
	name := r.PathValue("name")
	f.rpcCalls[name]++
	var args map[string]any
	if err := json.NewDecoder(r.Body).Decode(&args); err != nil {
		f.t.Errorf("rpc %s: body is not JSON: %v", name, err)
		writeJSON(w, http.StatusBadRequest, map[string]string{"message": "bad body"})
		return
	}
	argInt := func(key string) int {
		v, _ := args[key].(float64)
		return int(v)
	}
	argString := func(key string) string {
		v, _ := args[key].(string)
		return v
	}
	switch name {
	case "issue_user_jwt":
		for _, u := range f.users {
			if u.NetID == argString("requested_netid") {
				writeJSON(w, http.StatusOK, map[string]any{
					"jwt": "user-jwt-" + u.NetID, "id": u.ID, "netid": u.NetID, "role": u.Role, "team_nickname": u.TeamNickname,
				})
				return
			}
		}
		writeJSON(w, http.StatusNotAcceptable, map[string]string{"code": "PGRST116"})
	case "claim_repository_provisioning":
		f.claim(w, argString("p_assignment_slug"), argInt("p_user_id"))
	case "record_repository_provisioning":
		f.record(w, args)
	case "finalize_repository_provisioning":
		f.finalize(w, args)
	case "touch_repository_provisioning_readiness":
		attempt := f.attempts[argInt("p_attempt_id")]
		if attempt == nil {
			writeJSON(w, http.StatusNotFound, map[string]string{"code": "P0002"})
			return
		}
		if attempt.Stage != "generated" && attempt.Stage != "granted" && attempt.Stage != "finalized" {
			f.raise(w, "invalid_stage_transition")
			return
		}
		now := f.clock.Now()
		attempt.LastCheckedAt = &now
		if ready, _ := args["p_ready"].(bool); ready && attempt.ReadyAt == nil {
			attempt.ReadyAt = &now
		}
		writeJSON(w, http.StatusOK, attempt)
	case "set_user_github_identity":
		user := f.users[argInt("p_user_id")]
		id := int64(argInt("p_github_user_id"))
		for _, other := range f.users {
			if other.ID != user.ID && other.GitHubUserID == id {
				f.raise(w, "github_identity_taken")
				return
			}
		}
		// Locked, as the RPC is: a change of account once a repository
		// exists for the user, or an attempt of theirs finalized.
		if user.GitHubUserID != 0 && user.GitHubUserID != id {
			for _, repo := range f.repositories {
				if repo.UserID == user.ID {
					f.raise(w, "github_identity_locked")
					return
				}
			}
			for _, attempt := range f.attempts {
				if attempt.Stage == provisioningStageFinalized && (attempt.UserID == user.ID || attempt.InitiatedByUserID == user.ID) {
					f.raise(w, "github_identity_locked")
					return
				}
			}
		}
		user.GitHubUserID = id
		user.GitHubLogin = argString("p_github_login")
		verified, _ := args["p_verified"].(bool)
		f.verified[user.ID] = verified
		writeJSON(w, http.StatusOK, user)
	default:
		f.t.Errorf("unexpected rpc %s", name)
		writeJSON(w, http.StatusNotFound, map[string]string{"message": "no such rpc"})
	}
}

func (f *fakePostgREST) findAttempt(slug string, userID int, team string) *provisioningAttempt {
	for _, a := range f.attempts {
		if a.AssignmentSlug == slug && a.UserID == userID && a.TeamNickname == team {
			return a
		}
	}
	return nil
}

func (f *fakePostgREST) findRepository(slug string, userID int, team string) *fakeRepositoryRow {
	for _, r := range f.repositories {
		if r.AssignmentSlug == slug && r.UserID == userID && r.TeamNickname == team {
			return r
		}
	}
	return nil
}

// claim mirrors api.claim_repository_provisioning closely enough for the
// handler's branches: the same refusals in the same order, the synthetic
// finalized row for an existing repository, the failed-to-claimed reset.
func (f *fakePostgREST) claim(w http.ResponseWriter, slug string, userID int) {
	assignment, ok := f.assignments[slug]
	if !ok || assignment.draft || assignment.template == "" {
		f.raise(w, "repository_not_configured")
		return
	}
	user := f.users[userID]
	if user == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"code": "22023", "message": "unknown user"})
		return
	}
	if user.Role != "student" {
		f.raise(w, "not_a_student")
		return
	}
	ownerUser, ownerTeam := userID, ""
	if assignment.isTeam {
		if user.TeamNickname == "" {
			f.raise(w, "no_team")
			return
		}
		ownerUser, ownerTeam = 0, user.TeamNickname
	}
	attempt := f.findAttempt(slug, ownerUser, ownerTeam)
	if repo := f.findRepository(slug, ownerUser, ownerTeam); repo != nil {
		synthetic := provisioningAttempt{
			AssignmentSlug: slug, IsTeam: repo.IsTeam, UserID: repo.UserID, TeamNickname: repo.TeamNickname,
			InitiatedByUserID: userID, Provider: repo.Provider, TemplateFullName: assignment.template,
			DestinationName: strings.SplitN(repo.ProviderFullName, "/", 2)[1], ProviderRepoID: repo.ProviderRepoID,
			ProviderFullName: repo.ProviderFullName, Stage: "finalized", CreatedAt: repo.CreatedAt, UpdatedAt: repo.UpdatedAt,
			ExistingRepositoryID: repo.ID,
		}
		if attempt != nil {
			synthetic.ID, synthetic.LastCheckedAt, synthetic.ReadyAt = attempt.ID, attempt.LastCheckedAt, attempt.ReadyAt
		}
		writeJSON(w, http.StatusOK, synthetic)
		return
	}
	if attempt != nil {
		if attempt.Stage == "failed" {
			attempt.Stage, attempt.ErrorCode = "claimed", ""
			attempt.UpdatedAt = f.clock.Now()
		}
		writeJSON(w, http.StatusOK, attempt)
		return
	}
	if assignment.closed {
		f.raise(w, "assignment_closed")
		return
	}
	if !assignment.isTeam && user.GitHubLogin == "" {
		f.raise(w, "needs_github_link")
		return
	}
	suffix := ownerTeam
	if suffix == "" {
		suffix = user.GitHubLogin
	}
	now := f.clock.Now()
	attempt = &provisioningAttempt{
		ID: f.nextAttemptID, AssignmentSlug: slug, IsTeam: assignment.isTeam, UserID: ownerUser, TeamNickname: ownerTeam,
		InitiatedByUserID: userID, Provider: "github", TemplateFullName: assignment.template,
		DestinationName: slug + "-" + suffix, Stage: "claimed", CreatedAt: now, UpdatedAt: now,
	}
	f.nextAttemptID++
	f.attempts[attempt.ID] = attempt
	writeJSON(w, http.StatusOK, attempt)
}

func (f *fakePostgREST) record(w http.ResponseWriter, args map[string]any) {
	id, _ := args["p_attempt_id"].(float64)
	attempt := f.attempts[int(id)]
	if attempt == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"code": "P0002"})
		return
	}
	stage, _ := args["p_stage"].(string)
	if attempt.Stage == "finalized" {
		f.raise(w, "already_finalized")
		return
	}
	allowed := stage == attempt.Stage ||
		(attempt.Stage == "claimed" && stage == "generated") ||
		(attempt.Stage == "generated" && stage == "granted") ||
		stage == "failed"
	if !allowed {
		f.raise(w, "invalid_stage_transition")
		return
	}
	if stage == "generated" {
		repoID, _ := args["p_provider_repo_id"].(float64)
		fullName, _ := args["p_provider_full_name"].(string)
		if repoID == 0 || fullName == "" {
			f.t.Errorf("record generated without a repository: %v", args)
		}
		if attempt.Stage == "generated" && (attempt.ProviderRepoID != int64(repoID) || attempt.ProviderFullName != fullName) {
			f.raise(w, "invalid_stage_transition")
			return
		}
		attempt.ProviderRepoID, attempt.ProviderFullName = int64(repoID), fullName
	} else if args["p_provider_repo_id"] != nil || args["p_provider_full_name"] != nil {
		f.t.Errorf("record %s carries a repository: %v", stage, args)
	}
	attempt.ErrorCode = ""
	if stage == "failed" {
		code, _ := args["p_error_code"].(string)
		if code == "" {
			f.t.Errorf("record failed without an error code")
		}
		attempt.ErrorCode = code
	}
	attempt.Stage = stage
	attempt.UpdatedAt = f.clock.Now()
	writeJSON(w, http.StatusOK, attempt)
}

// finalize mirrors api.finalize_repository_provisioning's refusals, in its
// order: stage granted, the URL bound to the recorded repository, the
// account bound to the linked one, one repository per owner and per forge
// id, and one value in the URL field.
func (f *fakePostgREST) finalize(w http.ResponseWriter, args map[string]any) {
	f.finalizeCalls++
	if f.finalizeRaise != "" {
		f.raise(w, f.finalizeRaise)
		return
	}
	id, _ := args["p_attempt_id"].(float64)
	attempt := f.attempts[int(id)]
	if attempt == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"code": "P0002"})
		return
	}
	if attempt.Stage == "finalized" {
		writeJSON(w, http.StatusOK, f.findRepository(attempt.AssignmentSlug, attempt.UserID, attempt.TeamNickname))
		return
	}
	if attempt.Stage != "granted" {
		f.t.Errorf("finalize called at stage %s", attempt.Stage)
		f.raise(w, "invalid_stage_transition")
		return
	}
	repoURL, _ := args["p_repo_url"].(string)
	if repoURL != "https://github.com/"+attempt.ProviderFullName {
		f.raise(w, "repo_url_mismatch")
		return
	}
	var providerUserID *int64
	if v, ok := args["p_provider_user_id"].(float64); ok {
		id := int64(v)
		providerUserID = &id
	}
	if attempt.IsTeam && providerUserID != nil {
		f.t.Errorf("finalize for a team carries a provider_user_id: %v", args)
	}
	if !attempt.IsTeam && providerUserID != nil {
		if linked := f.users[attempt.UserID].GitHubUserID; linked != 0 && linked != *providerUserID {
			f.raise(w, "github_identity_mismatch")
			return
		}
	}
	existing := f.findRepository(attempt.AssignmentSlug, attempt.UserID, attempt.TeamNickname)
	if existing != nil && existing.ProviderRepoID != attempt.ProviderRepoID {
		f.raise(w, "repository_conflict")
		return
	}
	if existing == nil {
		for _, other := range f.repositories {
			if other.ProviderRepoID == attempt.ProviderRepoID {
				f.raise(w, "repository_conflict")
				return
			}
		}
	}
	submissionKey := fmt.Sprintf("%s|%d|%s", attempt.AssignmentSlug, attempt.UserID, attempt.TeamNickname)
	if body, ok := f.submissions[submissionKey]; ok && body != repoURL {
		f.raise(w, "submission_conflict")
		return
	}
	now := f.clock.Now()
	if existing == nil {
		existing = &fakeRepositoryRow{
			ID: f.nextRepoID, AssignmentSlug: attempt.AssignmentSlug, IsTeam: attempt.IsTeam, UserID: attempt.UserID,
			TeamNickname: attempt.TeamNickname, Provider: "github", ProviderRepoID: attempt.ProviderRepoID,
			ProviderFullName: attempt.ProviderFullName, ProviderUserID: providerUserID, CreatedAt: now, UpdatedAt: now,
		}
		f.nextRepoID++
		f.repositories = append(f.repositories, existing)
	}
	f.submissions[submissionKey] = repoURL
	attempt.Stage, attempt.ErrorCode, attempt.UpdatedAt = "finalized", "", now
	writeJSON(w, http.StatusOK, existing)
}

// serveView answers the reads: api.users for the service, and the
// provisioning views for a student under their own row-level security.
func (f *fakePostgREST) serveView(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	service, user := f.userForBearer(r)
	view := r.PathValue("view")
	query := r.URL.Query()
	eq := func(column string) (string, bool) {
		value, ok := strings.CutPrefix(query.Get(column), "eq.")
		return value, ok
	}
	switch view {
	case "users":
		if !service {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"message": "users are read by the service"})
			return
		}
		var rows []*provisioningUser
		for _, u := range f.users {
			if netID, ok := eq("netid"); ok && u.NetID != netID {
				continue
			}
			if team, ok := eq("team_nickname"); ok && u.TeamNickname != team {
				continue
			}
			rows = append(rows, u)
		}
		writeJSON(w, http.StatusOK, rows)
	case "assignment_repository_provisionings", "assignment_repositories", "my_assignments":
		if user == nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"message": "views are read as the student"})
			return
		}
		slug, _ := eq("assignment_slug")
		if view == "my_assignments" {
			slug, _ = eq("slug")
			rows := []map[string]any{}
			if a, ok := f.assignments[slug]; ok {
				provider := any(nil)
				if a.template != "" {
					provider = "github"
				}
				rows = append(rows, map[string]any{"slug": slug, "is_draft": a.draft, "repository_template_provider": provider})
			}
			writeJSON(w, http.StatusOK, rows)
			return
		}
		visible := func(isTeam bool, userID int, team string) bool {
			if isTeam {
				return user.TeamNickname != "" && user.TeamNickname == team
			}
			return userID == user.ID
		}
		if view == "assignment_repository_provisionings" {
			rows := []*provisioningAttempt{}
			for _, a := range f.attempts {
				if a.AssignmentSlug == slug && visible(a.IsTeam, a.UserID, a.TeamNickname) {
					rows = append(rows, a)
				}
			}
			writeJSON(w, http.StatusOK, rows)
			return
		}
		rows := []*fakeRepositoryRow{}
		for _, repo := range f.repositories {
			if repo.AssignmentSlug == slug && visible(repo.IsTeam, repo.UserID, repo.TeamNickname) {
				rows = append(rows, repo)
			}
		}
		writeJSON(w, http.StatusOK, rows)
	default:
		f.t.Errorf("unexpected view read %s", view)
		writeJSON(w, http.StatusNotFound, map[string]string{"message": "no such view"})
	}
}

func (f *fakePostgREST) attempt(t *testing.T, slug string, userID int, team string) provisioningAttempt {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	a := f.findAttempt(slug, userID, team)
	if a == nil {
		t.Fatalf("no attempt for %s user=%d team=%q", slug, userID, team)
	}
	return *a
}

// seedAttempt plants an attempt as an earlier process would have left it.
func (f *fakePostgREST) seedAttempt(a provisioningAttempt) *provisioningAttempt {
	f.mu.Lock()
	defer f.mu.Unlock()
	if a.ID == 0 {
		a.ID = f.nextAttemptID
		f.nextAttemptID++
	}
	if a.CreatedAt.IsZero() {
		a.CreatedAt = f.clock.Now()
	}
	if a.UpdatedAt.IsZero() {
		a.UpdatedAt = a.CreatedAt
	}
	if a.Provider == "" {
		a.Provider = "github"
	}
	f.attempts[a.ID] = &a
	return &a
}

func (f *fakePostgREST) seedRepository(row fakeRepositoryRow) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if row.ID == 0 {
		row.ID = f.nextRepoID
		f.nextRepoID++
	}
	if row.Provider == "" {
		row.Provider = "github"
	}
	if row.CreatedAt.IsZero() {
		row.CreatedAt = f.clock.Now()
	}
	row.UpdatedAt = row.CreatedAt
	f.repositories = append(f.repositories, &row)
}

// ---------------------------------------------------------------------------
// Fake GitHub
// ---------------------------------------------------------------------------

type fakeGitHubRepo struct {
	id        int64
	fullName  string
	createdAt time.Time
	template  string
	// ready answers HEAD with a commit; otherwise 409 as an empty
	// repository does. hidden answers 404 to everything, as a repository
	// the credential cannot see does.
	ready  bool
	hidden bool
}

type fakeGitHub struct {
	t      *testing.T
	clock  *fakeClock
	server *httptest.Server

	mu          sync.Mutex
	accounts    map[string]int64
	memberships map[string]string
	repos       map[string]*fakeGitHubRepo
	nextRepoID  int64
	calls       map[string]int

	// Scripting. generateStatus, when set, is answered instead of 201;
	// generateCreates makes the repository exist anyway, which is what an
	// ambiguous failure after the POST landed looks like. invited lists
	// logins whose collaborator grant answers 201 (an invitation).
	generateStatus  int
	generateCreates bool
	generateDelay   time.Duration
	invited         map[string]bool
	rateLimited     bool
	retryAfter      int
}

func newFakeGitHubForProvisioning(t *testing.T, clock *fakeClock) *fakeGitHub {
	t.Helper()
	g := &fakeGitHub{
		t:           t,
		clock:       clock,
		accounts:    map[string]int64{},
		memberships: map[string]string{},
		repos:       map[string]*fakeGitHubRepo{},
		nextRepoID:  1000,
		calls:       map[string]int{},
		invited:     map[string]bool{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /users/{login}", g.wrap("user", func(w http.ResponseWriter, r *http.Request) {
		login := r.PathValue("login")
		id, ok := g.accounts[login]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "login": login})
	}))
	mux.HandleFunc("GET /orgs/{org}/memberships/{login}", g.wrap("membership", func(w http.ResponseWriter, r *http.Request) {
		state, ok := g.memberships[r.PathValue("login")]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"state": state, "role": "member"})
	}))
	mux.HandleFunc("POST /repos/{owner}/{repo}/generate", g.wrap("generate", func(w http.ResponseWriter, r *http.Request) {
		template := r.PathValue("owner") + "/" + r.PathValue("repo")
		var body struct {
			Owner   string `json:"owner"`
			Name    string `json:"name"`
			Private bool   `json:"private"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if !body.Private {
			g.t.Errorf("generate without private=true: %+v", body)
		}
		if _, ok := g.repos[template]; !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		fullName := body.Owner + "/" + body.Name
		if _, exists := g.repos[fullName]; exists {
			writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"message": "Repository creation failed."})
			return
		}
		if g.generateDelay > 0 {
			g.mu.Unlock()
			time.Sleep(g.generateDelay)
			g.mu.Lock()
		}
		if g.generateStatus != 0 && !g.generateCreates {
			writeJSON(w, g.generateStatus, map[string]string{"message": "failed"})
			return
		}
		repo := &fakeGitHubRepo{id: g.nextRepoID, fullName: fullName, createdAt: g.clock.Now().Truncate(time.Second), template: template}
		g.nextRepoID++
		g.repos[fullName] = repo
		if g.generateStatus != 0 {
			writeJSON(w, g.generateStatus, map[string]string{"message": "failed"})
			return
		}
		writeJSON(w, http.StatusCreated, g.repoJSON(repo))
	}))
	mux.HandleFunc("GET /repos/{owner}/{repo}", g.wrap("get_repo", func(w http.ResponseWriter, r *http.Request) {
		repo, ok := g.repos[r.PathValue("owner")+"/"+r.PathValue("repo")]
		if !ok || repo.hidden {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		writeJSON(w, http.StatusOK, g.repoJSON(repo))
	}))
	mux.HandleFunc("PUT /repos/{owner}/{repo}/collaborators/{login}", g.wrap("collaborator", func(w http.ResponseWriter, r *http.Request) {
		repo, ok := g.repos[r.PathValue("owner")+"/"+r.PathValue("repo")]
		if !ok || repo.hidden {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["permission"] != "push" {
			g.t.Errorf("collaborator permission = %q, want push", body["permission"])
		}
		login := r.PathValue("login")
		g.calls["collaborator:"+login]++
		if g.invited[login] {
			writeJSON(w, http.StatusCreated, map[string]any{"id": 1})
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	mux.HandleFunc("GET /repos/{owner}/{repo}/commits/HEAD", g.wrap("head", func(w http.ResponseWriter, r *http.Request) {
		repo, ok := g.repos[r.PathValue("owner")+"/"+r.PathValue("repo")]
		if !ok || repo.hidden {
			writeJSON(w, http.StatusNotFound, map[string]string{"message": "Not Found"})
			return
		}
		if !repo.ready {
			writeJSON(w, http.StatusConflict, map[string]string{"message": "Git Repository is empty."})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"sha": "0123abcd"})
	}))
	g.server = httptest.NewServer(mux)
	t.Cleanup(g.server.Close)
	return g
}

// wrap checks the credential, applies the scripted rate limit, counts the
// call, and holds the lock for the handler.
func (g *fakeGitHub) wrap(name string, handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer "+provisioningTestToken {
			g.t.Errorf("%s %s: Authorization = %q", r.Method, r.URL.Path, got)
		}
		g.mu.Lock()
		defer g.mu.Unlock()
		g.calls[name]++
		if g.rateLimited {
			w.Header().Set("Retry-After", strconv.Itoa(g.retryAfter))
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"message": "API rate limit exceeded"})
			return
		}
		handler(w, r)
	}
}

func (g *fakeGitHub) repoJSON(repo *fakeGitHubRepo) map[string]any {
	out := map[string]any{
		"id":             repo.id,
		"full_name":      repo.fullName,
		"html_url":       "https://github.com/" + repo.fullName,
		"default_branch": "main",
		"created_at":     repo.createdAt.UTC().Format(time.RFC3339),
	}
	if repo.template != "" {
		out["template_repository"] = map[string]any{"full_name": repo.template}
	}
	return out
}

func (g *fakeGitHub) count(name string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls[name]
}

func (g *fakeGitHub) addRepo(repo fakeGitHubRepo) *fakeGitHubRepo {
	g.mu.Lock()
	defer g.mu.Unlock()
	if repo.id == 0 {
		repo.id = g.nextRepoID
		g.nextRepoID++
	}
	if repo.createdAt.IsZero() {
		repo.createdAt = g.clock.Now()
	}
	g.repos[repo.fullName] = &repo
	return &repo
}

func (g *fakeGitHub) setReady(fullName string, ready bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.repos[fullName].ready = ready
}

// ---------------------------------------------------------------------------
// The stack
// ---------------------------------------------------------------------------

type provisioningStack struct {
	t       *testing.T
	clock   *fakeClock
	db      *fakePostgREST
	github  *fakeGitHub
	handler *provisioningHandler
	server  *httptest.Server

	clientsMu sync.Mutex
	clients   map[string]*http.Client
}

// Fixtures every test starts from. hw1 is individual, proj is a team
// assignment; alice and bob are on team alpha with linked, active GitHub
// accounts; carol has no GitHub login; prof is faculty.
func newProvisioningStack(t *testing.T) *provisioningStack {
	t.Helper()
	clock := &fakeClock{now: time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)}
	db := newFakePostgREST(t, clock)
	db.assignments["hw1"] = fakeAssignment{template: "course/hw1-starter"}
	db.assignments["proj"] = fakeAssignment{isTeam: true, template: "course/proj-starter"}
	db.assignments["plain"] = fakeAssignment{}
	db.users[1] = &provisioningUser{ID: 1, NetID: "alice", Role: "student", TeamNickname: "alpha", GitHubLogin: "alice"}
	db.users[2] = &provisioningUser{ID: 2, NetID: "bob", Role: "student", TeamNickname: "alpha", GitHubLogin: "bob"}
	db.users[3] = &provisioningUser{ID: 3, NetID: "carol", Role: "student"}
	db.users[4] = &provisioningUser{ID: 4, NetID: "prof", Role: "faculty"}

	github := newFakeGitHubForProvisioning(t, clock)
	github.accounts["alice"] = 101
	github.accounts["bob"] = 102
	github.memberships["alice"] = "active"
	github.memberships["bob"] = "active"
	github.addRepo(fakeGitHubRepo{fullName: "course/hw1-starter", ready: true, createdAt: clock.Now().Add(-time.Hour)})
	github.addRepo(fakeGitHubRepo{fullName: "course/proj-starter", ready: true, createdAt: clock.Now().Add(-time.Hour)})

	sessionManager := newSessionManager(true, memstore.New())
	provisioner := &githubProvisioner{
		client: newGitHubClient(github.server.URL, githubStaticTokenSource{token: provisioningTestToken}),
		org:    "course",
	}
	handler := newProvisioningHandler(provisioner, db.config, sessionManager)
	handler.now = clock.Now

	mux := http.NewServeMux()
	mux.Handle("/auth/assignments/{slug}/repository", handler)
	mux.HandleFunc("/test/seed", func(w http.ResponseWriter, r *http.Request) {
		sessionManager.Put(r.Context(), "netid", r.URL.Query().Get("netid"))
		w.WriteHeader(http.StatusNoContent)
	})
	server := httptest.NewServer(sessionManager.LoadAndSave(mux))
	t.Cleanup(server.Close)

	return &provisioningStack{t: t, clock: clock, db: db, github: github, handler: handler, server: server, clients: map[string]*http.Client{}}
}

// clientFor returns a signed-in client for the netid; "" is a visitor with
// no session.
func (s *provisioningStack) clientFor(netID string) *http.Client {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	if client, ok := s.clients[netID]; ok {
		return client
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		s.t.Fatalf("cookiejar: %v", err)
	}
	client := &http.Client{Jar: jar}
	if netID != "" {
		response, err := client.Get(s.server.URL + "/test/seed?netid=" + url.QueryEscape(netID))
		if err != nil {
			s.t.Fatalf("seeding the session: %v", err)
		}
		response.Body.Close()
	}
	s.clients[netID] = client
	return client
}

type provisioningResponse struct {
	status     int
	header     http.Header
	state      string
	repoURL    string
	code       string
	retryable  bool
	body       string
	hasJoinURL bool
}

// do sends one request as the netid. POSTs are marked same-origin the way a
// browser marks them unless the test says otherwise. Every body is checked
// for the GitHub token: no reply may ever carry it.
func (s *provisioningStack) do(method string, netID string, slug string, headers map[string]string) provisioningResponse {
	s.t.Helper()
	req, err := http.NewRequest(method, s.server.URL+"/auth/assignments/"+slug+"/repository", strings.NewReader("{}"))
	if err != nil {
		s.t.Fatalf("building request: %v", err)
	}
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Sec-Fetch-Site", "same-origin")
	}
	for k, v := range headers {
		if v == "" {
			req.Header.Del(k)
		} else {
			req.Header.Set(k, v)
		}
	}
	response, err := s.clientFor(netID).Do(req)
	if err != nil {
		s.t.Fatalf("%s %s: %v", method, slug, err)
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(response.Body)
	body := string(raw)
	if strings.Contains(body, provisioningTestToken) {
		s.t.Fatalf("response body carries the GitHub token: %s", body)
	}
	if got := response.Header.Get("Cache-Control"); got != "no-store" && response.StatusCode != http.StatusNotFound {
		s.t.Errorf("%s %s: Cache-Control = %q, want no-store", method, slug, got)
	}
	out := provisioningResponse{status: response.StatusCode, header: response.Header, body: body}
	var decoded struct {
		State   *string `json:"state"`
		RepoURL *string `json:"repo_url"`
		JoinURL *string `json:"join_url"`
		Error   *struct {
			Code      string `json:"code"`
			Retryable bool   `json:"retryable"`
		} `json:"error"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		s.t.Fatalf("%s %s: body is not JSON: %s", method, slug, body)
	}
	if decoded.State != nil {
		out.state = *decoded.State
	}
	if decoded.RepoURL != nil {
		out.repoURL = *decoded.RepoURL
	}
	out.hasJoinURL = decoded.JoinURL != nil
	if decoded.Error != nil {
		out.code, out.retryable = decoded.Error.Code, decoded.Error.Retryable
	}
	return out
}

func (s *provisioningStack) post(netID string, slug string) provisioningResponse {
	s.t.Helper()
	return s.do(http.MethodPost, netID, slug, nil)
}

func (s *provisioningStack) get(netID string, slug string) provisioningResponse {
	s.t.Helper()
	return s.do(http.MethodGet, netID, slug, nil)
}

func (r provisioningResponse) expectState(t *testing.T, status int, state string) {
	t.Helper()
	if r.status != status || r.state != state {
		t.Fatalf("got %d %q (%s), want %d %q", r.status, r.state, r.body, status, state)
	}
	if r.hasJoinURL {
		t.Fatalf("join_url is set before the join flow exists: %s", r.body)
	}
}

func (r provisioningResponse) expectError(t *testing.T, status int, code string, retryable bool) {
	t.Helper()
	if r.status != status || r.code != code || r.retryable != retryable {
		t.Fatalf("got %d %q retryable=%v (%s), want %d %q retryable=%v", r.status, r.code, r.retryable, r.body, status, code, retryable)
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestProvisioningIndividualHappyPath(t *testing.T) {
	s := newProvisioningStack(t)

	// The click. GitHub returns the repository before its contents exist.
	first := s.post("alice", "hw1")
	first.expectState(t, http.StatusAccepted, repositoryStateCopying)
	if first.repoURL != "https://github.com/course/hw1-alice" {
		t.Fatalf("repo_url = %q", first.repoURL)
	}
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("generate calls = %d, want 1", got)
	}
	if got := s.github.count("collaborator:alice"); got != 1 {
		t.Fatalf("collaborator grants for alice = %d, want 1", got)
	}
	attempt := s.db.attempt(t, "hw1", 1, "")
	if attempt.Stage != "finalized" || attempt.ProviderRepoID == 0 || attempt.LastCheckedAt == nil || attempt.ReadyAt != nil {
		t.Fatalf("attempt after the click = %+v", attempt)
	}
	if s.db.finalizeCalls != 1 {
		t.Fatalf("finalize calls = %d, want 1", s.db.finalizeCalls)
	}
	// The login was resolved and linked, unverified, as a side effect.
	if s.db.users[1].GitHubUserID != 101 {
		t.Fatalf("alice's github_user_id = %d, want 101", s.db.users[1].GitHubUserID)
	}
	repo := s.db.findRepository("hw1", 1, "")
	if repo == nil || repo.ProviderUserID == nil || *repo.ProviderUserID != 101 {
		t.Fatalf("repository row = %+v", repo)
	}

	// A poll straight afterwards is answered from the row, not GitHub.
	heads := s.github.count("head")
	s.get("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	if got := s.github.count("head"); got != heads {
		t.Fatalf("poll within the cache window asked GitHub (%d -> %d)", heads, got)
	}

	// The contents land; the next poll after the window sees them.
	s.github.setReady("course/hw1-alice", true)
	s.clock.Advance(4 * time.Second)
	ready := s.get("alice", "hw1")
	ready.expectState(t, http.StatusOK, repositoryStateReady)
	if ready.repoURL != "https://github.com/course/hw1-alice" {
		t.Fatalf("repo_url = %q", ready.repoURL)
	}
	if got := s.github.count("head"); got != heads+1 {
		t.Fatalf("head calls = %d, want %d", got, heads+1)
	}
	// Ready is remembered: no GitHub call ever again for this repository.
	s.clock.Advance(time.Hour)
	s.get("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
	s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
	if got := s.github.count("head"); got != heads+1 {
		t.Fatalf("head calls after ready = %d, want %d", got, heads+1)
	}
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("a repeated click generated again (%d)", got)
	}
}

func TestProvisioningTeamHappyPath(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.addRepo(fakeGitHubRepo{fullName: "course/proj-alpha-placeholder"}) // unrelated name, must not matter

	bob := s.post("bob", "proj")
	bob.expectState(t, http.StatusAccepted, repositoryStateCopying)
	if bob.repoURL != "https://github.com/course/proj-alpha" {
		t.Fatalf("repo_url = %q", bob.repoURL)
	}
	for _, login := range []string{"alice", "bob"} {
		if got := s.github.count("collaborator:" + login); got != 1 {
			t.Fatalf("collaborator grants for %s = %d, want 1", login, got)
		}
	}
	attempt := s.db.attempt(t, "proj", 0, "alpha")
	if attempt.Stage != "finalized" || attempt.InitiatedByUserID != 2 {
		t.Fatalf("attempt = %+v", attempt)
	}
	if repo := s.db.findRepository("proj", 0, "alpha"); repo == nil || repo.ProviderUserID != nil {
		t.Fatalf("team repository row = %+v", repo)
	}

	// A teammate sees the same repository through their own session, and
	// a click of theirs creates nothing more.
	s.github.setReady("course/proj-alpha", true)
	s.clock.Advance(4 * time.Second)
	s.get("alice", "proj").expectState(t, http.StatusOK, repositoryStateReady)
	s.post("alice", "proj").expectState(t, http.StatusOK, repositoryStateReady)
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("generate calls = %d, want 1", got)
	}
	// Someone on another team does not.
	s.db.users[3].TeamNickname = "beta"
	s.get("carol", "proj").expectError(t, http.StatusNotFound, "repository_not_started", false)
}

func TestProvisioningTeamPrerequisites(t *testing.T) {
	s := newProvisioningStack(t)
	// bob has not joined the organization; alice clicks. The block is
	// bob's to clear, so alice gets a conflict, not "needs_org_join".
	s.github.memberships["bob"] = "pending"
	s.post("alice", "proj").expectError(t, http.StatusConflict, "team_prerequisites_incomplete", true)
	if got := s.github.count("generate"); got != 0 {
		t.Fatalf("generated with a teammate blocked (%d)", got)
	}
	// bob clicking sees his own blocker.
	s.post("bob", "proj").expectState(t, http.StatusOK, repositoryStateNeedsOrgJoin)
	// Once he joins, either click completes.
	s.github.memberships["bob"] = "active"
	s.post("alice", "proj").expectState(t, http.StatusAccepted, repositoryStateCopying)
}

// Each stage an earlier process may have died at, and what the next click
// must and must not do from there.
func TestProvisioningResumesFromEachStage(t *testing.T) {
	cases := []struct {
		stage            string
		wantGenerate     int
		wantCollaborator int
		wantFinalize     int
		wantStatus       int
		wantState        string
	}{
		// From claimed the repository is generated fresh and is still
		// copying; from the later stages the seeded repository has contents.
		{"claimed", 1, 1, 1, http.StatusAccepted, repositoryStateCopying},
		{"generated", 0, 1, 1, http.StatusOK, repositoryStateReady},
		// Grants are reconciled again from granted; the PUT is idempotent.
		{"granted", 0, 1, 1, http.StatusOK, repositoryStateReady},
		{"finalized", 0, 0, 0, http.StatusOK, repositoryStateReady},
	}
	for _, tc := range cases {
		t.Run(tc.stage, func(t *testing.T) {
			s := newProvisioningStack(t)
			s.db.users[1].GitHubUserID = 101
			attempt := provisioningAttempt{
				AssignmentSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter",
				DestinationName: "hw1-alice", Stage: tc.stage, CreatedAt: s.clock.Now().Add(-time.Minute),
			}
			if tc.stage != "claimed" {
				repo := s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", template: "course/hw1-starter", ready: true})
				attempt.ProviderRepoID, attempt.ProviderFullName = repo.id, repo.fullName
			}
			seeded := s.db.seedAttempt(attempt)
			if tc.stage == "finalized" {
				s.db.seedRepository(fakeRepositoryRow{AssignmentSlug: "hw1", UserID: 1, ProviderRepoID: seeded.ProviderRepoID, ProviderFullName: seeded.ProviderFullName})
			}

			s.post("alice", "hw1").expectState(t, tc.wantStatus, tc.wantState)
			if got := s.github.count("generate"); got != tc.wantGenerate {
				t.Fatalf("generate calls = %d, want %d", got, tc.wantGenerate)
			}
			if got := s.github.count("collaborator:alice"); got != tc.wantCollaborator {
				t.Fatalf("collaborator calls = %d, want %d", got, tc.wantCollaborator)
			}
			if s.db.finalizeCalls != tc.wantFinalize {
				t.Fatalf("finalize calls = %d, want %d", s.db.finalizeCalls, tc.wantFinalize)
			}
			if final := s.db.attempt(t, "hw1", 1, ""); final.Stage != "finalized" || final.ID != seeded.ID {
				t.Fatalf("attempt after resume = %+v", final)
			}
		})
	}
}

// A failed attempt is reset by the claim and run again from the start.
func TestProvisioningRetriesAFailedAttempt(t *testing.T) {
	s := newProvisioningStack(t)
	s.db.seedAttempt(provisioningAttempt{
		AssignmentSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter",
		DestinationName: "hw1-alice", Stage: "failed", ErrorCode: "github_unavailable",
	})
	s.get("alice", "hw1").expectError(t, http.StatusConflict, "github_unavailable", true)
	s.post("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("generate calls = %d, want 1", got)
	}
}

func TestProvisioningNeedsGitHubLink(t *testing.T) {
	s := newProvisioningStack(t)

	t.Run("no login on record", func(t *testing.T) {
		s.post("carol", "hw1").expectState(t, http.StatusOK, repositoryStateNeedsGitHubLink)
	})
	t.Run("login no longer resolves", func(t *testing.T) {
		s.db.users[2].GitHubLogin = "bob-renamed"
		s.post("bob", "hw1").expectState(t, http.StatusOK, repositoryStateNeedsGitHubLink)
		// Not a failure of the attempt: nothing was tried.
		if a := s.db.attempt(t, "hw1", 2, ""); a.Stage != "claimed" {
			t.Fatalf("attempt stage = %s, want claimed", a.Stage)
		}
	})
	t.Run("login now belongs to a different account", func(t *testing.T) {
		s.db.users[1].GitHubUserID = 999
		s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateNeedsGitHubLink)
	})
	if got := s.github.count("generate"); got != 0 {
		t.Fatalf("generated with no trusted identity (%d)", got)
	}
}

func TestProvisioningNeedsOrgJoin(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.memberships["alice"] = "pending"
	reply := s.post("alice", "hw1")
	reply.expectState(t, http.StatusOK, repositoryStateNeedsOrgJoin)
	if reply.repoURL != "" {
		t.Fatalf("repo_url = %q before anything exists", reply.repoURL)
	}
	delete(s.github.memberships, "alice")
	s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateNeedsOrgJoin)
	if got := s.github.count("generate"); got != 0 {
		t.Fatalf("generated for a non-member (%d)", got)
	}
	// Still linked, because the account did resolve.
	if s.db.users[1].GitHubUserID != 101 {
		t.Fatalf("alice's github_user_id = %d, want 101", s.db.users[1].GitHubUserID)
	}
}

// GitHub creates the repository and then answers 502. This click cannot
// know that; it records the failure. The next click looks the name up
// before posting and adopts what it finds.
func TestProvisioningAmbiguousGenerateIsAdoptedOnRetry(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.generateStatus = http.StatusBadGateway
	s.github.generateCreates = true

	s.post("alice", "hw1").expectError(t, http.StatusBadGateway, "github_unavailable", true)
	if got := s.github.count("collaborator:alice"); got != 0 {
		t.Fatalf("granted after an ambiguous generate (%d)", got)
	}
	if a := s.db.attempt(t, "hw1", 1, ""); a.Stage != "failed" || a.ErrorCode != "github_unavailable" {
		t.Fatalf("attempt = %+v", a)
	}
	s.github.generateStatus = 0
	s.post("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("generate calls = %d, want exactly 1", got)
	}
	attempt := s.db.attempt(t, "hw1", 1, "")
	if attempt.Stage != "finalized" || attempt.ProviderRepoID != s.github.repos["course/hw1-alice"].id {
		t.Fatalf("attempt = %+v", attempt)
	}
}

// The generate times out and the repository lands only afterwards, when a
// lookup made straight away would still have said 404. The rule holds
// because the lookup is the retry's first step, not a one-off after the
// failure.
func TestProvisioningLateLandingGenerateIsAdoptedOnRetry(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.generateStatus = http.StatusBadGateway

	s.post("alice", "hw1").expectError(t, http.StatusBadGateway, "github_unavailable", true)
	if got := s.github.count("get_repo"); got != 1 {
		t.Fatalf("lookups before the generate = %d, want 1", got)
	}
	// It lands.
	s.clock.Advance(20 * time.Second)
	landed := s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", template: "course/hw1-starter"})
	s.github.generateStatus = 0

	s.post("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("generate calls = %d, want exactly 1", got)
	}
	if a := s.db.attempt(t, "hw1", 1, ""); a.Stage != "finalized" || a.ProviderRepoID != landed.id {
		t.Fatalf("attempt = %+v", a)
	}
}

func TestProvisioningAmbiguousGenerateThatDidNotLand(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.generateStatus = http.StatusBadGateway

	s.post("alice", "hw1").expectError(t, http.StatusBadGateway, "github_unavailable", true)
	if got := s.github.count("collaborator:alice"); got != 0 {
		t.Fatalf("granted on a repository that does not exist (%d)", got)
	}
	// The retry posts again, because its lookup finds nothing.
	s.github.generateStatus = 0
	s.post("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	if got := s.github.count("generate"); got != 2 {
		t.Fatalf("generate calls = %d, want 2", got)
	}
}

func TestProvisioningNameTakenByAnUnrelatedRepository(t *testing.T) {
	s := newProvisioningStack(t)
	stranger := s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", template: "course/other-starter", createdAt: s.clock.Now().Add(-24 * time.Hour), ready: true})

	s.post("alice", "hw1").expectError(t, http.StatusConflict, "name_taken", false)
	if got := s.github.count("generate"); got != 0 {
		t.Fatalf("posted a generate over a taken name (%d)", got)
	}
	if got := s.github.count("collaborator:alice"); got != 0 {
		t.Fatalf("granted on a stranger's repository (%d)", got)
	}
	if s.db.finalizeCalls != 0 {
		t.Fatal("finalized a stranger's repository")
	}
	attempt := s.db.attempt(t, "hw1", 1, "")
	if attempt.Stage != "failed" || attempt.ErrorCode != "name_taken" || attempt.ProviderRepoID == stranger.id {
		t.Fatalf("attempt = %+v", attempt)
	}
	s.get("alice", "hw1").expectError(t, http.StatusConflict, "name_taken", true)
	// A repository made from our template but before the attempt is not
	// ours either.
	s.github.repos["course/hw1-alice"].template = "course/hw1-starter"
	s.post("alice", "hw1").expectError(t, http.StatusConflict, "name_taken", false)
}

func TestProvisioningTemplatePreflight(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.setReady("course/hw1-starter", false)
	s.post("alice", "hw1").expectError(t, http.StatusBadGateway, "template_empty", false)
	if got := s.github.count("generate"); got != 0 {
		t.Fatalf("generated from an empty template (%d)", got)
	}
	s.db.assignments["hw2"] = fakeAssignment{template: "course/missing-starter"}
	s.post("alice", "hw2").expectError(t, http.StatusBadGateway, "template_not_found", false)
}

func TestProvisioningCollaboratorInvitationIsNotAccess(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.invited["alice"] = true
	s.post("alice", "hw1").expectError(t, http.StatusConflict, "collaborator_not_member", false)
	if s.db.finalizeCalls != 0 {
		t.Fatal("finalized with only an invitation outstanding")
	}
	if a := s.db.attempt(t, "hw1", 1, ""); a.Stage != "failed" || a.ErrorCode != "collaborator_not_member" {
		t.Fatalf("attempt = %+v", a)
	}
}

// Validation is not a one-off at claim: a resumed attempt re-checks every
// owner before it touches GitHub again.
func TestProvisioningResumedAttemptsRevalidateOwners(t *testing.T) {
	t.Run("identity changed after generate", func(t *testing.T) {
		s := newProvisioningStack(t)
		s.db.users[1].GitHubUserID = 101
		repo := s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", template: "course/hw1-starter"})
		s.db.seedAttempt(provisioningAttempt{
			AssignmentSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter", DestinationName: "hw1-alice",
			Stage: "generated", ProviderRepoID: repo.id, ProviderFullName: repo.fullName,
		})
		// The login "alice" is now somebody else's account.
		s.github.accounts["alice"] = 9999
		s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateNeedsGitHubLink)
		if got := s.github.count("collaborator:alice"); got != 0 {
			t.Fatalf("granted to an account that is not the linked one (%d)", got)
		}
		if s.db.finalizeCalls != 0 {
			t.Fatal("finalized")
		}
	})
	t.Run("teammate membership lapsed after generate", func(t *testing.T) {
		s := newProvisioningStack(t)
		repo := s.github.addRepo(fakeGitHubRepo{fullName: "course/proj-alpha", template: "course/proj-starter"})
		s.db.seedAttempt(provisioningAttempt{
			AssignmentSlug: "proj", IsTeam: true, TeamNickname: "alpha", InitiatedByUserID: 1, TemplateFullName: "course/proj-starter",
			DestinationName: "proj-alpha", Stage: "generated", ProviderRepoID: repo.id, ProviderFullName: repo.fullName,
		})
		s.github.memberships["bob"] = "pending"
		s.post("alice", "proj").expectError(t, http.StatusConflict, "team_prerequisites_incomplete", true)
		if got := s.github.count("collaborator:alice") + s.github.count("collaborator:bob"); got != 0 {
			t.Fatalf("granted with a teammate blocked (%d)", got)
		}
	})
	t.Run("teammate added after grant", func(t *testing.T) {
		s := newProvisioningStack(t)
		repo := s.github.addRepo(fakeGitHubRepo{fullName: "course/proj-alpha", template: "course/proj-starter", ready: true})
		s.db.seedAttempt(provisioningAttempt{
			AssignmentSlug: "proj", IsTeam: true, TeamNickname: "alpha", InitiatedByUserID: 1, TemplateFullName: "course/proj-starter",
			DestinationName: "proj-alpha", Stage: "granted", ProviderRepoID: repo.id, ProviderFullName: repo.fullName,
		})
		s.db.users[5] = &provisioningUser{ID: 5, NetID: "dave", Role: "student", TeamNickname: "alpha", GitHubLogin: "dave"}
		s.github.accounts["dave"] = 105
		s.github.memberships["dave"] = "active"
		s.post("alice", "proj").expectState(t, http.StatusOK, repositoryStateReady)
		if got := s.github.count("collaborator:dave"); got != 1 {
			t.Fatalf("dave's grants = %d, want 1", got)
		}
		if s.db.finalizeCalls != 1 || s.db.users[5].GitHubUserID != 105 {
			t.Fatalf("finalize calls = %d, dave linked to %d", s.db.finalizeCalls, s.db.users[5].GitHubUserID)
		}
	})
}

// The provider cooldown is checked before each GitHub call, not once per
// request, so work that needs no GitHub call proceeds during it. A resumed
// unfinished attempt always needs GitHub (owners are revalidated), so it is
// refused; a finished one whose readiness is recorded is not.
func TestProvisioningCooldownIsPerCall(t *testing.T) {
	s := newProvisioningStack(t)
	s.db.users[1].GitHubUserID = 101
	repo := s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", template: "course/hw1-starter", ready: true})
	s.db.seedAttempt(provisioningAttempt{
		AssignmentSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter", DestinationName: "hw1-alice",
		Stage: "granted", ProviderRepoID: repo.id, ProviderFullName: repo.fullName,
	})
	s.handler.setCooldown(s.clock.Now().Add(time.Minute))

	reply := s.post("alice", "hw1")
	reply.expectError(t, http.StatusTooManyRequests, "github_rate_limited", true)
	if s.db.finalizeCalls != 0 || s.github.count("user") != 0 {
		t.Fatalf("finalize calls = %d, GitHub calls = %d during cooldown", s.db.finalizeCalls, s.github.count("user"))
	}

	// Once the cooldown passes the attempt finalizes; a later click during
	// another cooldown is answered from the row without GitHub.
	s.clock.Advance(2 * time.Minute)
	s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
	s.handler.setCooldown(s.clock.Now().Add(time.Minute))
	calls := s.github.count("user") + s.github.count("head")
	s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
	s.get("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
	if got := s.github.count("user") + s.github.count("head"); got != calls {
		t.Fatalf("asked GitHub during a cooldown (%d -> %d)", calls, got)
	}
}

// Each refusal finalize can raise, and how the handler answers it.
func TestProvisioningFinalizeRefusals(t *testing.T) {
	seedGranted := func(s *provisioningStack, repoID int64) {
		s.db.users[1].GitHubUserID = 101
		s.github.addRepo(fakeGitHubRepo{id: repoID, fullName: "course/hw1-alice", template: "course/hw1-starter", ready: true})
		s.db.seedAttempt(provisioningAttempt{
			AssignmentSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter", DestinationName: "hw1-alice",
			Stage: "granted", ProviderRepoID: repoID, ProviderFullName: "course/hw1-alice",
		})
	}
	expectFailed := func(t *testing.T, s *provisioningStack, code string) {
		t.Helper()
		if a := s.db.attempt(t, "hw1", 1, ""); a.Stage != "failed" || a.ErrorCode != code {
			t.Fatalf("attempt = %+v, want failed %s", a, code)
		}
		s.get("alice", "hw1").expectError(t, http.StatusConflict, code, true)
	}

	t.Run("repository_conflict: forge id already recorded for another owner", func(t *testing.T) {
		s := newProvisioningStack(t)
		seedGranted(s, 5)
		s.db.seedRepository(fakeRepositoryRow{AssignmentSlug: "hw1", UserID: 2, ProviderRepoID: 5, ProviderFullName: "course/hw1-alice"})
		s.post("alice", "hw1").expectError(t, http.StatusConflict, "repository_conflict", false)
		expectFailed(t, s, "repository_conflict")
	})
	t.Run("submission_conflict: the URL field already holds another value", func(t *testing.T) {
		s := newProvisioningStack(t)
		seedGranted(s, 5)
		s.db.submissions["hw1|1|"] = "https://github.com/alice/my-own-repo"
		s.post("alice", "hw1").expectError(t, http.StatusConflict, "submission_conflict", false)
		expectFailed(t, s, "submission_conflict")
	})
	t.Run("repo_url_mismatch", func(t *testing.T) {
		s := newProvisioningStack(t)
		seedGranted(s, 5)
		s.db.finalizeRaise = "repo_url_mismatch"
		s.post("alice", "hw1").expectError(t, http.StatusConflict, "repo_url_mismatch", false)
		expectFailed(t, s, "repo_url_mismatch")
	})
	t.Run("github_identity_mismatch is a link problem", func(t *testing.T) {
		s := newProvisioningStack(t)
		seedGranted(s, 5)
		s.db.finalizeRaise = "github_identity_mismatch"
		s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateNeedsGitHubLink)
		expectFailed(t, s, "github_identity_mismatch")
	})
	t.Run("a repeated finalize is a no-op", func(t *testing.T) {
		s := newProvisioningStack(t)
		seedGranted(s, 5)
		s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
		s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
		if got := len(s.db.repositories); got != 1 || s.db.finalizeCalls != 1 {
			t.Fatalf("repositories = %d, finalize calls = %d", got, s.db.finalizeCalls)
		}
	})
}

func TestProvisioningGitHubRateLimit(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.rateLimited = true
	s.github.retryAfter = 30

	reply := s.post("alice", "hw1")
	reply.expectError(t, http.StatusTooManyRequests, "github_rate_limited", true)
	if got := reply.header.Get("Retry-After"); got != "30" {
		t.Fatalf("Retry-After = %q, want 30", got)
	}
	calls := s.github.count("user")
	// The cooldown holds for everyone until GitHub's wait has passed.
	s.post("bob", "hw1").expectError(t, http.StatusTooManyRequests, "github_rate_limited", true)
	if got := s.github.count("user"); got != calls {
		t.Fatalf("asked GitHub during its cooldown (%d -> %d)", calls, got)
	}
	s.github.rateLimited = false
	s.clock.Advance(31 * time.Second)
	s.post("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
}

func TestProvisioningCredentialRejected(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.memberships["alice"] = "active"
	// Generate is refused as forbidden without any rate-limit signal.
	s.github.generateStatus = http.StatusForbidden
	s.post("alice", "hw1").expectError(t, http.StatusBadGateway, "github_credential_rejected", false)
	if a := s.db.attempt(t, "hw1", 1, ""); a.Stage != "failed" || a.ErrorCode != "github_credential_rejected" {
		t.Fatalf("attempt = %+v", a)
	}
}

func TestProvisioningConcurrentClicksGenerateOnce(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.generateDelay = 100 * time.Millisecond

	const clicks = 4
	var wg sync.WaitGroup
	results := make([]provisioningResponse, clicks)
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = s.do(http.MethodPost, "alice", "hw1", nil)
		}(i)
	}
	wg.Wait()
	for i, r := range results {
		if r.status != http.StatusAccepted || r.state != repositoryStateCopying {
			t.Fatalf("click %d: %d %s", i, r.status, r.body)
		}
	}
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("generate calls = %d, want 1", got)
	}
	if got := s.github.count("collaborator:alice"); got != 1 {
		t.Fatalf("collaborator calls = %d, want 1", got)
	}
	if s.db.finalizeCalls != 1 {
		t.Fatalf("finalize calls = %d, want 1", s.db.finalizeCalls)
	}
}

func TestProvisioningConcurrentPollsShareOneCheck(t *testing.T) {
	s := newProvisioningStack(t)
	s.post("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	s.clock.Advance(4 * time.Second)
	heads := s.github.count("head")

	const polls = 6
	var wg sync.WaitGroup
	for i := 0; i < polls; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.do(http.MethodGet, "alice", "hw1", nil).expectState(t, http.StatusAccepted, repositoryStateCopying)
		}()
	}
	wg.Wait()
	if got := s.github.count("head"); got != heads+1 {
		t.Fatalf("%d concurrent polls made %d readiness checks, want 1", polls, got-heads)
	}
}

func TestProvisioningStatusBeforeAnyClick(t *testing.T) {
	s := newProvisioningStack(t)
	s.get("alice", "hw1").expectError(t, http.StatusNotFound, "repository_not_started", false)
	s.get("alice", "plain").expectError(t, http.StatusNotFound, "repository_not_configured", false)
	s.get("alice", "nope").expectError(t, http.StatusNotFound, "repository_not_configured", false)
	s.get("prof", "hw1").expectError(t, http.StatusForbidden, "not_a_student", false)
	if got := s.github.count("generate") + s.github.count("head"); got != 0 {
		t.Fatalf("a GET called GitHub (%d)", got)
	}
	if s.db.rpcCalls["claim_repository_provisioning"] != 0 {
		t.Fatal("a GET claimed an attempt")
	}
}

func TestProvisioningStatusOnInterruptedAttempt(t *testing.T) {
	for _, stage := range []string{"claimed", "generated", "granted"} {
		t.Run(stage, func(t *testing.T) {
			s := newProvisioningStack(t)
			attempt := provisioningAttempt{AssignmentSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter", DestinationName: "hw1-alice", Stage: stage}
			if stage != "claimed" {
				attempt.ProviderRepoID, attempt.ProviderFullName = 5, "course/hw1-alice"
			}
			s.db.seedAttempt(attempt)
			s.get("alice", "hw1").expectError(t, http.StatusConflict, "provisioning_interrupted", true)
			if s.db.finalizeCalls != 0 || s.db.rpcCalls["record_repository_provisioning"] != 0 {
				t.Fatal("a GET wrote to the attempt")
			}
		})
	}
}

// A repository the old course tooling recorded, with no attempt at all, is
// still answered.
func TestProvisioningStatusOnLegacyRepository(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", ready: true})
	s.db.seedRepository(fakeRepositoryRow{AssignmentSlug: "hw1", UserID: 1, ProviderRepoID: 77, ProviderFullName: "course/hw1-alice"})
	reply := s.get("alice", "hw1")
	reply.expectState(t, http.StatusOK, repositoryStateReady)
	if reply.repoURL != "https://github.com/course/hw1-alice" {
		t.Fatalf("repo_url = %q", reply.repoURL)
	}
	// And a click reuses it rather than generating another.
	s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
	if got := s.github.count("generate"); got != 0 {
		t.Fatalf("generated over an existing mapping (%d)", got)
	}
}

func TestProvisioningReadinessBounds(t *testing.T) {
	seed := func(s *provisioningStack, age time.Duration) {
		s.db.users[1].GitHubUserID = 101
		s.db.seedAttempt(provisioningAttempt{
			AssignmentSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter", DestinationName: "hw1-alice",
			Stage: "finalized", ProviderRepoID: 5, ProviderFullName: "course/hw1-alice", CreatedAt: s.clock.Now().Add(-age),
		})
		s.db.seedRepository(fakeRepositoryRow{AssignmentSlug: "hw1", UserID: 1, ProviderRepoID: 5, ProviderFullName: "course/hw1-alice", CreatedAt: s.clock.Now().Add(-age)})
	}

	t.Run("not yet visible within the grace is copying", func(t *testing.T) {
		s := newProvisioningStack(t)
		seed(s, time.Minute)
		s.get("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	})
	t.Run("not visible after the grace is an error", func(t *testing.T) {
		s := newProvisioningStack(t)
		seed(s, 11*time.Minute)
		s.get("alice", "hw1").expectError(t, http.StatusBadGateway, "repository_not_visible", false)
	})
	t.Run("empty after the grace is a copy timeout", func(t *testing.T) {
		s := newProvisioningStack(t)
		seed(s, 11*time.Minute)
		s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", template: "course/hw1-starter"})
		s.get("alice", "hw1").expectError(t, http.StatusBadGateway, "template_copy_timed_out", false)
	})
	t.Run("rate limited poll carries the wait", func(t *testing.T) {
		s := newProvisioningStack(t)
		seed(s, time.Minute)
		s.github.rateLimited, s.github.retryAfter = true, 7
		reply := s.get("alice", "hw1")
		reply.expectError(t, http.StatusTooManyRequests, "github_rate_limited", true)
		if got := reply.header.Get("Retry-After"); got != "7" {
			t.Fatalf("Retry-After = %q, want 7", got)
		}
	})
	t.Run("access lost after it was ready is reported once seen", func(t *testing.T) {
		// A repository the credential can no longer see answers 404 like
		// one that never appeared; past the grace that is the same error.
		s := newProvisioningStack(t)
		seed(s, time.Minute)
		s.github.addRepo(fakeGitHubRepo{fullName: "course/hw1-alice", template: "course/hw1-starter", hidden: true})
		s.get("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
		s.clock.Advance(11 * time.Minute)
		s.get("alice", "hw1").expectError(t, http.StatusBadGateway, "repository_not_visible", false)
	})
}

func TestProvisioningRoutesAbsentWhenDisabled(t *testing.T) {
	mux := http.NewServeMux()
	registerProvisioningRoutes(mux, nil, FetchJWTConfig{}, newSessionManager(true, memstore.New()))
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(method, "/auth/assignments/hw1/repository", nil))
		if recorder.Code != http.StatusNotFound {
			t.Fatalf("%s with provisioning disabled = %d, want 404", method, recorder.Code)
		}
	}
}

func TestProvisioningRequiresASession(t *testing.T) {
	s := newProvisioningStack(t)
	s.get("", "hw1").expectError(t, http.StatusUnauthorized, "unauthenticated", false)
	s.post("", "hw1").expectError(t, http.StatusUnauthorized, "unauthenticated", false)
	if s.db.rpcCalls["claim_repository_provisioning"] != 0 {
		t.Fatal("claimed without a session")
	}
}

func TestProvisioningRefusesCrossSiteClicks(t *testing.T) {
	s := newProvisioningStack(t)
	serverHost := strings.TrimPrefix(s.server.URL, "http://")
	cases := []struct {
		name    string
		headers map[string]string
		want    int
	}{
		{"cross-site fetch", map[string]string{"Sec-Fetch-Site": "cross-site"}, http.StatusForbidden},
		{"same-site subdomain", map[string]string{"Sec-Fetch-Site": "same-site"}, http.StatusForbidden},
		{"no evidence at all", map[string]string{"Sec-Fetch-Site": ""}, http.StatusForbidden},
		{"foreign origin", map[string]string{"Sec-Fetch-Site": "", "Origin": "https://evil.example"}, http.StatusForbidden},
		{"same-origin fetch", map[string]string{"Sec-Fetch-Site": "same-origin"}, http.StatusAccepted},
		{"matching origin only", map[string]string{"Sec-Fetch-Site": "", "Origin": "http://" + serverHost}, http.StatusAccepted},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reply := s.do(http.MethodPost, "alice", "hw1", tc.headers)
			if reply.status != tc.want {
				t.Fatalf("status = %d (%s), want %d", reply.status, reply.body, tc.want)
			}
			if tc.want == http.StatusForbidden && reply.code != "cross_site_request" {
				t.Fatalf("code = %q", reply.code)
			}
		})
	}
	if got := s.github.count("generate"); got != 1 {
		t.Fatalf("generate calls = %d, want 1", got)
	}
}

func TestProvisioningClicksAreRateLimitedPerStudent(t *testing.T) {
	s := newProvisioningStack(t)
	s.github.memberships["alice"] = "pending" // every click stops early, cheaply
	for i := 0; i < provisioningPostsPerMinute; i++ {
		s.post("alice", "hw1").expectState(t, http.StatusOK, repositoryStateNeedsOrgJoin)
	}
	reply := s.post("alice", "hw1")
	reply.expectError(t, http.StatusTooManyRequests, "too_many_requests", true)
	if reply.header.Get("Retry-After") == "" {
		t.Fatal("no Retry-After on the admission refusal")
	}
	// Another student is not affected, and polling is not limited here.
	s.post("bob", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	s.get("alice", "hw1").expectError(t, http.StatusConflict, "provisioning_interrupted", true)
}

func TestProvisioningEligibilityRefusals(t *testing.T) {
	s := newProvisioningStack(t)
	s.post("prof", "hw1").expectError(t, http.StatusForbidden, "not_a_student", false)
	s.post("alice", "plain").expectError(t, http.StatusNotFound, "repository_not_configured", false)
	s.post("carol", "proj").expectError(t, http.StatusForbidden, "no_team", false)
	s.db.assignments["hw1"] = fakeAssignment{template: "course/hw1-starter", closed: true}
	s.post("alice", "hw1").expectError(t, http.StatusForbidden, "assignment_closed", false)
	if got := s.github.count("generate"); got != 0 {
		t.Fatalf("generate calls = %d, want 0", got)
	}
	// Other methods are refused with an Allow header.
	reply := s.do(http.MethodDelete, "alice", "hw1", nil)
	if reply.status != http.StatusMethodNotAllowed || reply.header.Get("Allow") != "GET, POST" {
		t.Fatalf("DELETE = %d Allow=%q", reply.status, reply.header.Get("Allow"))
	}
}

func TestProvisioningErrorBodiesNeverCarryTheToken(t *testing.T) {
	// The stack's do() fails any response that contains the token; this
	// drives the paths that log or return GitHub failures to make sure
	// they all go through it.
	s := newProvisioningStack(t)
	s.github.generateStatus = http.StatusInternalServerError
	s.post("alice", "hw1")
	s.github.generateStatus = http.StatusForbidden
	s.post("alice", "hw1")
	s.github.rateLimited = true
	s.post("alice", "hw1")
	s.get("alice", "hw1")
}

func TestIsSameOriginRequest(t *testing.T) {
	cases := []struct {
		fetchSite string
		origin    string
		host      string
		want      bool
	}{
		{"same-origin", "", "example.edu", true},
		{"none", "", "example.edu", true},
		{"same-site", "https://example.edu", "example.edu", false},
		{"cross-site", "https://example.edu", "example.edu", false},
		{"", "https://example.edu", "example.edu", true},
		{"", "https://EXAMPLE.edu", "example.edu", true},
		{"", "https://example.edu:8443", "example.edu", false},
		{"", "https://evil.example", "example.edu", false},
		{"", "https://example.edu/", "example.edu", false},
		{"", "null", "example.edu", false},
		{"", "", "example.edu", false},
	}
	for _, tc := range cases {
		t.Run(fmt.Sprintf("site=%q origin=%q", tc.fetchSite, tc.origin), func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/auth/assignments/hw1/repository", nil)
			r.Host = tc.host
			// Behind Caddy the request is https by X-Forwarded-Proto.
			r.Header.Set("X-Forwarded-Proto", "https")
			if tc.fetchSite != "" {
				r.Header.Set("Sec-Fetch-Site", tc.fetchSite)
			}
			if tc.origin != "" {
				r.Header.Set("Origin", tc.origin)
			}
			if got := isSameOriginRequest(r); got != tc.want {
				t.Fatalf("isSameOriginRequest = %v, want %v", got, tc.want)
			}
		})
	}

	// The scheme is part of the origin: an http origin is not the https site.
	schemes := []struct {
		name           string
		forwardedProto string
		tls            bool
		origin         string
		want           bool
	}{
		{"http origin against forwarded https", "https", false, "http://example.edu", false},
		{"https origin against forwarded https", "https", false, "https://example.edu", true},
		{"http origin against tls", "", true, "http://example.edu", false},
		{"https origin against tls", "", true, "https://example.edu", true},
		{"https origin against plain http", "", false, "https://example.edu", false},
		{"http origin against plain http", "", false, "http://example.edu", true},
	}
	for _, tc := range schemes {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/auth/assignments/hw1/repository", nil)
			r.Host = "example.edu"
			r.Header.Set("Origin", tc.origin)
			if tc.forwardedProto != "" {
				r.Header.Set("X-Forwarded-Proto", tc.forwardedProto)
			}
			if tc.tls {
				r.TLS = &tls.ConnectionState{}
			}
			if got := isSameOriginRequest(r); got != tc.want {
				t.Fatalf("isSameOriginRequest = %v, want %v", got, tc.want)
			}
		})
	}
}
