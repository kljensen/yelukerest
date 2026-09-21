package main

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// The repositories page against the provisioning stack: what it renders
// for whom, that rendering it touches neither GitHub nor the attempt
// table, and that its script posts on a click and nothing else.

type pageResponse struct {
	status   int
	header   http.Header
	location string
	body     string
}

func (s *provisioningStack) page(netID string, query string) pageResponse {
	s.t.Helper()
	client := s.clientFor(netID)
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Get(s.server.URL + repositoriesPagePath + query)
	if err != nil {
		s.t.Fatalf("GET %s%s: %v", repositoriesPagePath, query, err)
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(response.Body)
	if strings.Contains(string(raw), provisioningTestToken) {
		s.t.Fatalf("the page carries the GitHub token: %s", raw)
	}
	return pageResponse{status: response.StatusCode, header: response.Header, location: response.Header.Get("Location"), body: string(raw)}
}

func (r pageResponse) expectContains(t *testing.T, wants ...string) {
	t.Helper()
	if r.status != http.StatusOK {
		t.Fatalf("page = %d %s", r.status, r.body)
	}
	for _, want := range wants {
		if !strings.Contains(r.body, want) {
			t.Fatalf("page lacks %q:\n%s", want, r.body)
		}
	}
}

func (r pageResponse) expectLacks(t *testing.T, unwanted ...string) {
	t.Helper()
	for _, s := range unwanted {
		if strings.Contains(r.body, s) {
			t.Fatalf("page has %q:\n%s", s, r.body)
		}
	}
}

func TestRepositoriesPageRendersTheSections(t *testing.T) {
	s := newProvisioningStack(t)
	now := s.clock.Now()
	s.db.users[1].GitHubVerifiedAt = &now

	page := s.page("alice", "")
	page.expectContains(t,
		`<section id="account">`, "Connected as <strong>alice</strong>", `<span class="badge">verified</span>`,
		`<section id="templates">`,
		`<li class="template" data-slug="hw1" data-state="" data-action="/auth/repositories/hw1">`, "Homework 1 starter", "Go, with the tests wired up",
		`<form class="create" method="POST" action="/auth/repositories/hw1"><button type="submit">Create</button></form>`,
		`data-slug="proj"`, "Project starter", `<span class="badge">team</span>`, `action="/auth/repositories/proj"`,
		`<section id="repositories">`, `<p id="no-repositories">None yet.</p>`,
		`<script src="`+repositoriesScriptPath+`">`, "<noscript>",
	)
	// The inactive template is not offered.
	page.expectLacks(t, "Retired starter", `data-slug="plain"`)
	if csp := page.header.Get("Content-Security-Policy"); !strings.Contains(csp, "script-src 'self'") || !strings.Contains(csp, "connect-src 'self'") || !strings.Contains(csp, "style-src 'self'") {
		t.Fatalf("CSP = %q", csp)
	}
	if got := page.header.Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q", got)
	}
	// Without the join flow, an unlinked student is told to be invited;
	// a linked but unverified one is shown as connected, with no button.
	s.page("carol", "").expectContains(t, "No GitHub account is connected yet. Ask the course staff", "accept the invitation")
	unverified := s.page("bob", "")
	unverified.expectContains(t, "Connected as <strong>bob</strong>")
	unverified.expectLacks(t, "verified", "Connect your GitHub account", "Verify it and join")

	// With the join flow, the button appears for the unlinked and the
	// unverified, pointing at the landing page returning here.
	s.handler.github.join = &githubJoinApp{clientID: "x", clientSecret: "y"}
	joinForm := `<form method="GET" action="` + githubJoinLandingPath + `"><input type="hidden" name="next" value="` + repositoriesPagePath + `">`
	s.page("carol", "").expectContains(t, joinForm+`<button type="submit">Connect your GitHub account</button>`)
	s.page("bob", "").expectContains(t, "Connected as <strong>bob</strong>", joinForm+`<button type="submit">Verify it and join the course organization</button>`)
	s.page("alice", "").expectLacks(t, joinForm)

	// Rendering called GitHub for nothing and claimed nothing.
	if got := s.github.count("generate") + s.github.count("user") + s.github.count("membership") + s.github.count("head"); got != 0 {
		t.Fatalf("rendering the page called GitHub (%d calls)", got)
	}
	for _, rpc := range []string{"claim_repository_provisioning", "record_repository_provisioning", "finalize_repository_provisioning", "touch_repository_provisioning_readiness"} {
		if got := s.db.rpcCalls[rpc]; got != 0 {
			t.Fatalf("rendering the page called %s (%d)", rpc, got)
		}
	}
	if s.db.viewReads["repository_templates"] == 0 || s.db.viewReads["my_repositories"] == 0 || s.db.viewReads["repository_provisionings"] == 0 {
		t.Fatalf("view reads = %v", s.db.viewReads)
	}
}

func TestRepositoriesPageFiltersTemplatesByTeam(t *testing.T) {
	s := newProvisioningStack(t)
	// carol has no team: the team template is not offered to her.
	page := s.page("carol", "")
	page.expectContains(t, `data-slug="hw1"`)
	page.expectLacks(t, `data-slug="proj"`)
	// prof sees the templates and no buttons.
	prof := s.page("prof", "")
	prof.expectContains(t, "Only students create repositories here.", `data-slug="hw1"`)
	prof.expectLacks(t, `<form class="create"`)
}

func TestRepositoriesPageShowsEachRowState(t *testing.T) {
	s := newProvisioningStack(t)
	s.db.users[1].GitHubUserID = 101
	// hw1: recorded and ready. proj: recorded, still copying. hw2: failed.
	// hw3: interrupted.
	s.db.templates["hw2"] = fakeTemplate{label: "Homework 2 starter", template: "course/hw2-starter"}
	s.db.templates["hw3"] = fakeTemplate{label: "Homework 3 starter", template: "course/hw3-starter"}
	now := s.clock.Now()
	s.db.seedAttempt(provisioningAttempt{TemplateSlug: "hw1", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw1-starter", DestinationName: "hw1-alice", Stage: "finalized", ProviderRepoID: 5, ProviderFullName: "course/hw1-alice", ReadyAt: &now})
	s.db.seedRepository(fakeRepositoryRow{TemplateSlug: "hw1", UserID: 1, ProviderRepoID: 5, ProviderFullName: "course/hw1-alice"})
	s.db.seedAttempt(provisioningAttempt{TemplateSlug: "proj", IsTeam: true, TeamNickname: "alpha", InitiatedByUserID: 2, TemplateFullName: "course/proj-starter", DestinationName: "proj-alpha", Stage: "finalized", ProviderRepoID: 6, ProviderFullName: "course/proj-alpha"})
	s.db.seedRepository(fakeRepositoryRow{TemplateSlug: "proj", IsTeam: true, TeamNickname: "alpha", ProviderRepoID: 6, ProviderFullName: "course/proj-alpha"})
	s.db.seedAttempt(provisioningAttempt{TemplateSlug: "hw2", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw2-starter", DestinationName: "hw2-alice", Stage: "failed", ErrorCode: "name_taken"})
	s.db.seedAttempt(provisioningAttempt{TemplateSlug: "hw3", UserID: 1, InitiatedByUserID: 1, TemplateFullName: "course/hw3-starter", DestinationName: "hw3-alice", Stage: "generated", ProviderRepoID: 7, ProviderFullName: "course/hw3-alice"})

	page := s.page("alice", "")
	page.expectContains(t,
		`data-slug="hw1" data-state="ready"`, `Ready: <a href="https://github.com/course/hw1-alice">https://github.com/course/hw1-alice</a>`,
		`data-slug="proj" data-state="copying"`, `Preparing your repository… <a href="https://github.com/course/proj-alpha">`,
		`data-slug="hw2" data-state="failed"`, "Could not create it last time (name_taken).", `action="/auth/repositories/hw2"><button type="submit">Try again</button>`,
		`data-slug="hw3" data-state="interrupted"`, "A previous attempt was interrupted.", `action="/auth/repositories/hw3"><button type="submit">Try again</button>`,
		`<li data-slug="hw1"><a href="https://github.com/course/hw1-alice">course/hw1-alice</a> — Homework 1 starter</li>`,
		`<li data-slug="proj"><a href="https://github.com/course/proj-alpha">course/proj-alpha</a> — Project starter</li>`,
	)
	page.expectLacks(t, `action="/auth/repositories/hw1"><button`, `action="/auth/repositories/proj"><button`, "no-repositories")
	// A teammate sees the team repository through their own session; a
	// student on another team does not.
	s.page("bob", "").expectContains(t, `data-slug="proj" data-state="copying"`, `<li data-slug="proj">`)
	s.db.users[3].TeamNickname = "beta"
	s.page("carol", "").expectContains(t, `data-slug="proj" data-state=""`)
	// Nothing above asked GitHub anything.
	if got := s.github.count("head") + s.github.count("get_repo"); got != 0 {
		t.Fatalf("rendering the page called GitHub (%d calls)", got)
	}
}

func TestRepositoriesPageNotices(t *testing.T) {
	s := newProvisioningStack(t)
	cases := map[string]string{
		"?github_join=ok":                            "Your GitHub account is connected and in the course organization.",
		"?github_join=denied":                        "You cancelled the GitHub authorization; nothing changed.",
		"?github_join=error%3Agithub_unavailable":    "Connecting your GitHub account failed (github_unavailable). Try again in a moment.",
		"?github_join=error%3Agithub_identity_taken": "Connecting your GitHub account failed (github_identity_taken). Contact the course staff.",
		"?template=hw1&result=copying":               "hw1: your repository is being prepared; reload in a moment.",
		"?template=hw1&result=needs_org_join":        "hw1: your GitHub account is not in the course organization yet (above).",
		"?template=hw1&result=name_taken":            "hw1: could not create the repository (name_taken).",
	}
	for query, want := range cases {
		s.page("alice", query).expectContains(t, `<p class="notice" id="notice">`+want+`</p>`)
	}
	// Anything not shaped like a marker is dropped, not echoed.
	for _, query := range []string{"?github_join=%3Cb%3Ehi", "?template=hw1&result=%3Cb%3E", "?template=%3Cb%3E&result=ready", "?result=ready"} {
		s.page("alice", query).expectLacks(t, `id="notice"`, "<b>", "&lt;b&gt;")
	}
}

func TestRepositoriesPageRequiresASession(t *testing.T) {
	s := newProvisioningStack(t)
	visitor := s.page("", "")
	if visitor.status != http.StatusFound || visitor.location != githubJoinLoginPath+"?next="+url.QueryEscape(repositoriesPagePath) {
		t.Fatalf("signed-out page = %d %q", visitor.status, visitor.location)
	}
	stranger := s.page("stranger", "")
	if stranger.status != http.StatusForbidden || !strings.Contains(stranger.body, "not_enrolled") {
		t.Fatalf("unenrolled page = %d %s", stranger.status, stranger.body)
	}
}

// The script posts from the submit handler and nowhere else, so a link to
// the page creates nothing by itself; it disables the button in flight,
// polls the status route every three seconds while copying, and gives up
// polling after two minutes with a Check again button.
func TestRepositoriesScriptIsClickOnly(t *testing.T) {
	s := newProvisioningStack(t)
	client := s.clientFor("alice")
	response, err := client.Get(s.server.URL + repositoriesScriptPath)
	if err != nil {
		t.Fatalf("GET script: %v", err)
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(response.Body)
	js := string(raw)
	if response.StatusCode != http.StatusOK || !strings.HasPrefix(response.Header.Get("Content-Type"), "text/javascript") {
		t.Fatalf("script = %d %q", response.StatusCode, response.Header.Get("Content-Type"))
	}
	handlerStart := strings.Index(js, `form.addEventListener("submit"`)
	if handlerStart < 0 {
		t.Fatalf("script registers no submit handler:\n%s", js)
	}
	if postAt := strings.Index(js, `method: "POST"`); postAt < handlerStart || strings.Count(js, `method: "POST"`) != 1 {
		t.Fatalf("script posts outside the submit handler:\n%s", js)
	}
	for _, banned := range []string{"submit()", "requestSubmit(", "DOMContentLoaded", `addEventListener("load"`, "innerHTML"} {
		if strings.Contains(js, banned) {
			t.Fatalf("script has %q:\n%s", banned, js)
		}
	}
	for _, want := range []string{"button.disabled = true", "POLL_INTERVAL_MS = 3000", "POLL_LIMIT_MS = 120000", `"Check again"`, `method: "GET"`, `"Retry-After"`, `"Accept": "application/json"`} {
		if !strings.Contains(js, want) {
			t.Fatalf("script lacks %q:\n%s", want, js)
		}
	}
}

// The status route the script polls, driven the way the script drives it:
// a click, then polls, then ready; the readiness stamp is the only write.
func TestRepositoriesPagePollingSequence(t *testing.T) {
	s := newProvisioningStack(t)
	s.post("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	s.page("alice", "").expectContains(t, `data-slug="hw1" data-state="copying"`)
	s.clock.Advance(4 * time.Second)
	s.get("alice", "hw1").expectState(t, http.StatusAccepted, repositoryStateCopying)
	s.github.setReady("course/hw1-alice", true)
	s.clock.Advance(4 * time.Second)
	s.get("alice", "hw1").expectState(t, http.StatusOK, repositoryStateReady)
	s.page("alice", "").expectContains(t, `data-slug="hw1" data-state="ready"`, `<li data-slug="hw1">`)
	if s.db.rpcCalls["record_repository_provisioning"] != 2 || s.db.finalizeCalls != 1 {
		t.Fatalf("writes: record=%d finalize=%d", s.db.rpcCalls["record_repository_provisioning"], s.db.finalizeCalls)
	}
}
