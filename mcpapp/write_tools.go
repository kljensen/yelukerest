package main

// Curated write tools (issue #267): preview and submit for assignment field
// submissions.
//
// preview_submission_change reads the current state and reports exactly what a
// write would do; submit_submission_change performs it. Both run entirely under
// the caller's own forwarded credential, so row-level security is the sole
// authorization authority, and the write scope — granted by the student on the
// consent screen — is what separates the two.
//
// There is deliberately no confirmation flow here, and no intent token. A write
// through MCP does exactly what the same student can do through the course
// website or by calling the API with their own JWT, and a gate on this path
// only would make the front door worse than the side door without removing any
// capability. docs/mcp-writes.md records that decision and what replaced it.
//
// Optimistic concurrency rides on the DB's PT409 trigger: an overwrite PATCH
// carries the updated_at read moments earlier, and the database rejects the
// write if the row changed in between. A caller that read the value earlier can
// pass expected_updated_at to be told, rather than silently clobber.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// maxSubmissionWriteBytes mirrors the database CHECK constraint
// octet_length(body) <= 65536 on assignment_field_submission.body, so
// oversized bodies are rejected early with a clear error.
const maxSubmissionWriteBytes = 64 * 1024

// errStaleSubmission is the mapping for HTTP 409 responses on the write path:
// both the DB's PT409 stale-write trigger and unique-constraint conflicts
// (someone created the row between prepare and commit) mean the prepared
// snapshot no longer matches reality.
var errStaleSubmission = errors.New("the submission changed while this write was in flight; re-read it and try again")

func registerWriteTools(server *mcp.Server, deps *toolDeps) {
	mcp.AddTool(server, &mcp.Tool{
		Name: "submit_submission_change",
		Description: "Write one assignment field of the caller's submission, creating the submission if this is their first field. " +
			"On a team assignment (is_team) this is the TEAM's shared submission, not a row of the caller's own: the write affects work several students share, " +
			"it can overwrite what a teammate wrote, and the teammates are not asked. " +
			"Requires a token with the write scope. This is the same write a student can perform through the course website or the API directly; " +
			"call preview_submission_change first to see is_team, the team_nickname affected, and what would change. " +
			"Pass expected_updated_at from a preview or from get_my_submissions to be told (rather than silently overwrite) if the value changed since you read it.",
		Annotations: &mcp.ToolAnnotations{
			Title:           "Submit submission change",
			ReadOnlyHint:    false,
			DestructiveHint: boolPtr(true), // an overwrite replaces existing work
			IdempotentHint:  false,
			OpenWorldHint:   boolPtr(false),
		},
	}, deps.submitSubmissionChange)
	mcp.AddTool(server, &mcp.Tool{
		Name: "preview_submission_change",
		Description: "Show exactly what submit_submission_change would do for one assignment field: the current value, the proposed value, whether this creates or overwrites, whether the assignment is open, and the current updated_at. " +
			"Performs no write and needs no write scope. Showing this to the user before submitting is good manners, not a security boundary." + untrustedTextNote,
		Annotations: &mcp.ToolAnnotations{
			Title:         "Preview submission change",
			ReadOnlyHint:  true,
			OpenWorldHint: boolPtr(false),
		},
	}, deps.previewSubmissionChange)
}

// ---- resolving a change ----

// submissionChangePlan is everything both write tools need to know about a
// proposed change: where it would land, what is there now, and whether it
// creates or overwrites. Both tools resolve it the same way, under the
// caller's own credential and row-level security.
type submissionChangePlan struct {
	AssignmentSlug   string
	AssignmentTitle  string
	FieldSlug        string
	IsTeam           bool
	TeamNickname     string
	IsOpen           bool
	ClosedAt         string
	SubmissionID     int
	CreateSubmission bool
	CurrentBody      string
	CurrentUpdatedAt string // empty when there is no existing value
	Action           string // "create" or "overwrite"
}

type submissionChangeInput struct {
	AssignmentSlug string `json:"assignment_slug" jsonschema:"the assignment slug, e.g. from list_assignments"`
	FieldSlug      string `json:"field_slug" jsonschema:"the assignment field slug, e.g. from get_assignment"`
	Body           string `json:"body" jsonschema:"the full value for the field (max 64KB)"`
	// ExpectedUpdatedAt lets a caller assert which version it read. Omitted,
	// the value read moments ago is used, so a concurrent write still loses.
	ExpectedUpdatedAt string `json:"expected_updated_at,omitempty" jsonschema:"optional: the updated_at of the existing value this change is based on; the write fails if it changed since"`
}

// resolveSubmissionChange validates the input and reads the current state.
func (d *toolDeps) resolveSubmissionChange(ctx context.Context, token string, id *identity, in submissionChangeInput) (submissionChangePlan, error) {
	var plan submissionChangePlan
	if !slugPattern.MatchString(in.AssignmentSlug) {
		return plan, errors.New("assignment_slug must be 1-59 characters of lowercase letters, digits, and hyphens")
	}
	if !slugPattern.MatchString(in.FieldSlug) {
		return plan, errors.New("field_slug must be 1-59 characters of lowercase letters, digits, and hyphens")
	}
	if len(in.Body) > maxSubmissionWriteBytes {
		return plan, fmt.Errorf("body is %d bytes; the maximum is %d bytes (64KB)", len(in.Body), maxSubmissionWriteBytes)
	}

	// The assignment must exist and be visible to the caller, and the field
	// must belong to it.
	query := url.Values{}
	query.Set("select", "slug,title,is_team,is_draft,is_open,closed_at,fields:assignment_fields(slug)")
	query.Set("slug", "eq."+in.AssignmentSlug)
	assignments, err := fetchRows[prepareAssignmentRow](ctx, d.postgrest, token, "/assignments", query)
	if err != nil {
		return plan, err
	}
	if len(assignments) == 0 {
		return plan, fmt.Errorf("assignment %q was not found or is not visible to you", in.AssignmentSlug)
	}
	assignment := assignments[0]
	fieldExists := false
	for _, field := range assignment.Fields {
		if field.Slug == in.FieldSlug {
			fieldExists = true
			break
		}
	}
	if !fieldExists {
		return plan, fmt.Errorf("assignment %q has no field %q; call get_assignment to list its fields", in.AssignmentSlug, in.FieldSlug)
	}

	plan.AssignmentSlug = in.AssignmentSlug
	plan.AssignmentTitle = assignment.Title
	plan.FieldSlug = in.FieldSlug
	plan.IsTeam = assignment.IsTeam
	plan.IsOpen = assignment.IsOpen
	plan.ClosedAt = assignment.ClosedAt

	// Locate the caller's (or their team's) existing submission and the
	// current field value, all under the caller's own RLS context.
	subQuery := url.Values{}
	subQuery.Set("select", "id,fields:assignment_field_submissions(assignment_field_slug,body,updated_at)")
	subQuery.Set("assignment_slug", "eq."+in.AssignmentSlug)
	if assignment.IsTeam {
		plan.TeamNickname, err = d.fetchCallerTeamNickname(ctx, token, id.UserID)
		if err != nil {
			return plan, err
		}
		if plan.TeamNickname == "" || !teamNicknamePattern.MatchString(plan.TeamNickname) {
			return plan, fmt.Errorf("assignment %q is a team assignment but you are not on a team", in.AssignmentSlug)
		}
		subQuery.Set("team_nickname", "eq."+plan.TeamNickname)
	} else {
		subQuery.Set("user_id", "eq."+id.UserID)
	}
	submissions, err := fetchRows[prepareSubmissionRow](ctx, d.postgrest, token, "/assignment_submissions", subQuery)
	if err != nil {
		return plan, err
	}
	if len(submissions) > 0 {
		plan.SubmissionID = submissions[0].ID
		for _, field := range submissions[0].Fields {
			if field.AssignmentFieldSlug == in.FieldSlug {
				plan.CurrentBody = field.Body
				plan.CurrentUpdatedAt = field.UpdatedAt
				break
			}
		}
	} else {
		plan.CreateSubmission = true
	}

	if plan.CurrentUpdatedAt != "" {
		if in.ExpectedUpdatedAt != "" && in.ExpectedUpdatedAt != plan.CurrentUpdatedAt {
			return plan, fmt.Errorf("the field value changed since you read it: it was last updated at %s, you expected %s; re-read the submission and try again", plan.CurrentUpdatedAt, in.ExpectedUpdatedAt)
		}
		plan.Action = "overwrite"
	} else {
		if in.ExpectedUpdatedAt != "" {
			return plan, errors.New("there is no existing value for this field, so expected_updated_at must be omitted")
		}
		plan.Action = "create"
	}
	return plan, nil
}

// prepareAssignmentRow is the assignment shape the resolver reads.
type prepareAssignmentRow struct {
	Slug     string `json:"slug"`
	Title    string `json:"title"`
	IsTeam   bool   `json:"is_team"`
	IsDraft  bool   `json:"is_draft"`
	IsOpen   bool   `json:"is_open"`
	ClosedAt string `json:"closed_at"`
	Fields   []struct {
		Slug string `json:"slug"`
	} `json:"fields"`
}

// prepareSubmissionRow is the existing-submission shape the resolver reads.
type prepareSubmissionRow struct {
	ID     int `json:"id"`
	Fields []struct {
		AssignmentFieldSlug string `json:"assignment_field_slug"`
		Body                string `json:"body"`
		UpdatedAt           string `json:"updated_at"`
	} `json:"fields"`
}

// ---- preview ----

type previewSubmissionChangeOutput struct {
	AssignmentSlug    string `json:"assignment_slug"`
	AssignmentTitle   string `json:"assignment_title"`
	FieldSlug         string `json:"field_slug"`
	Action            string `json:"action" jsonschema:"create or overwrite"`
	CreatesSubmission bool   `json:"creates_submission" jsonschema:"true when no submission row exists yet and the write will create one"`
	IsTeam            bool   `json:"is_team"`
	TeamNickname      string `json:"team_nickname,omitempty" jsonschema:"the team whose shared submission this change affects"`
	AssignmentIsOpen  bool   `json:"assignment_is_open"`
	ClosedAt          string `json:"closed_at"`

	CurrentBody           string `json:"current_body,omitempty" jsonschema:"the value that would be overwritten; untrusted course content"`
	CurrentBodyTruncated  bool   `json:"current_body_truncated,omitempty"`
	CurrentUpdatedAt      string `json:"current_updated_at,omitempty" jsonschema:"pass this back as expected_updated_at to detect a concurrent change"`
	ProposedBody          string `json:"proposed_body"`
	ProposedBodyTruncated bool   `json:"proposed_body_truncated,omitempty"`

	CurrentLengthBytes  int    `json:"current_length_bytes"`
	ProposedLengthBytes int    `json:"proposed_length_bytes"`
	Changed             bool   `json:"changed" jsonschema:"false when the proposed value is identical to the current one"`
	Warning             string `json:"warning,omitempty"`
}

func (d *toolDeps) previewSubmissionChange(ctx context.Context, req *mcp.CallToolRequest, in submissionChangeInput) (*mcp.CallToolResult, previewSubmissionChangeOutput, error) {
	var zero previewSubmissionChangeOutput
	// A preview only reads, so it needs no more than read access.
	id, token, err := readCaller(ctx, req)
	if err != nil {
		return nil, zero, err
	}
	plan, err := d.resolveSubmissionChange(ctx, token, id, in)
	if err != nil {
		return nil, zero, err
	}

	out := previewSubmissionChangeOutput{
		AssignmentSlug:      plan.AssignmentSlug,
		AssignmentTitle:     plan.AssignmentTitle,
		FieldSlug:           plan.FieldSlug,
		Action:              plan.Action,
		CreatesSubmission:   plan.CreateSubmission,
		IsTeam:              plan.IsTeam,
		TeamNickname:        plan.TeamNickname,
		AssignmentIsOpen:    plan.IsOpen,
		ClosedAt:            plan.ClosedAt,
		CurrentUpdatedAt:    plan.CurrentUpdatedAt,
		CurrentLengthBytes:  len(plan.CurrentBody),
		ProposedLengthBytes: len(in.Body),
		Changed:             plan.CurrentBody != in.Body,
	}
	out.ProposedBody, out.ProposedBodyTruncated = boundText(in.Body, maxSubmissionBodyChars)
	if plan.Action == "overwrite" {
		out.CurrentBody, out.CurrentBodyTruncated = boundText(plan.CurrentBody, maxSubmissionBodyChars)
	}
	if !plan.IsOpen {
		out.Warning = "The assignment is not currently open. A write will be rejected by the database unless you have a deadline exception."
	}
	if !out.Changed {
		out.Warning = joinWarnings(out.Warning, "The proposed value is identical to the current value; writing would change nothing.")
	}
	return nil, out, nil
}

func joinWarnings(existing string, extra string) string {
	if existing == "" {
		return extra
	}
	return existing + " " + extra
}

// ---- submit ----

type submitSubmissionChangeOutput struct {
	Action         string `json:"action" jsonschema:"create or overwrite"`
	AssignmentSlug string `json:"assignment_slug"`
	FieldSlug      string `json:"field_slug"`
	SubmissionID   int    `json:"submission_id"`
	Body           string `json:"body" jsonschema:"the stored value as returned by the API"`
	BodyTruncated  bool   `json:"body_truncated,omitempty"`
	CreatedAt      string `json:"created_at"`
	UpdatedAt      string `json:"updated_at"`
}

// storedFieldSubmission is the representation PostgREST returns for the
// written field submission row.
type storedFieldSubmission struct {
	AssignmentSubmissionID int    `json:"assignment_submission_id"`
	AssignmentFieldSlug    string `json:"assignment_field_slug"`
	AssignmentSlug         string `json:"assignment_slug"`
	Body                   string `json:"body"`
	CreatedAt              string `json:"created_at"`
	UpdatedAt              string `json:"updated_at"`
}

// submitSubmissionChange performs the write.
//
// The authorization boundary is the write scope, granted by the student on the
// OAuth consent screen, and row-level security underneath it: this tool can do
// exactly what its caller could do by PATCHing the API with their own token,
// and nothing more. It deliberately carries no confirmation flow of its own —
// see docs/mcp-writes.md.
func (d *toolDeps) submitSubmissionChange(ctx context.Context, req *mcp.CallToolRequest, in submissionChangeInput) (*mcp.CallToolResult, submitSubmissionChangeOutput, error) {
	var zero submitSubmissionChangeOutput
	id, token, err := writeCaller(ctx, req)
	if err != nil {
		return nil, zero, err
	}
	plan, err := d.resolveSubmissionChange(ctx, token, id, in)
	if err != nil {
		return nil, zero, err
	}

	submissionID := plan.SubmissionID
	if plan.CreateSubmission {
		submissionID, err = d.createSubmissionRow(ctx, token, plan.AssignmentSlug)
		if err != nil {
			return nil, zero, err
		}
	}

	var stored storedFieldSubmission
	if plan.Action == "create" {
		stored, err = d.createFieldSubmission(ctx, token, plan, submissionID, in.Body)
	} else {
		stored, err = d.overwriteFieldSubmission(ctx, token, plan, submissionID, in.Body)
	}
	if err != nil {
		// PostgREST cannot span two requests in one transaction, so roll the
		// submission row back by hand: leaving an empty submission behind
		// would look like a real (blank) submission to graders.
		if plan.CreateSubmission && submissionID > 0 {
			d.deleteSubmissionRow(ctx, token, submissionID)
		}
		return nil, zero, err
	}

	d.logger.Info("submission_write",
		"subject", id.Subject,
		"assignment", plan.AssignmentSlug,
		"field", plan.FieldSlug,
		"action", plan.Action)

	out := submitSubmissionChangeOutput{
		Action:         plan.Action,
		AssignmentSlug: plan.AssignmentSlug,
		FieldSlug:      plan.FieldSlug,
		SubmissionID:   stored.AssignmentSubmissionID,
		CreatedAt:      stored.CreatedAt,
		UpdatedAt:      stored.UpdatedAt,
	}
	out.Body, out.BodyTruncated = boundText(stored.Body, maxSubmissionBodyChars)
	return nil, out, nil
}

// mapWriteError converts a non-2xx write response into a tool error. HTTP 409
// covers both the DB's PT409 stale-write rejection and unique-constraint
// conflicts; both mean the prepared snapshot is stale.
func mapWriteError(status int, body []byte) error {
	if status == http.StatusConflict {
		return errStaleSubmission
	}
	return newPostgRESTError(status, body)
}

// createSubmissionRow POSTs the assignment_submissions row (the database
// trigger fills user_id or team_nickname from the caller's JWT) and returns
// its id. Mirrors the Elm client's createAssignmentSubmission.
// deleteSubmissionRow compensates for a partially completed create: the
// submission row was written but its field value was not. Best effort — the
// caller is already returning the underlying failure, so a failed rollback is
// logged rather than surfaced.
func (d *toolDeps) deleteSubmissionRow(ctx context.Context, token string, submissionID int) {
	query := url.Values{}
	query.Set("id", fmt.Sprintf("eq.%d", submissionID))
	status, _, err := d.postgrest.do(ctx, token, http.MethodDelete, "/assignment_submissions", query, nil, nil)
	if err != nil || status < 200 || status >= 300 {
		d.logger.Warn("could not roll back an empty submission row",
			"submission_id", submissionID, "status", status)
	}
}

func (d *toolDeps) createSubmissionRow(ctx context.Context, token string, assignmentSlug string) (int, error) {
	payload, err := json.Marshal(map[string]string{"assignment_slug": assignmentSlug})
	if err != nil {
		return 0, errors.New("could not encode the submission request")
	}
	headers := http.Header{}
	headers.Set("Prefer", "return=representation")
	headers.Set("Accept", "application/vnd.pgrst.object+json")
	status, body, err := d.postgrest.do(ctx, token, http.MethodPost, "/assignment_submissions", nil, payload, headers)
	if err != nil {
		return 0, err
	}
	if status < 200 || status >= 300 {
		return 0, mapWriteError(status, body)
	}
	var row struct {
		ID int `json:"id"`
	}
	if err := json.Unmarshal(body, &row); err != nil || row.ID == 0 {
		return 0, errors.New("could not decode the created submission")
	}
	return row.ID, nil
}

// createFieldSubmission POSTs a new assignment_field_submissions row. No
// merge-duplicates resolution is requested on purpose: if the field value
// came into existence between the read and the write, the primary-key
// conflict (HTTP 409) surfaces as a stale-read error instead of silently
// overwriting work nobody saw.
func (d *toolDeps) createFieldSubmission(ctx context.Context, token string, plan submissionChangePlan, submissionID int, body string) (storedFieldSubmission, error) {
	record := map[string]any{
		"assignment_field_slug": plan.FieldSlug,
		"assignment_slug":       plan.AssignmentSlug,
		"body":                  body,
	}
	if submissionID > 0 {
		record["assignment_submission_id"] = submissionID
	}
	payload, err := json.Marshal(record)
	if err != nil {
		return storedFieldSubmission{}, errors.New("could not encode the field submission request")
	}
	headers := http.Header{}
	headers.Set("Prefer", "return=representation")
	headers.Set("Accept", "application/vnd.pgrst.object+json")
	status, responseBody, err := d.postgrest.do(ctx, token, http.MethodPost, "/assignment_field_submissions", nil, payload, headers)
	if err != nil {
		return storedFieldSubmission{}, err
	}
	if status < 200 || status >= 300 {
		return storedFieldSubmission{}, mapWriteError(status, responseBody)
	}
	var stored storedFieldSubmission
	if err := json.Unmarshal(responseBody, &stored); err != nil {
		return storedFieldSubmission{}, errors.New("could not decode the stored field submission")
	}
	return stored, nil
}

// overwriteFieldSubmission PATCHes the existing row by primary key, carrying
// the updated_at read moments earlier so the database's PT409 trigger rejects
// the write if the row changed in between (optimistic concurrency).
func (d *toolDeps) overwriteFieldSubmission(ctx context.Context, token string, plan submissionChangePlan, submissionID int, body string) (storedFieldSubmission, error) {
	record := map[string]string{
		"body":       body,
		"updated_at": plan.CurrentUpdatedAt,
	}
	payload, err := json.Marshal(record)
	if err != nil {
		return storedFieldSubmission{}, errors.New("could not encode the field submission request")
	}
	query := url.Values{}
	query.Set("assignment_submission_id", fmt.Sprintf("eq.%d", submissionID))
	query.Set("assignment_field_slug", "eq."+plan.FieldSlug)
	headers := http.Header{}
	headers.Set("Prefer", "return=representation")
	status, responseBody, err := d.postgrest.do(ctx, token, http.MethodPatch, "/assignment_field_submissions", query, payload, headers)
	if err != nil {
		return storedFieldSubmission{}, err
	}
	if status < 200 || status >= 300 {
		return storedFieldSubmission{}, mapWriteError(status, responseBody)
	}
	var rows []storedFieldSubmission
	if err := json.Unmarshal(responseBody, &rows); err != nil {
		return storedFieldSubmission{}, errors.New("could not decode the stored field submission")
	}
	if len(rows) == 0 {
		// RLS filtered the row out of the UPDATE: the write window closed
		// between prepare and commit, or the row disappeared.
		return storedFieldSubmission{}, errors.New("the write was not permitted; the submission window may have closed or the row no longer exists")
	}
	return rows[0], nil
}
