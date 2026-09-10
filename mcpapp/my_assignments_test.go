package main

// Tests for the api.my_assignments reads (issue #381): the three assignment
// tools agree on the caller's eligibility, an extension is either a complete
// object or null, fractional credit stays numeric, a long submissions array is
// cut explicitly, and the server instructions tell the model which fields to
// trust.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestAssignmentToolsAgreeOnEligibility(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/my_assignments", fixtureAssignments)
	fake.respond("/assignments", fixtureAssignmentDetail)
	fake.respond("/assignment_grade_distributions", "[]")
	fake.respond("/assignment_submissions", "[]")
	req, _ := readToolRequest(t, nil)
	deps := fake.deps(t)
	ctx := context.Background()

	_, list, err := deps.listAssignments(ctx, req, nil)
	if err != nil {
		t.Fatalf("list_assignments: %v", err)
	}
	_, detail, err := deps.getAssignment(ctx, req, getAssignmentInput{Slug: "proj1"})
	if err != nil {
		t.Fatalf("get_assignment: %v", err)
	}
	_, preview, err := deps.previewSubmissionChange(ctx, req, submissionChangeInput{
		AssignmentSlug: "proj1", FieldSlug: "repo-url", Body: "x",
	})
	if err != nil {
		t.Fatalf("preview_submission_change: %v", err)
	}

	want := assignmentEligibility{
		EffectiveClosedAt:    "2026-09-05T00:00:00+00:00",
		SubmissionWindowOpen: true,
		CanSubmit:            true,
		Extension:            &assignmentExtension{ClosedAt: "2026-09-05T00:00:00+00:00", FractionalCredit: 0.8},
	}
	for name, got := range map[string]assignmentEligibility{
		"list_assignments":          list.Assignments[0].assignmentEligibility,
		"get_assignment":            detail.assignmentEligibility,
		"preview_submission_change": preview.assignmentEligibility,
	} {
		if got.EffectiveClosedAt != want.EffectiveClosedAt || got.CanSubmit != want.CanSubmit ||
			got.SubmissionWindowOpen != want.SubmissionWindowOpen || got.CanSubmitReason != "" {
			t.Errorf("%s eligibility = %+v, want %+v", name, got, want)
		}
		if got.Extension == nil || *got.Extension != *want.Extension {
			t.Errorf("%s extension = %+v, want %+v", name, got.Extension, want.Extension)
		}
	}
	// The assignment's own deadline is still reported as it was, so the
	// switch changes no existing field's meaning.
	if list.Assignments[0].IsOpen || list.Assignments[0].ClosedAt != "2026-09-01T00:00:00+00:00" {
		t.Errorf("list is_open/closed_at = %v/%q", list.Assignments[0].IsOpen, list.Assignments[0].ClosedAt)
	}
	// An eligible caller gets no eligibility warning, extension or not.
	if preview.Warning != "" {
		t.Errorf("preview warning = %q, want none", preview.Warning)
	}
	// The detail carries the caller's submissions with grades, newest first.
	if len(detail.Submissions) != 2 || detail.Submissions[0].ID != 9 || detail.Submissions[1].ID != 7 {
		t.Fatalf("submissions = %+v", detail.Submissions)
	}
	if grade := detail.Submissions[0].Grade; grade == nil || grade.Points != 8 || grade.Description != "late but fine" {
		t.Errorf("newest grade = %+v", grade)
	}
	if detail.Submissions[1].Grade != nil || detail.Submissions[1].TeamNickname != "team-one" {
		t.Errorf("older submission = %+v", detail.Submissions[1])
	}
}

// fractional_credit is numeric upstream and must reach the agent as a JSON
// number, not a string it would have to parse.
func TestExtensionFractionalCreditIsANumber(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/my_assignments", fixtureAssignments)
	req, _ := readToolRequest(t, nil)

	_, out, err := fake.deps(t).listAssignments(context.Background(), req, nil)
	if err != nil {
		t.Fatalf("list_assignments: %v", err)
	}
	encoded, err := json.Marshal(out.Assignments[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"extension":{"closed_at":"2026-09-05T00:00:00+00:00","fractional_credit":0.8}`) {
		t.Fatalf("extension is not a numeric object: %s", encoded)
	}
	if strings.Contains(string(encoded), `"can_submit_reason"`) {
		t.Fatalf("an eligible row must omit can_submit_reason: %s", encoded)
	}
}

func TestExtensionAbsentIsNull(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/my_assignments", fixtureAssignmentsNoExtension)
	fake.respond("/assignments", fixtureAssignmentDetail)
	fake.respond("/assignment_grade_distributions", "[]")
	req, _ := readToolRequest(t, nil)
	deps := fake.deps(t)
	ctx := context.Background()

	_, list, err := deps.listAssignments(ctx, req, nil)
	if err != nil {
		t.Fatalf("list_assignments: %v", err)
	}
	if list.Assignments[0].Extension != nil || list.Assignments[0].EffectiveClosedAt != "2026-09-01T00:00:00+00:00" {
		t.Fatalf("eligibility = %+v", list.Assignments[0].assignmentEligibility)
	}
	encoded, err := json.Marshal(list.Assignments[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"extension":null`) {
		t.Fatalf("a missing extension must serialize as null, not be omitted: %s", encoded)
	}

	_, detail, err := deps.getAssignment(ctx, req, getAssignmentInput{Slug: "proj1"})
	if err != nil {
		t.Fatalf("get_assignment: %v", err)
	}
	encoded, err = json.Marshal(detail)
	if err != nil {
		t.Fatal(err)
	}
	if detail.Extension != nil || !strings.Contains(string(encoded), `"submissions":[]`) {
		t.Fatalf("detail without submissions must carry an empty array: %s", encoded)
	}
}

func TestEligibilityWarning(t *testing.T) {
	extension := &assignmentExtension{ClosedAt: "2026-09-05T00:00:00+00:00", FractionalCredit: 0.8}
	tests := []struct {
		name string
		in   assignmentEligibility
		want []string
	}{
		{name: "eligible", in: assignmentEligibility{CanSubmit: true}, want: nil},
		{name: "eligible under extension", in: assignmentEligibility{CanSubmit: true, Extension: extension}, want: nil},
		{name: "draft", in: assignmentEligibility{CanSubmitReason: "draft"}, want: []string{"draft", "reject"}},
		{name: "no team", in: assignmentEligibility{CanSubmitReason: "no_team"}, want: []string{"not on a team", "reject"}},
		{
			name: "deadline passed",
			in:   assignmentEligibility{CanSubmitReason: "deadline_passed", EffectiveClosedAt: "2026-01-01T00:00:00+00:00"},
			want: []string{"deadline passed at 2026-01-01T00:00:00+00:00", "reject"},
		},
		{
			name: "extended deadline passed",
			in:   assignmentEligibility{CanSubmitReason: "deadline_passed", EffectiveClosedAt: "2026-09-05T00:00:00+00:00", Extension: extension},
			want: []string{"deadline passed at 2026-09-05T00:00:00+00:00", "extended deadline", "reject"},
		},
		{name: "unknown reason", in: assignmentEligibility{CanSubmitReason: "something_new"}, want: []string{"not currently eligible", "reject"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := eligibilityWarning(tt.in)
			if tt.want == nil && got != "" {
				t.Fatalf("eligibilityWarning(%+v) = %q, want none", tt.in, got)
			}
			for _, want := range tt.want {
				if !strings.Contains(got, want) {
					t.Errorf("eligibilityWarning(%+v) = %q, missing %q", tt.in, got, want)
				}
			}
		})
	}
}

// A student with many submissions (or a grader who writes essays) must not
// push get_assignment past the cap, and whatever is cut is announced: a
// partial submissions array is never presented as the whole.
func TestGetAssignmentTruncatesOversizedSubmissionsExplicitly(t *testing.T) {
	subs := make([]string, 0, 400)
	for i := range 400 {
		subs = append(subs, fmt.Sprintf(
			`{"id":%d,"team_nickname":null,"created_at":"2026-09-02T00:00:00+00:00","updated_at":"2026-09-02T00:00:00+00:00","fields_submitted":1,"fields_total":1,"grade":{"points":8,"description":%q,"created_at":"2026-09-06T00:00:00+00:00"}}`,
			1000-i, strings.Repeat("d", maxDescriptionChars+500)))
	}
	row := strings.Replace(fixtureAssignmentsNoExtension, `"submissions":[]`, `"submissions":[`+strings.Join(subs, ",")+`]`, 1)
	fake := newFakePostgREST(t)
	fake.respond("/assignments", fixtureAssignmentDetail)
	fake.respond("/my_assignments", row)
	fake.respond("/assignment_grade_distributions", "[]")
	req, _ := readToolRequest(t, nil)

	_, out, err := fake.deps(t).getAssignment(context.Background(), req, getAssignmentInput{Slug: "proj1"})
	if err != nil {
		t.Fatalf("get_assignment: %v", err)
	}
	encoded, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > maxToolResultBytes {
		t.Fatalf("output is %d bytes, cap is %d", len(encoded), maxToolResultBytes)
	}
	if !out.SubmissionsTruncated {
		t.Fatal("expected submissions_truncated = true")
	}
	if len(out.Submissions) == 0 || len(out.Submissions) >= 400 {
		t.Fatalf("len(submissions) = %d", len(out.Submissions))
	}
	// Newest first upstream, so the cut keeps the newest.
	if out.Submissions[0].ID != 1000 {
		t.Fatalf("first kept submission id = %d, want 1000", out.Submissions[0].ID)
	}
	if grade := out.Submissions[0].Grade; grade == nil || !grade.DescriptionTruncated || !strings.HasSuffix(grade.Description, "...[truncated]") {
		t.Fatalf("grade description was not bounded: %+v", grade)
	}
	// The body and fields were small and must be untouched.
	if out.Body != "Do the thing" || out.BodyTruncated || out.FieldsTruncated {
		t.Fatalf("body/fields = %q/%v/%v", out.Body, out.BodyTruncated, out.FieldsTruncated)
	}
}

func TestServerInstructionsTrustEffectiveDeadline(t *testing.T) {
	for _, writesEnabled := range []bool{false, true} {
		instructions := serverInstructions(writesEnabled)
		for _, want := range []string{
			"effective_closed_at and can_submit already account for any extension",
			"trust them over closed_at and is_open",
		} {
			if !strings.Contains(instructions, want) {
				t.Errorf("instructions (writes=%v) do not say %q", writesEnabled, want)
			}
		}
	}
}
