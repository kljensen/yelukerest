package main

// Unit tests for the curated read tools (issue #266) against a fake PostgREST:
// query paths and parameters (eq filters, select= embeds), Authorization
// forwarding, output shaping and truncation, scope gating, and error mapping.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// ---- fake PostgREST ----

type pgRequest struct {
	method string
	path   string
	query  url.Values
	auth   string
	prefer []string
	accept string
	body   string
}

type pgResponse struct {
	status int
	body   string
}

// fakePostgREST records every request (method, path, query, headers, body)
// and responds from two maps: method-specific responses ("POST /x") win over
// path-only responses ("/x", used by the GET-only read tools).
type fakePostgREST struct {
	mu        sync.Mutex
	requests  []pgRequest
	responses map[string]pgResponse
	server    *httptest.Server
}

func newFakePostgREST(t *testing.T) *fakePostgREST {
	t.Helper()
	fake := &fakePostgREST{responses: map[string]pgResponse{}}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestBody, _ := io.ReadAll(r.Body)
		fake.mu.Lock()
		fake.requests = append(fake.requests, pgRequest{
			method: r.Method,
			path:   r.URL.Path,
			query:  r.URL.Query(),
			auth:   r.Header.Get("Authorization"),
			prefer: r.Header.Values("Prefer"),
			accept: r.Header.Get("Accept"),
			body:   string(requestBody),
		})
		resp, ok := fake.responses[r.Method+" "+r.URL.Path]
		if !ok {
			resp, ok = fake.responses[r.URL.Path]
		}
		fake.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"message":"unhandled path in fake PostgREST"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.status)
		_, _ = io.WriteString(w, resp.body)
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakePostgREST) respond(path string, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.responses[path] = pgResponse{status: http.StatusOK, body: body}
}

func (f *fakePostgREST) respondStatus(path string, status int, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.responses[path] = pgResponse{status: status, body: body}
}

// respondMethod registers a response for one method+path pair, taking
// precedence over path-only responses.
func (f *fakePostgREST) respondMethod(method string, path string, status int, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.responses[method+" "+path] = pgResponse{status: status, body: body}
}

func (f *fakePostgREST) recorded() []pgRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]pgRequest(nil), f.requests...)
}

func (f *fakePostgREST) client(t *testing.T) *postgrestClient {
	t.Helper()
	parsed, err := url.Parse(f.server.URL)
	if err != nil {
		t.Fatalf("parse fake PostgREST URL: %v", err)
	}
	return &postgrestClient{
		baseURL:    parsed,
		httpClient: &http.Client{Timeout: 5 * time.Second},
	}
}

func (f *fakePostgREST) deps(t *testing.T) *toolDeps {
	t.Helper()
	return &toolDeps{
		logger:    slog.New(slog.NewTextHandler(io.Discard, nil)),
		postgrest: f.client(t),
	}
}

// readToolRequest builds a CallToolRequest carrying the TokenInfo the
// streamable HTTP transport hands tool handlers. It packs the identity
// directly rather than verifying a bearer token, because /mcp accepts OAuth
// tokens only (issue #322) and these tests are about what a tool does once
// the caller is known; who gets in is jwt_test.go's and hydra_test.go's
// subject.
//
// The claims are those of the internal credential api.issue_user_jwt_for_mcp
// mints, and the returned token is that credential — what a tool must forward
// to PostgREST. The scopes are the ones a student's consent grants for reads:
// since issue #324 a caller carrying no recognised scope is denied every
// tool, so a fixture caller has to carry them. Tests that need a different
// grant overwrite the claim.
func readToolRequest(t *testing.T, mutate func(map[string]any)) (*mcp.CallToolRequest, string) {
	t.Helper()
	claims := currentClaims()
	claims["netid"] = "abc123"
	claims["scopes"] = []any{"course:read", "grades:read", "submissions:read"}
	if mutate != nil {
		mutate(claims)
	}
	token := signTestToken(t, hs256Header(), claims, testSecret)
	info := tokenInfoFromIdentity(identityForClaims(t, claims, token))
	return &mcp.CallToolRequest{Extra: &mcp.RequestExtra{TokenInfo: info}}, token
}

// identityForClaims builds the identity an OAuth caller presents to tools:
// the verified claims, plus the deferred exchange that is now the only route
// to a forwardable credential (identity.forwardableToken). Claims are
// round-tripped through JSON so the production claim readers see exactly the
// types a decoded token gives them.
//
// The exchange's cache is primed with token, so the fixture mints nothing and
// needs no upstream; exchange_test.go covers the mint itself. A fixture
// caller whose exchange would miss that cache — no netid, or no scopes — is
// refused by tokenFor before it reaches the (nil) PostgREST client, which is
// the same refusal production gives.
func identityForClaims(t *testing.T, claims map[string]any, token string) *identity {
	t.Helper()
	encoded, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal claims: %v", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	decoded := map[string]any{}
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatalf("decode claims: %v", err)
	}
	exp, err := numericDateClaim(decoded, "exp")
	if err != nil {
		t.Fatalf("exp claim: %v", err)
	}
	subject, _ := decoded["sub"].(string)
	userID, _ := strings.CutPrefix(subject, "user:")
	netID, _ := decoded["netid"].(string)
	role, _ := decoded["role"].(string)
	jti, _ := decoded["jti"].(string)
	id := &identity{
		Subject:   subject,
		UserID:    userID,
		NetID:     netID,
		Role:      role,
		JTI:       jti,
		ExpiresAt: time.Unix(exp, 0),
		Scopes:    scopesFromClaims(decoded),
		External:  true,
	}
	request := exchangeRequest{netID: id.NetID, scopes: id.Scopes, outerExp: id.ExpiresAt}
	exchanger := newTokenExchanger(nil, "service-token")
	// Only the token is primed: leaving the minted userid, netid and role
	// empty keeps forwardableToken from overwriting what the claims say, so a
	// test that mutates a claim still sees its mutation.
	key := exchangeCacheKey(request.netID, request.external.ClientID, request.external.IssuedAt, request.scopes)
	exchanger.cache[key] = exchangeCacheEntry{minted: mintedToken{token: token}, notAfter: id.ExpiresAt}
	id.exchange = &pendingExchange{exchanger: exchanger, request: request}
	return id
}

// ---- fixtures ----

const (
	fixtureUserRows = `[{"id":42,"netid":"abc123","name":"Alice Ok","known_as":"Al","nickname":"fuzzy-bunny","team_nickname":"team-one","role":"student"}]`

	fixtureUserRowsNoTeam = `[{"id":42,"netid":"abc123","name":"Alice Ok","known_as":"Al","nickname":"fuzzy-bunny","team_nickname":null,"role":"student"}]`

	fixtureAssignments = `[{"slug":"proj1","title":"Project 1","points_possible":10,"is_team":false,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00"}]`

	fixtureAssignmentDetail = `[{"slug":"proj1","title":"Project 1","body":"Do the thing","is_markdown":true,"points_possible":10,"is_team":false,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00","fields":[{"slug":"repo-url","label":"Repo URL","help":"paste it","placeholder":"https://...","is_url":true,"is_multiline":false,"display_order":0,"pattern":".*","example":"https://example.com"}]}]`

	fixtureAssignmentDistribution = `[{"count":5,"average":8.2,"min":4,"max":10,"points_possible":10,"stddev":1.5}]`

	fixtureSubmissions = `[{"id":7,"assignment_slug":"proj1","is_team":true,"user_id":null,"team_nickname":"team-one","submitter_user_id":43,"created_at":"2026-08-02T00:00:00+00:00","updated_at":"2026-08-02T00:00:00+00:00","fields":[{"assignment_field_slug":"repo-url","body":"https://example.com/x","submitter_user_id":43,"created_at":"2026-08-02T00:00:00+00:00","updated_at":"2026-08-02T00:00:00+00:00"}]}]`

	fixtureQuizzes = `[{"id":1,"meeting_slug":"intro","points_possible":5,"is_draft":false,"is_open":false,"open_at":"2026-08-20T00:00:00+00:00","closed_at":"2026-08-25T00:00:00+00:00","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00"}]`

	fixtureQuizGrades = `[{"quiz_id":1,"points":4,"points_possible":5,"description":"good work","created_at":"2026-08-26T00:00:00+00:00","updated_at":"2026-08-26T00:00:00+00:00"}]`

	fixtureQuizDistributions = `[{"quiz_id":1,"count":10,"average":3.5,"min":1,"max":5,"points_possible":5,"stddev":0.8}]`

	fixtureGrades = `[{"snapshot_slug":"midterm","points":88,"description":"solid","created_at":"2026-10-15T00:00:00+00:00","updated_at":"2026-10-15T00:00:00+00:00"}]`

	fixtureSnapshotDistributions = `[{"snapshot_slug":"midterm","count":12,"average":80,"min":60,"max":95,"stddev":9.5,"grades":[60,75,95]}]`

	fixtureMeetings = `[{"slug":"intro","title":"Introduction","summary":"hello","begins_at":"2026-08-27T13:00:00+00:00","duration":"01:15:00","meeting_type":"lecture","is_draft":false,"created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00"}]`

	fixtureEngagements = `[{"user_id":42,"meeting_slug":"intro","participation":"attended","created_at":"2026-08-27T00:00:00+00:00","updated_at":"2026-08-27T00:00:00+00:00"}]`
)

// ---- query paths, filters, embeds, auth forwarding, output shaping ----

type wantRequest struct {
	path   string
	query  map[string]string
	absent []string // query keys that must not be present
}

func TestReadToolsQueriesAndAuthForwarding(t *testing.T) {
	ctx := context.Background()
	tests := []struct {
		name  string
		setup func(f *fakePostgREST)
		call  func(d *toolDeps, req *mcp.CallToolRequest) (any, error)
		want  []wantRequest
		check func(t *testing.T, out any)
	}{
		{
			name:  "whoami",
			setup: func(f *fakePostgREST) { f.respond("/users", fixtureUserRows) },
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.whoami(ctx, req, nil)
				return out, err
			},
			want: []wantRequest{{
				path: "/users",
				query: map[string]string{
					"id":     "eq.42",
					"select": "id,netid,name,known_as,nickname,team_nickname,role",
				},
			}},
			check: func(t *testing.T, out any) {
				got := out.(whoamiOutput)
				if got.Subject != "user:42" || got.UserID != "42" {
					t.Fatalf("identity = %+v", got)
				}
				if got.NetID != "abc123" {
					t.Fatalf("netid = %q", got.NetID)
				}
				if got.Nickname != "fuzzy-bunny" || got.TeamNickname != "team-one" || got.DBRole != "student" {
					t.Fatalf("db profile = %+v", got)
				}
			},
		},
		{
			name:  "list_assignments",
			setup: func(f *fakePostgREST) { f.respond("/assignments", fixtureAssignments) },
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.listAssignments(ctx, req, nil)
				return out, err
			},
			want: []wantRequest{{
				path: "/assignments",
				query: map[string]string{
					"select": "slug,title,points_possible,is_team,is_draft,is_open,closed_at,created_at,updated_at",
					"order":  "closed_at.asc,slug.asc",
				},
			}},
			check: func(t *testing.T, out any) {
				got := out.(listAssignmentsOutput)
				if got.TotalCount != 1 || got.Truncated || len(got.Assignments) != 1 {
					t.Fatalf("output = %+v", got)
				}
				if got.Assignments[0].Slug != "proj1" || !got.Assignments[0].IsOpen {
					t.Fatalf("assignment = %+v", got.Assignments[0])
				}
			},
		},
		{
			name: "get_assignment",
			setup: func(f *fakePostgREST) {
				f.respond("/assignments", fixtureAssignmentDetail)
				f.respond("/assignment_grade_distributions", fixtureAssignmentDistribution)
			},
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.getAssignment(ctx, req, getAssignmentInput{Slug: "proj1"})
				return out, err
			},
			want: []wantRequest{
				{
					path: "/assignments",
					query: map[string]string{
						"slug":         "eq.proj1",
						"select":       "slug,title,body,is_markdown,points_possible,is_team,is_draft,is_open,closed_at,created_at,updated_at,fields:assignment_fields(slug,label,help,placeholder,is_url,is_multiline,display_order,pattern,example)",
						"fields.order": "display_order.asc,slug.asc",
					},
				},
				{
					path: "/assignment_grade_distributions",
					query: map[string]string{
						"assignment_slug": "eq.proj1",
						"select":          "count,average,min,max,points_possible,stddev",
					},
				},
			},
			check: func(t *testing.T, out any) {
				got := out.(getAssignmentOutput)
				if got.Slug != "proj1" || got.Body != "Do the thing" || got.BodyTruncated {
					t.Fatalf("assignment = %+v", got)
				}
				if len(got.Fields) != 1 || got.Fields[0].Slug != "repo-url" || !got.Fields[0].IsURL {
					t.Fatalf("fields = %+v", got.Fields)
				}
				if got.GradeDistribution == nil || got.GradeDistribution.Count != 5 {
					t.Fatalf("distribution = %+v", got.GradeDistribution)
				}
				if got.GradeDistribution.Grades != nil {
					t.Fatal("individual scores must not appear in get_assignment")
				}
			},
		},
		{
			name: "get_my_submissions with team",
			setup: func(f *fakePostgREST) {
				f.respond("/users", fixtureUserRows)
				f.respond("/assignment_submissions", fixtureSubmissions)
			},
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.getMySubmissions(ctx, req, getMySubmissionsInput{})
				return out, err
			},
			want: []wantRequest{
				{path: "/users", query: map[string]string{"id": "eq.42", "select": "id,team_nickname"}},
				{
					path: "/assignment_submissions",
					query: map[string]string{
						"or":     "(user_id.eq.42,team_nickname.eq.team-one)",
						"select": "id,assignment_slug,is_team,user_id,team_nickname,submitter_user_id,created_at,updated_at,fields:assignment_field_submissions(assignment_field_slug,body,submitter_user_id,created_at,updated_at)",
						"order":  "assignment_slug.asc,id.asc",
					},
				},
			},
			check: func(t *testing.T, out any) {
				got := out.(getMySubmissionsOutput)
				if got.TotalCount != 1 || len(got.Submissions) != 1 {
					t.Fatalf("output = %+v", got)
				}
				sub := got.Submissions[0]
				if !sub.IsTeam || sub.TeamNickname != "team-one" || sub.SubmitterUserID != 43 {
					t.Fatalf("submission = %+v", sub)
				}
				if len(sub.Fields) != 1 || sub.Fields[0].SubmitterUserID != 43 {
					t.Fatalf("field provenance = %+v", sub.Fields)
				}
			},
		},
		{
			name: "get_my_submissions without team filters by user only",
			setup: func(f *fakePostgREST) {
				f.respond("/users", fixtureUserRowsNoTeam)
				f.respond("/assignment_submissions", "[]")
			},
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.getMySubmissions(ctx, req, getMySubmissionsInput{AssignmentSlug: "proj1"})
				return out, err
			},
			want: []wantRequest{
				{path: "/users", query: map[string]string{"id": "eq.42"}},
				{
					path: "/assignment_submissions",
					query: map[string]string{
						"user_id":         "eq.42",
						"assignment_slug": "eq.proj1",
					},
					absent: []string{"or"},
				},
			},
			check: func(t *testing.T, out any) {
				got := out.(getMySubmissionsOutput)
				if got.TotalCount != 0 || got.Truncated {
					t.Fatalf("output = %+v", got)
				}
			},
		},
		{
			name:  "list_quizzes",
			setup: func(f *fakePostgREST) { f.respond("/quizzes", fixtureQuizzes) },
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.listQuizzes(ctx, req, nil)
				return out, err
			},
			want: []wantRequest{{
				path: "/quizzes",
				query: map[string]string{
					"select": "id,meeting_slug,points_possible,is_draft,is_open,open_at,closed_at,created_at,updated_at",
					"order":  "open_at.asc,id.asc",
				},
			}},
			check: func(t *testing.T, out any) {
				got := out.(listQuizzesOutput)
				if got.TotalCount != 1 || got.Quizzes[0].MeetingSlug != "intro" {
					t.Fatalf("output = %+v", got)
				}
			},
		},
		{
			name: "get_my_quiz_grades",
			setup: func(f *fakePostgREST) {
				f.respond("/quiz_grades", fixtureQuizGrades)
				f.respond("/quiz_grade_distributions", fixtureQuizDistributions)
			},
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.getMyQuizGrades(ctx, req, nil)
				return out, err
			},
			want: []wantRequest{
				{
					path: "/quiz_grades",
					query: map[string]string{
						"user_id": "eq.42",
						"select":  "quiz_id,points,points_possible,description,created_at,updated_at",
						"order":   "quiz_id.asc",
					},
				},
				{
					path: "/quiz_grade_distributions",
					query: map[string]string{
						"select": "quiz_id,count,average,min,max,points_possible,stddev",
					},
				},
			},
			check: func(t *testing.T, out any) {
				got := out.(getMyQuizGradesOutput)
				if got.TotalCount != 1 || got.QuizGrades[0].Points != 4 {
					t.Fatalf("output = %+v", got)
				}
				dist := got.QuizGrades[0].ClassDistribution
				if dist == nil || dist.Count != 10 || dist.Grades != nil {
					t.Fatalf("distribution = %+v", dist)
				}
			},
		},
		{
			name: "get_my_grades",
			setup: func(f *fakePostgREST) {
				f.respond("/grades", fixtureGrades)
				f.respond("/grade_snapshot_distributions", fixtureSnapshotDistributions)
			},
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.getMyGrades(ctx, req, nil)
				return out, err
			},
			want: []wantRequest{
				{
					path: "/grades",
					query: map[string]string{
						"user_id": "eq.42",
						"select":  "snapshot_slug,points,description,created_at,updated_at",
						"order":   "snapshot_slug.asc",
					},
				},
				{
					path: "/grade_snapshot_distributions",
					query: map[string]string{
						"select": "snapshot_slug,count,average,min,max,stddev,grades",
					},
				},
			},
			check: func(t *testing.T, out any) {
				got := out.(getMyGradesOutput)
				if got.TotalCount != 1 || got.Grades[0].Points != 88 {
					t.Fatalf("output = %+v", got)
				}
				dist := got.Grades[0].ClassDistribution
				if dist == nil || dist.Count != 12 {
					t.Fatalf("distribution = %+v", dist)
				}
				if len(dist.Grades) != 3 {
					t.Fatalf("dedicated grades tool should include class scores, got %+v", dist.Grades)
				}
			},
		},
		{
			name:  "list_meetings",
			setup: func(f *fakePostgREST) { f.respond("/meetings", fixtureMeetings) },
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.listMeetings(ctx, req, nil)
				return out, err
			},
			want: []wantRequest{{
				path: "/meetings",
				query: map[string]string{
					"select": "slug,title,summary,begins_at,duration,meeting_type,is_draft,created_at,updated_at",
					"order":  "begins_at.asc,slug.asc",
				},
			}},
			check: func(t *testing.T, out any) {
				got := out.(listMeetingsOutput)
				if got.TotalCount != 1 || got.Meetings[0].MeetingType != "lecture" {
					t.Fatalf("output = %+v", got)
				}
			},
		},
		{
			name:  "get_my_engagements",
			setup: func(f *fakePostgREST) { f.respond("/engagements", fixtureEngagements) },
			call: func(d *toolDeps, req *mcp.CallToolRequest) (any, error) {
				_, out, err := d.getMyEngagements(ctx, req, nil)
				return out, err
			},
			want: []wantRequest{{
				path: "/engagements",
				query: map[string]string{
					"user_id": "eq.42",
					"select":  "meeting_slug,participation,created_at,updated_at",
					"order":   "meeting_slug.asc",
				},
			}},
			check: func(t *testing.T, out any) {
				got := out.(getMyEngagementsOutput)
				if got.TotalCount != 1 || got.Engagements[0].Participation != "attended" {
					t.Fatalf("output = %+v", got)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			tt.setup(fake)
			deps := fake.deps(t)
			req, token := readToolRequest(t, nil)

			out, err := tt.call(deps, req)
			if err != nil {
				t.Fatalf("tool error: %v", err)
			}

			recorded := fake.recorded()
			if len(recorded) != len(tt.want) {
				t.Fatalf("PostgREST requests = %d, want %d: %+v", len(recorded), len(tt.want), recorded)
			}
			for i, want := range tt.want {
				got := recorded[i]
				if got.path != want.path {
					t.Fatalf("request %d path = %q, want %q", i, got.path, want.path)
				}
				if got.auth != "Bearer "+token {
					t.Fatalf("request %d did not forward the caller's bearer token", i)
				}
				for key, value := range want.query {
					if got.query.Get(key) != value {
						t.Fatalf("request %d query %s = %q, want %q", i, key, got.query.Get(key), value)
					}
				}
				for _, key := range want.absent {
					if got.query.Has(key) {
						t.Fatalf("request %d query must not include %s", i, key)
					}
				}
			}
			if tt.check != nil {
				tt.check(t, out)
			}
		})
	}
}

// ---- output caps and truncation ----

func TestListToolTruncatesOversizedResults(t *testing.T) {
	rows := make([]string, 0, 1200)
	for i := range 1200 {
		rows = append(rows, fmt.Sprintf(
			`{"slug":"a-%04d","title":%q,"points_possible":10,"is_team":false,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00"}`,
			i, strings.Repeat("x", 120)))
	}
	fake := newFakePostgREST(t)
	fake.respond("/assignments", "["+strings.Join(rows, ",")+"]")
	req, _ := readToolRequest(t, nil)

	_, out, err := fake.deps(t).listAssignments(context.Background(), req, nil)
	if err != nil {
		t.Fatalf("tool error: %v", err)
	}
	if !out.Truncated {
		t.Fatal("expected truncated = true")
	}
	if out.TotalCount != 1200 {
		t.Fatalf("total_count = %d, want 1200", out.TotalCount)
	}
	if len(out.Assignments) == 0 || len(out.Assignments) >= 1200 {
		t.Fatalf("len(assignments) = %d", len(out.Assignments))
	}
	encoded, err := json.Marshal(out)
	if err != nil {
		t.Fatalf("marshal output: %v", err)
	}
	if len(encoded) > maxToolResultBytes {
		t.Fatalf("output is %d bytes, cap is %d", len(encoded), maxToolResultBytes)
	}
}

func TestGetAssignmentBoundsBodyText(t *testing.T) {
	longBody := strings.Repeat("z", maxAssignmentBodyChars+5000)
	detail := strings.Replace(fixtureAssignmentDetail, `"body":"Do the thing"`, `"body":"`+longBody+`"`, 1)
	fake := newFakePostgREST(t)
	fake.respond("/assignments", detail)
	fake.respond("/assignment_grade_distributions", "[]")
	req, _ := readToolRequest(t, nil)

	_, out, err := fake.deps(t).getAssignment(context.Background(), req, getAssignmentInput{Slug: "proj1"})
	if err != nil {
		t.Fatalf("tool error: %v", err)
	}
	if !out.BodyTruncated {
		t.Fatal("expected body_truncated = true")
	}
	if !strings.HasSuffix(out.Body, "...[truncated]") {
		t.Fatalf("body does not end with the truncation marker: %q", out.Body[len(out.Body)-30:])
	}
	if out.GradeDistribution != nil {
		t.Fatal("no distribution row means no grade_distribution in the output")
	}
}

func TestGetMySubmissionsBoundsFieldBodies(t *testing.T) {
	longBody := strings.Repeat("y", maxSubmissionBodyChars+2000)
	submissions := strings.Replace(fixtureSubmissions, `"body":"https://example.com/x"`, `"body":"`+longBody+`"`, 1)
	fake := newFakePostgREST(t)
	fake.respond("/users", fixtureUserRows)
	fake.respond("/assignment_submissions", submissions)
	req, _ := readToolRequest(t, nil)

	_, out, err := fake.deps(t).getMySubmissions(context.Background(), req, getMySubmissionsInput{})
	if err != nil {
		t.Fatalf("tool error: %v", err)
	}
	field := out.Submissions[0].Fields[0]
	if !field.BodyTruncated {
		t.Fatal("expected body_truncated = true on the field submission")
	}
	if !strings.HasSuffix(field.Body, "...[truncated]") {
		t.Fatal("field body does not end with the truncation marker")
	}
}

// ---- error mapping ----

func TestPostgRESTErrorMapping(t *testing.T) {
	tests := []struct {
		name        string
		status      int
		body        string
		wantSubstrs []string
	}{
		{
			name:        "401 explains expiry",
			status:      http.StatusUnauthorized,
			body:        `{"message":"JWT expired"}`,
			wantSubstrs: []string{"HTTP 401", "JWT expired", "re-authenticate"},
		},
		{
			name:        "403 carries the PostgREST message",
			status:      http.StatusForbidden,
			body:        `{"message":"permission denied for view grades"}`,
			wantSubstrs: []string{"HTTP 403", "permission denied for view grades"},
		},
		{
			name:        "unparseable body still reports the status",
			status:      http.StatusNotFound,
			body:        `not json at all`,
			wantSubstrs: []string{"HTTP 404"},
		},
		{
			name:        "control characters are sanitized",
			status:      http.StatusInternalServerError,
			body:        "{\"message\":\"bad\\nthing\\u0001here\"}",
			wantSubstrs: []string{"HTTP 500", "bad thing"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			fake.respondStatus("/assignments", tt.status, tt.body)
			req, token := readToolRequest(t, nil)

			_, _, err := fake.deps(t).listAssignments(context.Background(), req, nil)
			if err == nil {
				t.Fatal("expected a tool error")
			}
			text := err.Error()
			for _, want := range tt.wantSubstrs {
				if !strings.Contains(text, want) {
					t.Fatalf("error %q does not contain %q", text, want)
				}
			}
			if strings.Contains(text, token) {
				t.Fatal("error echoes the bearer token")
			}
			if strings.Contains(text, "\n") {
				t.Fatalf("error contains a newline: %q", text)
			}
		})
	}
}

// ---- scope gating ----

func TestAuthorizeScope(t *testing.T) {
	tests := []struct {
		name     string
		scopes   []string
		required string
		allowed  bool
	}{
		{name: "missing scopes claim may not read", scopes: nil, required: scopeRead, allowed: false},
		{name: "empty scopes claim may not read", scopes: []string{}, required: scopeRead, allowed: false},
		{name: "missing scopes claim may not write", scopes: nil, required: "write", allowed: false},
		{name: "read scope allows reads", scopes: []string{"read"}, required: scopeRead, allowed: true},
		{name: "unrelated scopes deny reads", scopes: []string{"openid", "profile"}, required: scopeRead, allowed: false},
		{name: "write scope alone denies reads", scopes: []string{"write"}, required: scopeRead, allowed: false},
		{name: "write scope allows writes", scopes: []string{"read", "write"}, required: "write", allowed: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := authorizeScope(&identity{Scopes: tt.scopes}, tt.required)
			if tt.allowed && err != nil {
				t.Fatalf("expected allow, got %v", err)
			}
			if !tt.allowed && err == nil {
				t.Fatal("expected deny, got allow")
			}
		})
	}
}

// TestScopelessIdentityIsDeniedEveryTool pins the removal of the phase 0
// grandfathering (issue #324). An identity carrying no scope this server
// recognises once got read access, because phase 0 tokens predated the scopes
// claim; that credential class is gone (issue #322) and the exemption with
// it. The rule now is uniform, and it has to stay uniform: a scope claim that
// fails to parse, or a future identity built by code that never heard of this
// rule, must land on a refusal rather than inherit reads by omission. Note
// that External is not consulted — an identity without it is refused exactly
// like an OAuth one.
func TestScopelessIdentityIsDeniedEveryTool(t *testing.T) {
	for _, scopes := range [][]string{nil, {}, {"openid", "offline_access"}} {
		for _, external := range []bool{true, false} {
			for _, required := range []string{scopeRead, scopeWrite} {
				id := &identity{Scopes: scopes, External: external}
				// Errorf, not Fatalf: every violating combination should
				// show up in one run, not just the first.
				if err := authorizeScope(id, required); err == nil {
					t.Errorf("scopes %v (external=%t) were allowed %q", scopes, external, required)
				}
			}
		}
	}

	// And through the tools themselves, read tools included: every one
	// refuses, and none of them reaches PostgREST.
	ctx := context.Background()
	fake := newFakePostgREST(t)
	fake.respond("/users", fixtureUserRows)
	fake.respond("/assignments", fixtureAssignmentDetail)
	fake.respond("/quizzes", fixtureQuizzes)
	fake.respond("/meetings", fixtureMeetings)
	fake.respond("/engagements", fixtureEngagements)
	deps := fake.deps(t)
	// Deliberately not marked External: that is the hazard this test exists
	// for. The grandfathering only ever applied to an identity that was not
	// an OAuth caller, so a fixture that is one would not notice its return.
	claims := currentClaims()
	claims["netid"] = "abc123"
	id := identityForClaims(t, claims, signTestToken(t, hs256Header(), claims, testSecret))
	id.External = false
	req := &mcp.CallToolRequest{Extra: &mcp.RequestExtra{TokenInfo: tokenInfoFromIdentity(id)}}

	calls := map[string]func() error{
		"whoami":             func() error { _, _, err := deps.whoami(ctx, req, nil); return err },
		"list_assignments":   func() error { _, _, err := deps.listAssignments(ctx, req, nil); return err },
		"get_assignment":     func() error { _, _, err := deps.getAssignment(ctx, req, getAssignmentInput{Slug: "proj1"}); return err },
		"get_my_submissions": func() error { _, _, err := deps.getMySubmissions(ctx, req, getMySubmissionsInput{}); return err },
		"list_quizzes":       func() error { _, _, err := deps.listQuizzes(ctx, req, nil); return err },
		"get_my_quiz_grades": func() error { _, _, err := deps.getMyQuizGrades(ctx, req, nil); return err },
		"get_my_grades":      func() error { _, _, err := deps.getMyGrades(ctx, req, nil); return err },
		"list_meetings":      func() error { _, _, err := deps.listMeetings(ctx, req, nil); return err },
		"get_my_engagements": func() error { _, _, err := deps.getMyEngagements(ctx, req, nil); return err },
		"get_api_schema":     func() error { _, _, err := deps.getAPISchema(ctx, req, nil); return err },
		"postgrest_request GET": func() error {
			_, _, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{Method: http.MethodGet, Path: "/assignments"})
			return err
		},
		"postgrest_request POST": func() error {
			_, _, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{Method: http.MethodPost, Path: "/assignment_field_submissions", Body: `{"body":"x"}`})
			return err
		},
		"preview_submission_change": func() error {
			_, _, err := deps.previewSubmissionChange(ctx, req, submissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x"})
			return err
		},
		"submit_submission_change": func() error {
			_, _, err := deps.submitSubmissionChange(ctx, req, submissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x"})
			return err
		},
	}
	for name, call := range calls {
		t.Run(name, func(t *testing.T) {
			err := call()
			if err == nil {
				t.Fatal("a caller with no recognised scopes was allowed")
			}
			// The scope gate, not a later failure: only authorizeScope says
			// "denied". The exchange refuses a scopeless caller too, but that
			// is the second line of defence, and a tool must never get that
			// far.
			if !strings.Contains(err.Error(), "denied") {
				t.Fatalf("error is not a scope denial: %v", err)
			}
		})
	}
	if recorded := fake.recorded(); len(recorded) != 0 {
		t.Fatalf("scope-denied calls reached PostgREST: %+v", recorded)
	}
}

func TestReadToolsHonorScopeClaims(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixtureAssignments)

	// A scope-bearing token without read is denied before any PostgREST call.
	deniedReq, _ := readToolRequest(t, func(claims map[string]any) {
		claims["scopes"] = []string{"openid"}
	})
	_, _, err := fake.deps(t).listAssignments(context.Background(), deniedReq, nil)
	if err == nil || !strings.Contains(err.Error(), "scope") {
		t.Fatalf("expected a scope error, got %v", err)
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("scope-denied call must not reach PostgREST")
	}

	// An OAuth-style space-delimited scope claim carrying read is allowed.
	// The fixture's own "scopes" claim goes, since it takes precedence.
	allowedReq, _ := readToolRequest(t, func(claims map[string]any) {
		delete(claims, "scopes")
		claims["scope"] = "read write"
	})
	_, out, err := fake.deps(t).listAssignments(context.Background(), allowedReq, nil)
	if err != nil {
		t.Fatalf("tool error: %v", err)
	}
	if out.TotalCount != 1 {
		t.Fatalf("output = %+v", out)
	}
}

// ---- input validation ----

func TestGetAssignmentRejectsInvalidSlug(t *testing.T) {
	fake := newFakePostgREST(t)
	req, _ := readToolRequest(t, nil)

	for _, slug := range []string{"", "UPPER", "has space", "a,b", "x=y", strings.Repeat("a", 80)} {
		_, _, err := fake.deps(t).getAssignment(context.Background(), req, getAssignmentInput{Slug: slug})
		if err == nil {
			t.Fatalf("slug %q should be rejected", slug)
		}
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("invalid slugs must not reach PostgREST")
	}
}

func TestCapAssignmentOutputEnforcesByteBudget(t *testing.T) {
	out := getAssignmentOutput{
		Slug:  "big",
		Title: "big assignment",
		// Multibyte runes: 24k runes of 'é' serialize to ~48KB alone.
		Body: strings.Repeat("é", 24000),
	}
	for i := range 200 {
		out.Fields = append(out.Fields, assignmentFieldInfo{
			Slug:  fmt.Sprintf("f-%03d", i),
			Label: strings.Repeat("x", 400),
		})
	}
	capped := capAssignmentOutput(out)
	encoded, err := json.Marshal(capped)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > maxToolResultBytes {
		t.Fatalf("capped output is %d bytes, want <= %d", len(encoded), maxToolResultBytes)
	}
	if !capped.FieldsTruncated && !capped.BodyTruncated {
		t.Fatal("expected truncation flags to be set")
	}
}

func TestCapAssignmentOutputLeavesSmallResultsAlone(t *testing.T) {
	out := getAssignmentOutput{Slug: "small", Body: "short"}
	capped := capAssignmentOutput(out)
	if capped.Body != "short" || capped.BodyTruncated || capped.FieldsTruncated {
		t.Fatal("small output must pass through unchanged")
	}
}

// Tokens minted by api.issue_user_jwt_for_mcp carry granular scope names;
// hand-minted tokens may carry the coarse ones. Both must work.
func TestAuthorizeScopeAcceptsGranularScopeNames(t *testing.T) {
	cases := []struct {
		scopes    []string
		required  string
		wantAllow bool
	}{
		{[]string{"course:read", "grades:read"}, scopeRead, true},
		{[]string{"course:read", "grades:read"}, scopeWrite, false},
		{[]string{"submissions:read", "submissions:write"}, scopeWrite, true},
		{[]string{"read"}, scopeRead, true},
		{[]string{"write"}, scopeWrite, true},
		{[]string{"read"}, scopeWrite, false},
		{[]string{"unrelated:scope"}, scopeRead, false},
	}
	for _, tc := range cases {
		err := authorizeScope(&identity{Scopes: tc.scopes}, tc.required)
		if tc.wantAllow && err != nil {
			t.Errorf("scopes %v should grant %q: %v", tc.scopes, tc.required, err)
		}
		if !tc.wantAllow && err == nil {
			t.Errorf("scopes %v must not grant %q", tc.scopes, tc.required)
		}
	}
}

// Issue #372: the instructions are injected into the calling model's context
// and are the server's own account of what it can do. They used to open
// "curated read-only tools" while newMCPServer registered the write tools, so
// a model reasoning about whether it may change a student's submission read a
// claim that was wrong in the permissive direction. Both escape-hatch modes
// register the same write tool, so both must say so.
func TestServerInstructionsDescribeTheWriteTool(t *testing.T) {
	for _, tc := range []struct {
		name          string
		writesEnabled bool
	}{
		{"escape hatch read-only", false},
		{"escape hatch read-write", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			instructions := serverInstructions(tc.writesEnabled)

			// The server must not describe its tool surface as read-only
			// while registerWriteTools is registering a tool that writes.
			for _, claim := range []string{"read-only tools", "curated read-only"} {
				if strings.Contains(strings.ToLower(instructions), claim) {
					t.Fatalf("instructions still claim %q: %q", claim, instructions)
				}
			}
			// The write tool and the scope it needs are named, and the model
			// is told the scope is not granted by default.
			for _, want := range []string{
				"submit_submission_change",
				"submissions:write",
				"unchecked by default",
			} {
				if !strings.Contains(instructions, want) {
					t.Fatalf("instructions do not mention %q: %q", want, instructions)
				}
			}
			// The blast radius of a write: on a team assignment
			// submit_submission_change resolves to the team's shared
			// submission (write_tools.go filters by team_nickname), so one
			// write can overwrite several students' shared work by people who
			// never consented to this client. A model that reads only "the
			// caller's own submission" would act without knowing that.
			lower := strings.ToLower(instructions)
			for _, want := range []string{"team", "shared submission", "teammate", "is_team"} {
				if !strings.Contains(lower, want) {
					t.Fatalf("instructions do not say a write can affect a team's shared work (missing %q): %q", want, instructions)
				}
			}

			// The prefix must not contradict the escape-hatch half spliced in
			// after it. Merely naming postgrest_request is not enough: the
			// first version of this test did exactly that and passed against
			// a document that claimed one writer in the prefix and described
			// a second one four lines later.
			if !strings.Contains(instructions, "postgrest_request") {
				t.Fatalf("instructions lost the escape-hatch description: %q", instructions)
			}
			singleWriterClaim := strings.Contains(instructions, "ONLY path on this deployment that can change") ||
				strings.Contains(instructions, "the one tool that writes")
			secondWritePath := strings.Contains(instructions, "SECOND write path") ||
				strings.Contains(instructions, "other verbs need the write scope")
			if singleWriterClaim && secondWritePath {
				t.Fatalf("instructions claim a single write path and describe a second one: %q", instructions)
			}
			if !singleWriterClaim && !secondWritePath {
				t.Fatalf("instructions say nothing about how many write paths exist: %q", instructions)
			}
			// And each mode must state the one that matches its hatch.
			if tc.writesEnabled != secondWritePath {
				t.Fatalf("writesEnabled=%v but the instructions %s a second write path: %q",
					tc.writesEnabled, map[bool]string{true: "describe", false: "do not describe"}[secondWritePath], instructions)
			}
			if tc.writesEnabled && !strings.Contains(instructions, "POST, PATCH") {
				t.Fatalf("the deployed (writes-enabled) rendering does not name the raw verbs it permits: %q", instructions)
			}
		})
	}

	// Only the escape-hatch half may differ between the two postures.
	readOnly, writable := serverInstructions(false), serverInstructions(true)
	if readOnly == writable {
		t.Fatal("the two escape-hatch postures produce identical instructions")
	}
}

// Issue #373: the strings a student can actually read must not carry the
// internal platform name — a scope failure is exactly when they are already
// confused — while keeping the half that tells them what to do about it.
func TestStudentFacingStringsAvoidThePlatformName(t *testing.T) {
	containsPlatformName := func(s string) bool {
		return strings.Contains(strings.ToLower(s), "yeluke")
	}

	// The scope gate every tool shares. The guidance has to name scopes that
	// would actually grant what was denied: a student told to re-authorize
	// for the three read scopes after a denied write follows the instruction
	// exactly and is denied again.
	for _, tc := range []struct {
		name     string
		id       *identity
		required string
		want     []string
		reject   []string
	}{
		{
			name:     "no scopes at all, read denied",
			id:       &identity{},
			required: scopeRead,
			want:     []string{"re-authorize", "course:read", "grades:read", "submissions:read"},
		},
		{
			name:     "no scopes at all, write denied",
			id:       &identity{},
			required: scopeWrite,
			want:     []string{"re-authorize", "submissions:write"},
			// Sending a blocked write to the read scopes is the loop.
			reject: []string{"course:read, grades:read, or submissions:read"},
		},
		{
			// The realistic case: consent granted the reads, not the write.
			name:     "read scopes only, write denied",
			id:       &identity{Scopes: []string{"course:read", "grades:read", "submissions:read"}},
			required: scopeWrite,
			want:     []string{"re-authorize", "submissions:write"},
			reject:   []string{"course:read, grades:read, or submissions:read"},
		},
	} {
		err := authorizeScope(tc.id, tc.required)
		if err == nil {
			t.Fatalf("%s: %q was allowed", tc.name, tc.required)
		}
		if containsPlatformName(err.Error()) {
			t.Fatalf("%s: scope denial names the platform: %q", tc.name, err)
		}
		for _, want := range tc.want {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("%s: scope denial dropped %q: %q", tc.name, want, err)
			}
		}
		for _, reject := range tc.reject {
			if strings.Contains(err.Error(), reject) {
				t.Fatalf("%s: a denied write is sent to scopes that would not grant it: %q", tc.name, err)
			}
		}
		if !strings.Contains(err.Error(), tc.required) {
			t.Fatalf("%s: scope denial no longer says what was denied: %q", tc.name, err)
		}
	}

	// The same failure reached through the token exchange.
	exchanger := newTokenExchanger(newPostgRESTClient("postgrest", "3000"), "service-jwt")
	_, err := exchanger.tokenFor(context.Background(), exchangeRequest{
		netID:    "abc123",
		outerExp: time.Now().Add(time.Hour),
	})
	if err == nil {
		t.Fatal("a scopeless exchange request was allowed to mint a credential")
	}
	if containsPlatformName(err.Error()) {
		t.Fatalf("exchange denial names the platform: %q", err)
	}
	if !strings.Contains(err.Error(), "no course credential can be issued") {
		t.Fatalf("exchange denial lost its explanation: %q", err)
	}

	// The schema document get_api_schema hands to the assistant.
	if containsPlatformName(apiSchemaDocument) {
		t.Fatalf("the API schema document names the platform: %q", firstLine(apiSchemaDocument))
	}

	// Nothing above is worth much if the instructions reintroduce it.
	for _, writesEnabled := range []bool{false, true} {
		if containsPlatformName(serverInstructions(writesEnabled)) {
			t.Fatalf("server instructions name the platform (writes=%v)", writesEnabled)
		}
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// A model can call a tool from its tools/list description alone: the server
// instructions are read once at initialize and a client may summarize or drop
// them, but the description travels with every listing. So the team
// consequence has to be stated there too, and the description used to say the
// opposite -- "the caller's own submission".
func TestSubmitSubmissionChangeDescriptionNamesTheTeamConsequence(t *testing.T) {
	server := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.1"}, nil)
	registerWriteTools(server, &toolDeps{
		logger:    slog.New(slog.NewJSONHandler(io.Discard, nil)),
		postgrest: newPostgRESTClient("postgrest", "3000"),
	})

	ctx := context.Background()
	clientTransport, serverTransport := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer serverSession.Close()
	session, err := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.1"}, nil).
		Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer session.Close()

	list, err := session.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("tools/list: %v", err)
	}
	var description string
	for _, tool := range list.Tools {
		if tool.Name == "submit_submission_change" {
			description = tool.Description
		}
	}
	if description == "" {
		t.Fatal("submit_submission_change is not registered")
	}
	if strings.Contains(description, "the caller's own submission") {
		t.Fatalf("description still claims the write touches only the caller's own row: %q", description)
	}
	for _, want := range []string{"team", "shared", "is_team"} {
		if !strings.Contains(strings.ToLower(description), want) {
			t.Fatalf("description does not mention %q: %q", want, description)
		}
	}
}
