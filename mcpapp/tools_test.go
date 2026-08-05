package main

// Unit tests for the curated read tools (issue #266) against a fake PostgREST:
// query paths and parameters (eq filters, select= embeds), Authorization
// forwarding, output shaping and truncation, scope gating, and error mapping.

import (
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
		intent:    newIntentSigner([]byte(testSecret), time.Now),
	}
}

// readToolRequest builds a CallToolRequest carrying the TokenInfo produced by
// the real verifier for a freshly signed token, exercising the same plumbing
// the streamable HTTP transport uses.
func readToolRequest(t *testing.T, mutate func(map[string]any)) (*mcp.CallToolRequest, string) {
	t.Helper()
	claims := currentClaims()
	if mutate != nil {
		mutate(claims)
	}
	token := signTestToken(t, hs256Header(), claims, testSecret)
	verifier := newTokenVerifier(testJWTConfig())
	info, err := verifier(context.Background(), token, nil)
	if err != nil {
		t.Fatalf("verify token: %v", err)
	}
	return &mcp.CallToolRequest{Extra: &mcp.RequestExtra{TokenInfo: info}}, token
}

// ---- fixtures ----

const (
	fixtureUserRows = `[{"id":42,"netid":"abc123","name":"Alice Ok","known_as":"Al","nickname":"fuzzy-bunny","team_nickname":"team-one","role":"student"}]`

	fixtureUserRowsNoTeam = `[{"id":42,"netid":"abc123","name":"Alice Ok","known_as":"Al","nickname":"fuzzy-bunny","team_nickname":null,"role":"student"}]`

	fixtureAssignments = `[{"slug":"proj1","title":"Project 1","points_possible":10,"is_team":false,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00"}]`

	fixtureAssignmentDetail = `[{"slug":"proj1","title":"Project 1","body":"Do the thing","is_markdown":true,"points_possible":10,"is_team":false,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00","fields":[{"slug":"repo-url","label":"Repo URL","help":"paste it","placeholder":"https://...","is_url":true,"is_multiline":false,"display_order":0,"pattern":".*","example":"https://example.com"}]}]`

	fixtureAssignmentDistribution = `[{"count":5,"average":8.2,"min":4,"max":10,"points_possible":10,"stddev":1.5}]`

	fixtureSubmissions = `[{"id":7,"assignment_slug":"proj1","is_team":true,"user_id":null,"team_nickname":"team-one","submitter_user_id":43,"created_at":"2026-08-02T00:00:00+00:00","updated_at":"2026-08-02T00:00:00+00:00","fields":[{"assignment_field_slug":"repo-url","body":"https://example.com/x","submitter_user_id":43,"created_at":"2026-08-02T00:00:00+00:00","updated_at":"2026-08-02T00:00:00+00:00"}]}]`

	fixtureQuizzes = `[{"id":1,"meeting_slug":"intro","points_possible":5,"is_draft":false,"is_open":false,"duration":"00:15:00","open_at":"2026-08-20T00:00:00+00:00","closed_at":"2026-08-25T00:00:00+00:00","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-01T00:00:00+00:00"}]`

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
					"select": "id,meeting_slug,points_possible,is_draft,is_open,duration,open_at,closed_at,created_at,updated_at",
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
		{name: "scopeless legacy token may read", scopes: nil, required: scopeRead, allowed: true},
		{name: "empty scopes claim may read", scopes: []string{}, required: scopeRead, allowed: true},
		{name: "scopeless legacy token may not write", scopes: nil, required: "write", allowed: false},
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
	allowedReq, _ := readToolRequest(t, func(claims map[string]any) {
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
