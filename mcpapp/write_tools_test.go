package main

// Tests for the curated write tools (issue #267) against the fake PostgREST.
//
// The write path is deliberately thin: preview_submission_change reads and
// summarizes, submit_submission_change writes, and the only authorization
// boundary is the OAuth write scope with row-level security underneath it.
// These tests therefore assert on the properties that boundary depends on:
// which scope each tool demands, that preview never writes, that input
// validation and the optimistic-concurrency check happen before any request
// leaves the process, that the write requests themselves carry the caller's
// own token and the updated_at just read, and that a half-finished create is
// rolled back rather than left looking like a blank submission.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	fixturePrepareAssignment = `[{"slug":"proj1","title":"Project 1","is_team":false,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","fields":[{"slug":"repo-url"},{"slug":"essay"}]}]`

	fixturePrepareTeamAssignment = `[{"slug":"team-proj","title":"Team Project","is_team":true,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","fields":[{"slug":"repo-url"}]}]`

	fixtureClosedAssignment = `[{"slug":"proj1","title":"Project 1","is_team":false,"is_draft":false,"is_open":false,"closed_at":"2026-01-01T00:00:00+00:00","fields":[{"slug":"repo-url"}]}]`

	fixtureExistingSubmission = `[{"id":7,"fields":[{"assignment_field_slug":"repo-url","body":"old-value","updated_at":"2026-08-02T00:00:00+00:00"}]}]`

	fixtureSubmissionWithoutField = `[{"id":7,"fields":[]}]`

	// fixtureStoredOverwrite is the PATCH representation PostgREST returns for
	// a successful overwrite (an array, since no object Accept is requested).
	fixtureStoredOverwrite = `[{"assignment_submission_id":7,"assignment_field_slug":"repo-url","assignment_slug":"proj1","body":"new-value","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-05T12:00:00+00:00"}]`
)

// writeToolRequest builds a CallToolRequest whose token carries read+write
// scopes.
func writeToolRequest(t *testing.T, mutate func(map[string]any)) (*mcp.CallToolRequest, string) {
	t.Helper()
	return readToolRequest(t, func(claims map[string]any) {
		claims["scopes"] = []string{"read", "write"}
		if mutate != nil {
			mutate(claims)
		}
	})
}

// ---- scope gating ----

func TestSubmitSubmissionChangeScopeDenials(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{name: "no recognised scopes (denied outright)", mutate: func(c map[string]any) { delete(c, "scopes") }},
		{name: "empty scopes claim", mutate: func(c map[string]any) { c["scopes"] = []string{} }},
		{name: "read-only scopes", mutate: func(c map[string]any) { c["scopes"] = []string{"read"} }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			req, _ := readToolRequest(t, tt.mutate)
			_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
				AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x",
			})
			if err == nil || !strings.Contains(err.Error(), "scope") && !strings.Contains(err.Error(), "denied") {
				t.Fatalf("expected a scope denial, got %v", err)
			}
			if len(fake.recorded()) != 0 {
				t.Fatal("a scope-denied submit must not reach PostgREST at all")
			}
		})
	}
}

// The preview is the tool an agent should reach for before writing, so it must
// work for a caller who was only ever granted read access — otherwise showing
// the user what a write would do would itself require the write scope.
func TestPreviewSubmissionChangeNeedsOnlyReadScopeAndWritesNothing(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{name: "the read scopes consent grants", mutate: nil},
		{name: "read scope only", mutate: func(c map[string]any) { c["scopes"] = []string{"read"} }},
		{name: "granular read scopes", mutate: func(c map[string]any) { c["scopes"] = []string{"course:read", "submissions:read"} }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			fake.respond("/assignments", fixturePrepareAssignment)
			fake.respond("/assignment_submissions", fixtureExistingSubmission)
			req, _ := readToolRequest(t, tt.mutate)

			_, out, err := fake.deps(t).previewSubmissionChange(context.Background(), req, submissionChangeInput{
				AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
			})
			if err != nil {
				t.Fatalf("preview: %v", err)
			}
			if out.Action != "overwrite" || out.CurrentBody != "old-value" {
				t.Fatalf("output = %+v", out)
			}
			if countWrites(fake) != 0 {
				t.Fatalf("preview issued a non-GET request: %+v", fake.recorded())
			}
		})
	}
}

// A caller holding only the write scope still cannot preview: preview is a
// read, and the read scope is what authorizes reads.
func TestPreviewSubmissionChangeRequiresReadScope(t *testing.T) {
	fake := newFakePostgREST(t)
	req, _ := readToolRequest(t, func(claims map[string]any) {
		claims["scopes"] = []string{"write"}
	})
	_, _, err := fake.deps(t).previewSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x",
	})
	if err == nil || !strings.Contains(err.Error(), "scope") {
		t.Fatalf("expected a scope error, got %v", err)
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("a scope-denied preview must not reach PostgREST")
	}
}

// ---- input validation, all of it ahead of any write ----

func TestSubmitSubmissionChangeRejectsOversizedBody(t *testing.T) {
	fake := newFakePostgREST(t)
	req, _ := writeToolRequest(t, nil)
	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url",
		Body: strings.Repeat("a", maxSubmissionWriteBytes+1),
	})
	if err == nil || !strings.Contains(err.Error(), "64KB") {
		t.Fatalf("expected a size error, got %v", err)
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("an oversized body must be rejected before any PostgREST call")
	}
}

func TestSubmitSubmissionChangeRejectsBadInputs(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", "[]")
	req, _ := writeToolRequest(t, nil)
	deps := fake.deps(t)
	ctx := context.Background()

	if _, _, err := deps.submitSubmissionChange(ctx, req, submissionChangeInput{AssignmentSlug: "BAD SLUG", FieldSlug: "repo-url", Body: "x"}); err == nil {
		t.Fatal("bad assignment slug accepted")
	}
	if _, _, err := deps.submitSubmissionChange(ctx, req, submissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "NOPE", Body: "x"}); err == nil {
		t.Fatal("bad field slug accepted")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("invalid slugs must not reach PostgREST")
	}
	if _, _, err := deps.submitSubmissionChange(ctx, req, submissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "no-such-field", Body: "x"}); err == nil || !strings.Contains(err.Error(), "no field") {
		t.Fatalf("unknown field: %v", err)
	}
	if _, _, err := deps.submitSubmissionChange(ctx, req, submissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x", ExpectedUpdatedAt: "2026-01-01T00:00:00+00:00"}); err == nil || !strings.Contains(err.Error(), "no existing value") {
		t.Fatalf("expected_updated_at with no existing row: %v", err)
	}
	if countWrites(fake) != 0 {
		t.Fatalf("a rejected submit performed a write: %+v", fake.recorded())
	}
}

// An assignment the caller cannot see is indistinguishable from one that does
// not exist, and both must stop the write before it starts. RLS already hides
// draft and foreign-course rows, so an empty read here is the normal shape of
// "you may not touch this".
func TestSubmitSubmissionChangeAssignmentNotFound(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", `[]`)
	req, _ := writeToolRequest(t, nil)
	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "no-such-assignment", FieldSlug: "repo-url", Body: "x",
	})
	if err == nil || !strings.Contains(err.Error(), "not found or is not visible") {
		t.Fatalf("unknown assignment: %v", err)
	}
	if countWrites(fake) != 0 {
		t.Fatal("an unknown assignment must not produce a write")
	}
}

// A caller that names the version it read must be told, not silently
// overwrite, when the stored version moved on. This is the whole point of
// keeping expected_updated_at now that the intent token is gone.
func TestSubmitSubmissionChangeStaleExpectedUpdatedAt(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	req, _ := writeToolRequest(t, nil)
	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x",
		ExpectedUpdatedAt: "2020-01-01T00:00:00+00:00",
	})
	if err == nil || !strings.Contains(err.Error(), "changed since you read it") {
		t.Fatalf("expected a stale error, got %v", err)
	}
	if countWrites(fake) != 0 {
		t.Fatalf("a stale submit performed a write: %+v", fake.recorded())
	}
}

func TestSubmitTeamAssignmentWithoutTeam(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareTeamAssignment)
	fake.respond("/users", fixtureUserRowsNoTeam)
	req, _ := writeToolRequest(t, nil)
	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "team-proj", FieldSlug: "repo-url", Body: "x",
	})
	if err == nil || !strings.Contains(err.Error(), "not on a team") {
		t.Fatalf("expected a team error, got %v", err)
	}
}

// A team assignment's submission is shared, so it must be located by the
// caller's team rather than by their user id; looking it up by user id would
// miss a teammate's existing submission and try to create a duplicate.
func TestPreviewTeamAssignmentLooksUpTheTeamSubmission(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareTeamAssignment)
	fake.respond("/users", fixtureUserRows)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	req, _ := writeToolRequest(t, nil)

	_, out, err := fake.deps(t).previewSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "team-proj", FieldSlug: "repo-url", Body: "new-value",
	})
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if !out.IsTeam || out.TeamNickname != "team-one" {
		t.Fatalf("output = %+v", out)
	}

	var lookups []pgRequest
	for _, recorded := range fake.recorded() {
		if recorded.path == "/assignment_submissions" {
			lookups = append(lookups, recorded)
		}
	}
	if len(lookups) != 1 {
		t.Fatalf("submission lookups = %+v", lookups)
	}
	if got := lookups[0].query.Get("team_nickname"); got != "eq.team-one" {
		t.Fatalf("team_nickname filter = %q", got)
	}
	if lookups[0].query.Has("user_id") {
		t.Fatal("a team submission must not be filtered by user_id")
	}
}

// ---- preview: create vs overwrite ----

func TestPreviewSubmissionChangeCreateVsOverwrite(t *testing.T) {
	tests := []struct {
		name             string
		submissions      string
		wantAction       string
		wantCreatesSub   bool
		wantCurrentBody  string
		wantCurrentTime  string
		wantCurrentBytes int
	}{
		{
			name:           "no submission row: create both",
			submissions:    "[]",
			wantAction:     "create",
			wantCreatesSub: true,
		},
		{
			name:        "submission exists, field missing: create field",
			submissions: fixtureSubmissionWithoutField,
			wantAction:  "create",
		},
		{
			name:             "field exists: overwrite",
			submissions:      fixtureExistingSubmission,
			wantAction:       "overwrite",
			wantCurrentBody:  "old-value",
			wantCurrentTime:  "2026-08-02T00:00:00+00:00",
			wantCurrentBytes: len("old-value"),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			fake.respond("/assignments", fixturePrepareAssignment)
			fake.respond("/assignment_submissions", tt.submissions)
			req, _ := writeToolRequest(t, nil)

			_, out, err := fake.deps(t).previewSubmissionChange(context.Background(), req, submissionChangeInput{
				AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
			})
			if err != nil {
				t.Fatalf("preview: %v", err)
			}
			if out.Action != tt.wantAction || out.CreatesSubmission != tt.wantCreatesSub {
				t.Fatalf("action = %q creates_submission = %v, want %q/%v", out.Action, out.CreatesSubmission, tt.wantAction, tt.wantCreatesSub)
			}
			if out.CurrentBody != tt.wantCurrentBody || out.CurrentLengthBytes != tt.wantCurrentBytes {
				t.Fatalf("current = %q (%d bytes)", out.CurrentBody, out.CurrentLengthBytes)
			}
			// current_updated_at is what a careful caller feeds back as
			// expected_updated_at, so it must be present on every overwrite.
			if out.CurrentUpdatedAt != tt.wantCurrentTime {
				t.Fatalf("current_updated_at = %q, want %q", out.CurrentUpdatedAt, tt.wantCurrentTime)
			}
			if !out.Changed {
				t.Fatal("a different proposed body must report changed=true")
			}
			if out.ProposedBody != "new-value" || out.ProposedLengthBytes != len("new-value") {
				t.Fatalf("proposed = %q (%d bytes)", out.ProposedBody, out.ProposedLengthBytes)
			}
			if out.AssignmentSlug != "proj1" || out.AssignmentTitle != "Project 1" || out.FieldSlug != "repo-url" {
				t.Fatalf("target = %+v", out)
			}
		})
	}
}

func TestPreviewSubmissionChangeUnchangedAndClosedWarnings(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixtureClosedAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	req, _ := writeToolRequest(t, nil)
	_, out, err := fake.deps(t).previewSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "old-value",
	})
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if out.Changed {
		t.Fatal("an identical body must report changed=false")
	}
	if out.AssignmentIsOpen {
		t.Fatal("a closed assignment must report assignment_is_open=false")
	}
	if !strings.Contains(out.Warning, "not currently open") || !strings.Contains(out.Warning, "identical") {
		t.Fatalf("warning = %q", out.Warning)
	}
}

// ---- submit: the exact PostgREST requests ----

func TestSubmitHappyCreateIncludingSubmissionRow(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", "[]")
	fake.respondMethod(http.MethodPost, "/assignment_submissions", http.StatusCreated,
		`{"id":9,"assignment_slug":"proj1","is_team":false,"user_id":42}`)
	fake.respondMethod(http.MethodPost, "/assignment_field_submissions", http.StatusCreated,
		`{"assignment_submission_id":9,"assignment_field_slug":"repo-url","assignment_slug":"proj1","body":"new-value","created_at":"2026-08-05T00:00:00+00:00","updated_at":"2026-08-05T00:00:00+00:00"}`)
	deps := fake.deps(t)
	req, token := writeToolRequest(t, nil)

	_, out, err := deps.submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	if out.Action != "create" || out.SubmissionID != 9 || out.Body != "new-value" {
		t.Fatalf("output = %+v", out)
	}

	writes := recordedWrites(fake)
	if len(writes) != 2 {
		t.Fatalf("write requests = %d, want 2: %+v", len(writes), writes)
	}

	subPost := writes[0]
	if subPost.method != http.MethodPost || subPost.path != "/assignment_submissions" {
		t.Fatalf("first write = %s %s", subPost.method, subPost.path)
	}
	if subPost.auth != "Bearer "+token {
		t.Fatal("the submission POST did not forward the caller's token, so RLS would run as someone else")
	}
	if len(subPost.prefer) != 1 || subPost.prefer[0] != "return=representation" {
		t.Fatalf("submission POST Prefer = %v", subPost.prefer)
	}
	if subPost.accept != "application/vnd.pgrst.object+json" {
		t.Fatalf("submission POST Accept = %q", subPost.accept)
	}
	var subBody map[string]any
	if err := json.Unmarshal([]byte(subPost.body), &subBody); err != nil {
		t.Fatalf("submission POST body: %v", err)
	}
	// Only the slug is sent: database triggers fill the owner from the JWT,
	// so the tool cannot address a submission to anybody else.
	if subBody["assignment_slug"] != "proj1" || len(subBody) != 1 {
		t.Fatalf("submission POST body = %v", subBody)
	}

	fieldPost := writes[1]
	if fieldPost.method != http.MethodPost || fieldPost.path != "/assignment_field_submissions" {
		t.Fatalf("second write = %s %s", fieldPost.method, fieldPost.path)
	}
	if len(fieldPost.prefer) != 1 || fieldPost.prefer[0] != "return=representation" {
		t.Fatalf("field POST Prefer = %v", fieldPost.prefer)
	}
	var fieldBody map[string]any
	if err := json.Unmarshal([]byte(fieldPost.body), &fieldBody); err != nil {
		t.Fatalf("field POST body: %v", err)
	}
	if fieldBody["assignment_submission_id"] != float64(9) ||
		fieldBody["assignment_field_slug"] != "repo-url" ||
		fieldBody["assignment_slug"] != "proj1" ||
		fieldBody["body"] != "new-value" {
		t.Fatalf("field POST body = %v", fieldBody)
	}
}

// The PATCH must carry the updated_at read moments earlier so the database's
// PT409 trigger can reject a write that races another one. Dropping it would
// turn every overwrite into a last-writer-wins clobber.
func TestSubmitHappyOverwriteSendsTheUpdatedAtItRead(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK, fixtureStoredOverwrite)
	deps := fake.deps(t)
	req, _ := writeToolRequest(t, nil)

	_, out, err := deps.submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
		// Naming the version we read is accepted when it still matches.
		ExpectedUpdatedAt: "2026-08-02T00:00:00+00:00",
	})
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	if out.Action != "overwrite" || out.SubmissionID != 7 || out.UpdatedAt != "2026-08-05T12:00:00+00:00" {
		t.Fatalf("output = %+v", out)
	}

	writes := recordedWrites(fake)
	if len(writes) != 1 {
		t.Fatalf("write requests = %d, want 1: %+v", len(writes), writes)
	}
	patch := writes[0]
	if patch.method != http.MethodPatch || patch.path != "/assignment_field_submissions" {
		t.Fatalf("write = %s %s", patch.method, patch.path)
	}
	// An unfiltered PATCH would hit every row RLS lets the caller write.
	if patch.query.Get("assignment_submission_id") != "eq.7" || patch.query.Get("assignment_field_slug") != "eq.repo-url" {
		t.Fatalf("PATCH filters = %v", patch.query)
	}
	if len(patch.prefer) != 1 || patch.prefer[0] != "return=representation" {
		t.Fatalf("PATCH Prefer = %v", patch.prefer)
	}
	var patchBody map[string]any
	if err := json.Unmarshal([]byte(patch.body), &patchBody); err != nil {
		t.Fatalf("PATCH body: %v", err)
	}
	if patchBody["body"] != "new-value" || patchBody["updated_at"] != "2026-08-02T00:00:00+00:00" {
		t.Fatalf("PATCH body = %v (must carry the updated_at just read for the PT409 check)", patchBody)
	}
}

// ---- submit: upstream failures ----

func TestSubmitMapsPT409ToStaleWriteError(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	// The DB PT409 stale-write trigger surfaces as HTTP 409 from PostgREST.
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusConflict,
		`{"message":"stale write rejected: submission last updated at ..., client expected ..."}`)
	req, _ := writeToolRequest(t, nil)

	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err == nil || !strings.Contains(err.Error(), "changed while this write was in flight") {
		t.Fatalf("PT409 mapping: %v", err)
	}
}

func TestSubmitOverwriteFilteredByRLSReturnsClearError(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	// A 200 with an empty array means RLS filtered the row out of the UPDATE,
	// e.g. the submission window closed between the read and the write.
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK, `[]`)
	req, _ := writeToolRequest(t, nil)

	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err == nil || !strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("empty PATCH result: %v", err)
	}
}

func TestSubmitSurfacesUpstreamErrorStatus(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusBadRequest,
		`{"message":"new row violates check constraint"}`)
	req, _ := writeToolRequest(t, nil)

	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "not-a-url",
	})
	if err == nil || !strings.Contains(err.Error(), "HTTP 400") || !strings.Contains(err.Error(), "check constraint") {
		t.Fatalf("upstream error mapping: %v", err)
	}
}

// PostgREST cannot span two requests in one transaction, so a create that gets
// its submission row written but its field value rejected must undo the first
// step by hand: an empty submission row is indistinguishable from a real but
// blank submission to a grader.
func TestSubmitRollsBackTheSubmissionRowWhenTheFieldWriteFails(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", "[]")
	fake.respondMethod(http.MethodPost, "/assignment_submissions", http.StatusCreated,
		`{"id":9,"assignment_slug":"proj1"}`)
	fake.respondMethod(http.MethodPost, "/assignment_field_submissions", http.StatusBadRequest,
		`{"message":"body does not match the required pattern"}`)
	fake.respondMethod(http.MethodDelete, "/assignment_submissions", http.StatusNoContent, ``)
	req, _ := writeToolRequest(t, nil)

	_, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "bad",
	})
	if err == nil || !strings.Contains(err.Error(), "required pattern") {
		t.Fatalf("expected the underlying failure to surface, got %v", err)
	}

	writes := recordedWrites(fake)
	if len(writes) != 3 {
		t.Fatalf("write requests = %d, want 3 (POST, POST, rollback DELETE): %+v", len(writes), writes)
	}
	rollback := writes[2]
	if rollback.method != http.MethodDelete || rollback.path != "/assignment_submissions" {
		t.Fatalf("rollback = %s %s", rollback.method, rollback.path)
	}
	// The DELETE must be pinned to the row just created; an unfiltered DELETE
	// would remove every submission RLS lets this student delete.
	if got := rollback.query.Get("id"); got != "eq.9" {
		t.Fatalf("rollback filter id = %q, want eq.9", got)
	}
}

// An overwrite creates no submission row, so a failed field write has nothing
// to roll back and must not issue a DELETE.
func TestSubmitDoesNotRollBackAnExistingSubmissionRow(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusBadRequest,
		`{"message":"nope"}`)
	req, _ := writeToolRequest(t, nil)

	if _, _, err := fake.deps(t).submitSubmissionChange(context.Background(), req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	}); err == nil {
		t.Fatal("expected the failed PATCH to surface as an error")
	}
	for _, write := range recordedWrites(fake) {
		if write.method == http.MethodDelete {
			t.Fatalf("a failed overwrite deleted a pre-existing submission row: %+v", write)
		}
	}
}

func TestMapWriteError(t *testing.T) {
	if err := mapWriteError(http.StatusConflict, []byte(`{"message":"PT409"}`)); err != errStaleSubmission {
		t.Fatalf("409 mapped to %v, want errStaleSubmission", err)
	}
	err := mapWriteError(http.StatusForbidden, []byte(`{"message":"permission denied"}`))
	if err == errStaleSubmission || !strings.Contains(err.Error(), "HTTP 403") {
		t.Fatalf("403 mapped to %v", err)
	}
}

// ---- end to end over the streamable HTTP stack ----

// TestSubmissionWriteOverStreamableHTTP drives preview then submit through the
// real transport with an ordinary client that offers no elicitation handler.
// That client is the point of the test: writes are now gated by the write
// scope alone, so a client that cannot prompt its user must still be able to
// complete a write it was authorized for, and a read-only token must still be
// refused.
func TestSubmissionWriteOverStreamableHTTP(t *testing.T) {
	server, fake, _, _ := newTestAppWithPostgREST(t, testAppConfig(t, 100))
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK, fixtureStoredOverwrite)

	connect := func(t *testing.T, scopes []string) *mcp.ClientSession {
		t.Helper()
		token := accessToken(t, func(claims map[string]any) {
			claims["scopes"] = scopes
		})
		client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.1"}, nil)
		session, err := client.Connect(context.Background(), &mcp.StreamableClientTransport{
			Endpoint:   server.URL + mcpPath,
			HTTPClient: &http.Client{Transport: authTransport{token: token}},
		}, nil)
		if err != nil {
			t.Fatalf("connect: %v", err)
		}
		t.Cleanup(func() { _ = session.Close() })
		return session
	}
	arguments := map[string]any{
		"assignment_slug": "proj1",
		"field_slug":      "repo-url",
		"body":            "new-value",
	}
	ctx := context.Background()

	// A read-only caller can see what the write would do but cannot do it.
	readOnly := connect(t, []string{"read"})
	previewed, err := readOnly.CallTool(ctx, &mcp.CallToolParams{Name: "preview_submission_change", Arguments: arguments})
	if err != nil {
		t.Fatalf("preview call: %v", err)
	}
	if previewed.IsError {
		t.Fatalf("preview tool error: %+v", previewed.Content)
	}
	var previewOut previewSubmissionChangeOutput
	raw, _ := json.Marshal(previewed.StructuredContent)
	if err := json.Unmarshal(raw, &previewOut); err != nil {
		t.Fatalf("decode preview output: %v", err)
	}
	if previewOut.Action != "overwrite" || previewOut.CurrentBody != "old-value" {
		t.Fatalf("preview output = %+v", previewOut)
	}

	refused, err := readOnly.CallTool(ctx, &mcp.CallToolParams{Name: "submit_submission_change", Arguments: arguments})
	if err != nil {
		t.Fatalf("submit call: %v", err)
	}
	if !refused.IsError {
		t.Fatal("a read-only token must not be able to submit")
	}
	if text := resultText(refused); !strings.Contains(text, "scope") {
		t.Fatalf("refusal text = %q", text)
	}
	if countWrites(fake) != 0 {
		t.Fatalf("a refused submit reached PostgREST: %+v", fake.recorded())
	}

	// The same call with the write scope succeeds, with no confirmation
	// round trip of any kind.
	writer := connect(t, []string{"read", "write"})
	committed, err := writer.CallTool(ctx, &mcp.CallToolParams{
		Name:      "submit_submission_change",
		Arguments: mergeArguments(arguments, "expected_updated_at", previewOut.CurrentUpdatedAt),
	})
	if err != nil {
		t.Fatalf("submit call: %v", err)
	}
	if committed.IsError {
		t.Fatalf("submit tool error: %+v", committed.Content)
	}
	var submitOut submitSubmissionChangeOutput
	raw, _ = json.Marshal(committed.StructuredContent)
	if err := json.Unmarshal(raw, &submitOut); err != nil {
		t.Fatalf("decode submit output: %v", err)
	}
	if submitOut.Action != "overwrite" || submitOut.SubmissionID != 7 || submitOut.Body != "new-value" {
		t.Fatalf("submit output = %+v", submitOut)
	}
	if countWrites(fake) != 1 {
		t.Fatalf("write count = %d, want exactly 1: %+v", countWrites(fake), fake.recorded())
	}
}

// mergeArguments copies a tool argument map with one extra entry, so the
// shared base map is not mutated between calls.
func mergeArguments(base map[string]any, key string, value any) map[string]any {
	merged := make(map[string]any, len(base)+1)
	for k, v := range base {
		merged[k] = v
	}
	merged[key] = value
	return merged
}

// recordedWrites returns the non-GET requests the fake saw, in order.
func recordedWrites(fake *fakePostgREST) []pgRequest {
	var writes []pgRequest
	for _, r := range fake.recorded() {
		if r.method != http.MethodGet {
			writes = append(writes, r)
		}
	}
	return writes
}

// countWrites counts non-GET requests recorded by the fake.
func countWrites(fake *fakePostgREST) int {
	return len(recordedWrites(fake))
}

// resultText flattens a tool result's text content for assertions.
func resultText(result *mcp.CallToolResult) string {
	var b strings.Builder
	for _, content := range result.Content {
		if text, ok := content.(*mcp.TextContent); ok {
			b.WriteString(text.Text)
		}
	}
	return b.String()
}
