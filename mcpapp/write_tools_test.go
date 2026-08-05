package main

// Tests for the prepare/commit write flow (issue #267) against the fake
// PostgREST: scope gating, size limits, create-vs-overwrite detection, intent
// token binding, exact write requests (methods, Prefer headers, updated_at),
// stale-write mapping, replay, and the prompt-injection regression.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	fixturePrepareAssignment = `[{"slug":"proj1","title":"Project 1","is_team":false,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","fields":[{"slug":"repo-url"},{"slug":"essay"}]}]`

	fixturePrepareTeamAssignment = `[{"slug":"team-proj","title":"Team Project","is_team":true,"is_draft":false,"is_open":true,"closed_at":"2026-09-01T00:00:00+00:00","fields":[{"slug":"repo-url"}]}]`

	fixtureClosedAssignment = `[{"slug":"proj1","title":"Project 1","is_team":false,"is_draft":false,"is_open":false,"closed_at":"2026-01-01T00:00:00+00:00","fields":[{"slug":"repo-url"}]}]`

	fixtureExistingSubmission = `[{"id":7,"fields":[{"assignment_field_slug":"repo-url","body":"old-value","updated_at":"2026-08-02T00:00:00+00:00"}]}]`

	fixtureSubmissionWithoutField = `[{"id":7,"fields":[]}]`
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

// decodeIntentToken decodes (without verifying) the payload segment.
func decodeIntentToken(t *testing.T, token string) intentPayload {
	t.Helper()
	dot := strings.IndexByte(token, '.')
	if dot < 0 {
		t.Fatalf("intent token has no signature segment: %q", token)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token[:dot])
	if err != nil {
		t.Fatalf("decode intent token payload: %v", err)
	}
	var payload intentPayload
	if err := json.Unmarshal(decoded, &payload); err != nil {
		t.Fatalf("unmarshal intent token payload: %v", err)
	}
	return payload
}

// ---- prepare: scope gating ----

func TestPrepareSubmissionChangeScopeDenials(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{name: "no scopes claim (default deny)", mutate: nil},
		{name: "empty scopes claim", mutate: func(c map[string]any) { c["scopes"] = []string{} }},
		{name: "read-only scopes", mutate: func(c map[string]any) { c["scopes"] = []string{"read"} }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			req, _ := readToolRequest(t, tt.mutate)
			_, _, err := fake.deps(t).prepareSubmissionChange(context.Background(), req, prepareSubmissionChangeInput{
				AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x",
			})
			if err == nil || !strings.Contains(err.Error(), "scope") && !strings.Contains(err.Error(), "denied") {
				t.Fatalf("expected a scope denial, got %v", err)
			}
			if len(fake.recorded()) != 0 {
				t.Fatal("scope-denied prepare must not reach PostgREST")
			}
		})
	}
}

// ---- prepare: validation ----

func TestPrepareSubmissionChangeRejectsOversizedBody(t *testing.T) {
	fake := newFakePostgREST(t)
	req, _ := writeToolRequest(t, nil)
	_, _, err := fake.deps(t).prepareSubmissionChange(context.Background(), req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url",
		Body: strings.Repeat("a", maxSubmissionWriteBytes+1),
	})
	if err == nil || !strings.Contains(err.Error(), "64KB") {
		t.Fatalf("expected a size error, got %v", err)
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("oversized body must be rejected before any PostgREST call")
	}
}

func TestPrepareSubmissionChangeRejectsBadInputs(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", "[]")
	req, _ := writeToolRequest(t, nil)
	deps := fake.deps(t)
	ctx := context.Background()

	if _, _, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{AssignmentSlug: "BAD SLUG", FieldSlug: "repo-url", Body: "x"}); err == nil {
		t.Fatal("bad assignment slug accepted")
	}
	if _, _, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "NOPE", Body: "x"}); err == nil {
		t.Fatal("bad field slug accepted")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("invalid slugs must not reach PostgREST")
	}
	if _, _, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "no-such-field", Body: "x"}); err == nil || !strings.Contains(err.Error(), "no field") {
		t.Fatalf("unknown field: %v", err)
	}
	if _, _, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x", ExpectedUpdatedAt: "2026-01-01T00:00:00+00:00"}); err == nil || !strings.Contains(err.Error(), "no existing value") {
		t.Fatalf("expected_updated_at with no existing row: %v", err)
	}
}

func TestPrepareSubmissionChangeStaleExpectedUpdatedAt(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	req, _ := writeToolRequest(t, nil)
	_, _, err := fake.deps(t).prepareSubmissionChange(context.Background(), req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x",
		ExpectedUpdatedAt: "2020-01-01T00:00:00+00:00",
	})
	if err == nil || !strings.Contains(err.Error(), "changed since") {
		t.Fatalf("expected a stale error, got %v", err)
	}
}

func TestPrepareTeamAssignmentWithoutTeam(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareTeamAssignment)
	fake.respond("/users", fixtureUserRowsNoTeam)
	req, _ := writeToolRequest(t, nil)
	_, _, err := fake.deps(t).prepareSubmissionChange(context.Background(), req, prepareSubmissionChangeInput{
		AssignmentSlug: "team-proj", FieldSlug: "repo-url", Body: "x",
	})
	if err == nil || !strings.Contains(err.Error(), "not on a team") {
		t.Fatalf("expected a team error, got %v", err)
	}
}

// ---- prepare: create vs overwrite and intent token contents ----

func TestPrepareSubmissionChangeCreateVsOverwrite(t *testing.T) {
	tests := []struct {
		name             string
		submissions      string
		wantAction       string
		wantCreatesSub   bool
		wantExpected     string
		wantSubmissionID int
		wantCurrentBody  string
		wantChanged      bool
	}{
		{
			name:             "no submission row: create both",
			submissions:      "[]",
			wantAction:       "create",
			wantCreatesSub:   true,
			wantExpected:     intentExpectedCreate,
			wantSubmissionID: 0,
			wantChanged:      true,
		},
		{
			name:             "submission exists, field missing: create field",
			submissions:      fixtureSubmissionWithoutField,
			wantAction:       "create",
			wantCreatesSub:   false,
			wantExpected:     intentExpectedCreate,
			wantSubmissionID: 7,
			wantChanged:      true,
		},
		{
			name:             "field exists: overwrite",
			submissions:      fixtureExistingSubmission,
			wantAction:       "overwrite",
			wantCreatesSub:   false,
			wantExpected:     "2026-08-02T00:00:00+00:00",
			wantSubmissionID: 7,
			wantCurrentBody:  "old-value",
			wantChanged:      true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			fake.respond("/assignments", fixturePrepareAssignment)
			fake.respond("/assignment_submissions", tt.submissions)
			req, _ := writeToolRequest(t, nil)

			_, out, err := fake.deps(t).prepareSubmissionChange(context.Background(), req, prepareSubmissionChangeInput{
				AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
			})
			if err != nil {
				t.Fatalf("prepare: %v", err)
			}
			if out.Action != tt.wantAction || out.CreatesSubmission != tt.wantCreatesSub {
				t.Fatalf("action = %q creates_submission = %v, want %q/%v", out.Action, out.CreatesSubmission, tt.wantAction, tt.wantCreatesSub)
			}
			if out.CurrentBody != tt.wantCurrentBody {
				t.Fatalf("current_body = %q, want %q", out.CurrentBody, tt.wantCurrentBody)
			}
			if out.Changed != tt.wantChanged {
				t.Fatalf("changed = %v", out.Changed)
			}
			if out.ProposedBody != "new-value" || out.ProposedLengthBytes != len("new-value") {
				t.Fatalf("proposed = %q (%d bytes)", out.ProposedBody, out.ProposedLengthBytes)
			}
			if out.IntentToken == "" || out.IntentExpiresAt == "" || out.Instructions == "" {
				t.Fatalf("summary envelope incomplete: %+v", out)
			}

			payload := decodeIntentToken(t, out.IntentToken)
			if payload.Kind != intentKindSubmission {
				t.Fatalf("kind = %q", payload.Kind)
			}
			if payload.Subject != "user:42" || payload.TokenJTI != "0b6f1625-3f39-4a12-9c4e-9ce67a9b6f37" {
				t.Fatalf("caller binding = %q/%q", payload.Subject, payload.TokenJTI)
			}
			if payload.AssignmentSlug != "proj1" || payload.FieldSlug != "repo-url" {
				t.Fatalf("target binding = %+v", payload)
			}
			if payload.BodySHA256 != sha256Hex("new-value") {
				t.Fatalf("body hash = %q", payload.BodySHA256)
			}
			if payload.Expected != tt.wantExpected {
				t.Fatalf("expected = %q, want %q", payload.Expected, tt.wantExpected)
			}
			if payload.SubmissionID != tt.wantSubmissionID || payload.CreateSubmission != tt.wantCreatesSub {
				t.Fatalf("submission binding = %d/%v", payload.SubmissionID, payload.CreateSubmission)
			}
		})
	}
}

func TestPrepareSubmissionChangeUnchangedAndClosedWarnings(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixtureClosedAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	req, _ := writeToolRequest(t, nil)
	_, out, err := fake.deps(t).prepareSubmissionChange(context.Background(), req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "old-value",
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if out.Changed {
		t.Fatal("identical body must report changed=false")
	}
	if out.AssignmentIsOpen {
		t.Fatal("closed assignment must report assignment_is_open=false")
	}
	if !strings.Contains(out.Warning, "not currently open") || !strings.Contains(out.Warning, "identical") {
		t.Fatalf("warning = %q", out.Warning)
	}
}

// ---- commit: happy paths with exact PostgREST requests ----

func TestCommitHappyCreateIncludingSubmissionRow(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", "[]")
	fake.respondMethod(http.MethodPost, "/assignment_submissions", http.StatusCreated,
		`{"id":9,"assignment_slug":"proj1","is_team":false,"user_id":42}`)
	fake.respondMethod(http.MethodPost, "/assignment_field_submissions", http.StatusCreated,
		`{"assignment_submission_id":9,"assignment_field_slug":"repo-url","assignment_slug":"proj1","body":"new-value","created_at":"2026-08-05T00:00:00+00:00","updated_at":"2026-08-05T00:00:00+00:00"}`)
	deps := fake.deps(t)
	req, token := writeToolRequest(t, nil)
	ctx := context.Background()

	_, prepared, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	prepareCalls := len(fake.recorded())

	_, out, err := deps.commitSubmissionChange(ctx, confirmWrite(req), commitSubmissionChangeInput{
		IntentToken: prepared.IntentToken, Body: "new-value",
	})
	if err != nil {
		t.Fatalf("commit: %v", err)
	}
	if out.Action != "create" || out.SubmissionID != 9 || out.Body != "new-value" {
		t.Fatalf("output = %+v", out)
	}

	writes := fake.recorded()[prepareCalls:]
	if len(writes) != 2 {
		t.Fatalf("write requests = %d, want 2: %+v", len(writes), writes)
	}

	subPost := writes[0]
	if subPost.method != http.MethodPost || subPost.path != "/assignment_submissions" {
		t.Fatalf("first write = %s %s", subPost.method, subPost.path)
	}
	if subPost.auth != "Bearer "+token {
		t.Fatal("submission POST did not forward the caller's token")
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

func TestCommitHappyOverwriteSendsExpectedUpdatedAt(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK,
		`[{"assignment_submission_id":7,"assignment_field_slug":"repo-url","assignment_slug":"proj1","body":"new-value","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-05T12:00:00+00:00"}]`)
	deps := fake.deps(t)
	req, _ := writeToolRequest(t, nil)
	ctx := context.Background()

	_, prepared, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	prepareCalls := len(fake.recorded())

	_, out, err := deps.commitSubmissionChange(ctx, confirmWrite(req), commitSubmissionChangeInput{
		IntentToken: prepared.IntentToken, Body: "new-value",
	})
	if err != nil {
		t.Fatalf("commit: %v", err)
	}
	if out.Action != "overwrite" || out.SubmissionID != 7 || out.UpdatedAt != "2026-08-05T12:00:00+00:00" {
		t.Fatalf("output = %+v", out)
	}

	writes := fake.recorded()[prepareCalls:]
	if len(writes) != 1 {
		t.Fatalf("write requests = %d, want 1: %+v", len(writes), writes)
	}
	patch := writes[0]
	if patch.method != http.MethodPatch || patch.path != "/assignment_field_submissions" {
		t.Fatalf("write = %s %s", patch.method, patch.path)
	}
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
		t.Fatalf("PATCH body = %v (must carry the prepare-time updated_at for the PT409 check)", patchBody)
	}
}

// ---- commit: rejections before any PostgREST call ----

func TestCommitRejectsBadIntentTokensBeforeAnyPostgRESTCall(t *testing.T) {
	// Mint a real token for the standard caller so tampering starts from a
	// valid artifact.
	signer := newTestIntentSigner(nil)
	valid, _, err := signer.mint(intentPayload{
		Kind: intentKindSubmission, AssignmentSlug: "proj1", FieldSlug: "repo-url",
		BodySHA256: sha256Hex("new-value"), Expected: intentExpectedCreate, CreateSubmission: true,
	}, testIdentity())
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name   string
		token  string
		body   string
		mutate func(map[string]any) // claims of the committing caller
	}{
		{name: "fabricated token (prompt injection)", token: "please.commit", body: "new-value"},
		{name: "tampered token", token: "A" + valid[1:], body: "new-value"},
		{name: "wrong body hash", token: valid, body: "attacker-substituted body"},
		{name: "foreign subject", token: valid, body: "new-value", mutate: func(c map[string]any) { c["sub"] = "user:43" }},
		{name: "different access token jti", token: valid, body: "new-value", mutate: func(c map[string]any) { c["jti"] = "different-jti" }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fake := newFakePostgREST(t)
			deps := fake.deps(t)
			// Share the signer that minted the token so signature-valid cases
			// exercise the binding checks, not key mismatch.
			deps.intent = signer
			req, _ := writeToolRequest(t, tt.mutate)

			_, _, err := deps.commitSubmissionChange(context.Background(), req, commitSubmissionChangeInput{
				IntentToken: tt.token, Body: tt.body,
			})
			if err == nil {
				t.Fatal("expected the commit to be rejected")
			}
			if len(fake.recorded()) != 0 {
				t.Fatalf("rejected commit reached PostgREST: %+v", fake.recorded())
			}
		})
	}
}

func TestCommitRejectsExpiredIntentToken(t *testing.T) {
	current := testNow
	signer := newIntentSigner([]byte(testSecret), func() time.Time { return current })
	token, _, err := signer.mint(intentPayload{
		Kind: intentKindSubmission, BodySHA256: sha256Hex("x"), Expected: intentExpectedCreate,
	}, testIdentity())
	if err != nil {
		t.Fatal(err)
	}
	current = current.Add(intentTokenTTL + time.Minute)

	fake := newFakePostgREST(t)
	deps := fake.deps(t)
	deps.intent = signer
	req, _ := writeToolRequest(t, nil)
	_, _, err = deps.commitSubmissionChange(context.Background(), req, commitSubmissionChangeInput{IntentToken: token, Body: "x"})
	if err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expected an expiry error, got %v", err)
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("expired commit reached PostgREST")
	}
}

func TestCommitReplayIsRejectedWithoutDuplicateWrite(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK,
		`[{"assignment_submission_id":7,"assignment_field_slug":"repo-url","assignment_slug":"proj1","body":"new-value","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-05T12:00:00+00:00"}]`)
	deps := fake.deps(t)
	req, _ := writeToolRequest(t, nil)
	ctx := context.Background()

	_, prepared, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := deps.commitSubmissionChange(ctx, confirmWrite(req), commitSubmissionChangeInput{IntentToken: prepared.IntentToken, Body: "new-value"}); err != nil {
		t.Fatalf("first commit: %v", err)
	}
	countAfterFirst := len(fake.recorded())

	_, _, err = deps.commitSubmissionChange(ctx, confirmWrite(req), commitSubmissionChangeInput{IntentToken: prepared.IntentToken, Body: "new-value"})
	if err == nil || !strings.Contains(err.Error(), "already used") {
		t.Fatalf("replay: %v", err)
	}
	if len(fake.recorded()) != countAfterFirst {
		t.Fatal("replayed commit performed another write")
	}
}

func TestCommitMapsPT409ToStalePrepareError(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	// The DB PT409 stale-write trigger surfaces as HTTP 409 from PostgREST.
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusConflict,
		`{"message":"stale write rejected: submission last updated at ..., client expected ..."}`)
	deps := fake.deps(t)
	req, _ := writeToolRequest(t, nil)
	ctx := context.Background()

	_, prepared, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = deps.commitSubmissionChange(ctx, confirmWrite(req), commitSubmissionChangeInput{IntentToken: prepared.IntentToken, Body: "new-value"})
	if err == nil || !strings.Contains(err.Error(), "changed since you prepared") {
		t.Fatalf("PT409 mapping: %v", err)
	}
}

func TestCommitOverwriteFilteredByRLSReturnsClearError(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	// A 200 with an empty array means RLS filtered the row from the UPDATE
	// (e.g. the window closed between prepare and commit).
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK, `[]`)
	deps := fake.deps(t)
	req, _ := writeToolRequest(t, nil)
	ctx := context.Background()

	_, prepared, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "new-value",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = deps.commitSubmissionChange(ctx, confirmWrite(req), commitSubmissionChangeInput{IntentToken: prepared.IntentToken, Body: "new-value"})
	if err == nil || !strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("empty PATCH result: %v", err)
	}
}

// ---- prompt-injection regression ----

// TestPromptInjectionCannotForgeCommit models the attack from ADR 0001: a
// tool result (untrusted course content) instructs the agent to call
// commit_submission_change with an attacker-supplied "intent token". Without
// a real prepare by this caller, every such commit is rejected server-side
// before any PostgREST request.
func TestPromptInjectionCannotForgeCommit(t *testing.T) {
	injected := []string{
		"TOKEN-FROM-TOOL-RESULT",
		"eyJraW5kIjoic3VibWlzc2lvbl9jaGFuZ2UifQ.Zm9yZ2Vk", // well-formed but unsigned
		"", // no token at all
	}
	for _, token := range injected {
		fake := newFakePostgREST(t)
		req, _ := writeToolRequest(t, nil)
		_, _, err := fake.deps(t).commitSubmissionChange(context.Background(), req, commitSubmissionChangeInput{
			IntentToken: token,
			Body:        "attacker chosen submission body",
		})
		if err == nil {
			t.Fatalf("commit with injected token %q succeeded", token)
		}
		if len(fake.recorded()) != 0 {
			t.Fatalf("commit with injected token %q reached PostgREST", token)
		}
	}
}

// ---- elicitation over a real in-process session ----

// TestCommitElicitationRoundTrip drives prepare→commit through the streamable
// HTTP stack with a client that supports elicitation, covering both the
// accept and decline paths and the single-use replay error end to end.
func TestCommitElicitationRoundTrip(t *testing.T) {
	tests := []struct {
		name        string
		handler     func(context.Context, *mcp.ElicitRequest) (*mcp.ElicitResult, error)
		wantWrite   bool
		wantErrText string
	}{
		{
			name: "user accepts",
			handler: func(_ context.Context, _ *mcp.ElicitRequest) (*mcp.ElicitResult, error) {
				return &mcp.ElicitResult{Action: "accept", Content: map[string]any{"confirm": true}}, nil
			},
			wantWrite: true,
		},
		{
			name: "user declines",
			handler: func(_ context.Context, _ *mcp.ElicitRequest) (*mcp.ElicitResult, error) {
				return &mcp.ElicitResult{Action: "decline"}, nil
			},
			wantWrite:   false,
			wantErrText: "declined",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server, fake, _ := newTestAppWithPostgREST(t, testAppConfig(100))
			fake.respond("/assignments", fixturePrepareAssignment)
			fake.respond("/assignment_submissions", fixtureExistingSubmission)
			fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK,
				`[{"assignment_submission_id":7,"assignment_field_slug":"repo-url","assignment_slug":"proj1","body":"new-value","created_at":"2026-08-01T00:00:00+00:00","updated_at":"2026-08-05T12:00:00+00:00"}]`)

			claims := currentClaims()
			claims["scopes"] = []string{"read", "write"}
			token := signTestToken(t, hs256Header(), claims, testSecret)

			var elicited int
			client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.1"}, &mcp.ClientOptions{
				ElicitationHandler: func(ctx context.Context, req *mcp.ElicitRequest) (*mcp.ElicitResult, error) {
					elicited++
					if req.Params.Message == "" {
						t.Error("elicitation message is empty")
					}
					return tt.handler(ctx, req)
				},
			})
			ctx := context.Background()
			session, err := client.Connect(ctx, &mcp.StreamableClientTransport{
				Endpoint:   server.URL + mcpPath,
				HTTPClient: &http.Client{Transport: authTransport{token: token}},
			}, nil)
			if err != nil {
				t.Fatalf("connect: %v", err)
			}
			defer session.Close()

			prepared, err := session.CallTool(ctx, &mcp.CallToolParams{
				Name: "prepare_submission_change",
				Arguments: map[string]any{
					"assignment_slug": "proj1",
					"field_slug":      "repo-url",
					"body":            "new-value",
				},
			})
			if err != nil {
				t.Fatalf("prepare call: %v", err)
			}
			if prepared.IsError {
				t.Fatalf("prepare tool error: %+v", prepared.Content)
			}
			var prepareOut prepareSubmissionChangeOutput
			raw, _ := json.Marshal(prepared.StructuredContent)
			if err := json.Unmarshal(raw, &prepareOut); err != nil {
				t.Fatalf("decode prepare output: %v", err)
			}
			if prepareOut.Action != "overwrite" || prepareOut.CurrentBody != "old-value" {
				t.Fatalf("prepare output = %+v", prepareOut)
			}
			writesBefore := countWrites(fake)

			committed, err := session.CallTool(ctx, &mcp.CallToolParams{
				Name: "commit_submission_change",
				Arguments: map[string]any{
					"intent_token": prepareOut.IntentToken,
					"body":         "new-value",
				},
			})
			if err != nil {
				t.Fatalf("commit call: %v", err)
			}
			if elicited != 1 {
				t.Fatalf("elicitation requests = %d, want 1", elicited)
			}
			wrote := countWrites(fake) > writesBefore
			if tt.wantWrite {
				if committed.IsError {
					t.Fatalf("commit tool error: %+v", committed.Content)
				}
				if !wrote {
					t.Fatal("accepted commit performed no write")
				}
				// Replay of the same single-use token fails cleanly.
				replayed, err := session.CallTool(ctx, &mcp.CallToolParams{
					Name: "commit_submission_change",
					Arguments: map[string]any{
						"intent_token": prepareOut.IntentToken,
						"body":         "new-value",
					},
				})
				if err != nil {
					t.Fatalf("replay call: %v", err)
				}
				if !replayed.IsError {
					t.Fatal("replayed intent token must produce a tool error")
				}
				if text := resultText(replayed); !strings.Contains(text, "already used") {
					t.Fatalf("replay error = %q", text)
				}
			} else {
				if !committed.IsError {
					t.Fatal("declined commit must produce a tool error")
				}
				if text := resultText(committed); !strings.Contains(text, tt.wantErrText) {
					t.Fatalf("declined error = %q", text)
				}
				if wrote {
					t.Fatal("declined commit still performed a write")
				}
			}
		})
	}
}

// countWrites counts non-GET requests recorded by the fake.
func countWrites(fake *fakePostgREST) int {
	count := 0
	for _, r := range fake.recorded() {
		if r.method != http.MethodGet {
			count++
		}
	}
	return count
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

// confirmWrite attaches an accepted confirmation to a request, standing in
// for the user having answered the elicitation.
func confirmWrite(req *mcp.CallToolRequest) *mcp.CallToolRequest {
	confirmed := *req
	params := &mcp.CallToolParamsRaw{}
	if confirmed.Params != nil {
		copied := *confirmed.Params
		params = &copied
	}
	params.InputResponses = mcp.InputResponseMap{
		confirmationInputID: &mcp.ElicitResult{
			Action:  "accept",
			Content: map[string]any{"confirm": true},
		},
	}
	confirmed.Params = params
	return &confirmed
}

// Writes must fail closed when the client cannot show the user a
// confirmation: an injected agent could otherwise call prepare and commit
// back to back with no human ever seeing the change.
func TestCommitWithoutConfirmationChannelIsRefused(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixturePrepareAssignment)
	fake.respond("/assignment_submissions", fixtureExistingSubmission)
	deps := fake.deps(t)
	req, _ := writeToolRequest(t, nil)
	ctx := context.Background()

	_, prepared, err := deps.prepareSubmissionChange(ctx, req, prepareSubmissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "injected-value",
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	before := len(fake.recorded())

	_, _, err = deps.commitSubmissionChange(ctx, req, commitSubmissionChangeInput{
		IntentToken: prepared.IntentToken, Body: "injected-value",
	})
	if !errors.Is(err, errWriteConfirmationUnsupported) {
		t.Fatalf("expected the write to be refused, got: %v", err)
	}
	if len(fake.recorded()) != before {
		t.Fatal("no write may reach the API without confirmation")
	}
}
