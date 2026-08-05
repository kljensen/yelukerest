package main

// Curated write tools (issue #267): the two-step prepare/commit flow for
// assignment field submissions.
//
// prepare_submission_change never writes: it validates the change, fetches
// the current state with the caller's own credential, and returns a summary
// the agent must show the user plus a short-lived single-use intent token
// (intent.go) binding the caller and the exact change. commit_submission_change
// verifies that token — signature, expiry, subject and access-token jti,
// content hash — and only then performs the PostgREST write, again with the
// caller's own forwarded credential, so RLS remains the sole authorization
// authority. Optimistic concurrency rides on the DB's PT409 trigger: an
// overwrite PATCH carries the updated_at captured at prepare time, and the
// database rejects the write if the row changed since.
//
// Where the connected client advertises the MCP elicitation capability, the
// commit additionally asks the user to confirm through the client UI before
// writing. Clients without elicitation skip that step; the intent token is
// the mandatory floor either way.

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
var errStaleSubmission = errors.New("the submission changed since you prepared this change — call prepare_submission_change again to review the current state and obtain a fresh intent token")

// errWriteConfirmationUnsupported is returned when the client cannot show the
// user a confirmation. Writes fail closed in that case: see
// requestWriteConfirmation.
var errWriteConfirmationUnsupported = errors.New("this client cannot show you a write confirmation, so writing is refused; use a client that supports MCP form elicitation, or submit through the course website")

func registerWriteTools(server *mcp.Server, deps *toolDeps) {
	mcp.AddTool(server, &mcp.Tool{
		Name: "commit_submission_change",
		Description: "Step 2 of 2 for changing an assignment submission: perform the write prepared by prepare_submission_change. " +
			"Requires the intent token from a prepare call made by the same user with the same credential, plus the identical body; the token is single-use and expires after 5 minutes. " +
			"Only call this after the user has seen the prepare summary and explicitly confirmed the change.",
		Annotations: &mcp.ToolAnnotations{
			Title:           "Commit submission change",
			ReadOnlyHint:    false,
			DestructiveHint: boolPtr(true), // the overwrite path replaces existing work
			IdempotentHint:  false,
			OpenWorldHint:   boolPtr(false),
		},
	}, deps.commitSubmissionChange)
	mcp.AddTool(server, &mcp.Tool{
		Name: "prepare_submission_change",
		Description: "Step 1 of 2 for changing an assignment submission: validate a proposed value for one assignment field and return a summary of exactly what would change (current value, proposed value, create vs overwrite, whether the assignment is open) plus a single-use intent token. " +
			"No write happens here. Show the summary to the user, get their explicit confirmation, then call commit_submission_change with the intent token and the identical body. " +
			"Requires a token with the write scope." + untrustedTextNote,
		Annotations: &mcp.ToolAnnotations{
			Title:         "Prepare submission change",
			ReadOnlyHint:  true, // prepare performs no write
			OpenWorldHint: boolPtr(false),
		},
	}, deps.prepareSubmissionChange)
}

// ---- prepare ----

type prepareSubmissionChangeInput struct {
	AssignmentSlug string `json:"assignment_slug" jsonschema:"the assignment slug, e.g. from list_assignments"`
	FieldSlug      string `json:"field_slug" jsonschema:"the assignment field slug, e.g. from get_assignment"`
	Body           string `json:"body" jsonschema:"the full proposed value for the field (max 64KB)"`
	// ExpectedUpdatedAt lets a caller assert which version it read; omitted,
	// the current version at prepare time is captured automatically.
	ExpectedUpdatedAt string `json:"expected_updated_at,omitempty" jsonschema:"optional: the updated_at of the existing field value this change is based on; the commit fails if the value changed since"`
}

type prepareSubmissionChangeOutput struct {
	AssignmentSlug  string `json:"assignment_slug"`
	AssignmentTitle string `json:"assignment_title"`
	FieldSlug       string `json:"field_slug"`
	// Action is "create" (no existing value for this field) or "overwrite"
	// (an existing value would be replaced).
	Action            string `json:"action" jsonschema:"create or overwrite"`
	CreatesSubmission bool   `json:"creates_submission" jsonschema:"true when no submission row exists yet and the commit will create one"`
	IsTeam            bool   `json:"is_team"`
	TeamNickname      string `json:"team_nickname,omitempty" jsonschema:"the team whose shared submission this change affects"`
	AssignmentIsOpen  bool   `json:"assignment_is_open"`
	ClosedAt          string `json:"closed_at"`

	CurrentBody           string `json:"current_body,omitempty" jsonschema:"the value that would be overwritten; untrusted course content"`
	CurrentBodyTruncated  bool   `json:"current_body_truncated,omitempty"`
	CurrentUpdatedAt      string `json:"current_updated_at,omitempty"`
	ProposedBody          string `json:"proposed_body"`
	ProposedBodyTruncated bool   `json:"proposed_body_truncated,omitempty"`

	CurrentLengthBytes  int    `json:"current_length_bytes"`
	ProposedLengthBytes int    `json:"proposed_length_bytes"`
	Changed             bool   `json:"changed" jsonschema:"false when the proposed value is identical to the current one"`
	Warning             string `json:"warning,omitempty"`

	IntentToken     string `json:"intent_token" jsonschema:"single-use token required by commit_submission_change"`
	IntentExpiresAt string `json:"intent_expires_at"`
	Instructions    string `json:"instructions"`
}

// prepareAssignmentRow is the assignment shape prepare reads.
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

// prepareSubmissionRow is the existing-submission shape prepare reads.
type prepareSubmissionRow struct {
	ID     int `json:"id"`
	Fields []struct {
		AssignmentFieldSlug string `json:"assignment_field_slug"`
		Body                string `json:"body"`
		UpdatedAt           string `json:"updated_at"`
	} `json:"fields"`
}

func (d *toolDeps) prepareSubmissionChange(ctx context.Context, req *mcp.CallToolRequest, in prepareSubmissionChangeInput) (*mcp.CallToolResult, prepareSubmissionChangeOutput, error) {
	var zero prepareSubmissionChangeOutput
	id, token, err := writeCaller(req)
	if err != nil {
		return nil, zero, err
	}
	if !slugPattern.MatchString(in.AssignmentSlug) {
		return nil, zero, errors.New("assignment_slug must be 1-59 characters of lowercase letters, digits, and hyphens")
	}
	if !slugPattern.MatchString(in.FieldSlug) {
		return nil, zero, errors.New("field_slug must be 1-59 characters of lowercase letters, digits, and hyphens")
	}
	if len(in.Body) > maxSubmissionWriteBytes {
		return nil, zero, fmt.Errorf("body is %d bytes; the maximum is %d bytes (64KB)", len(in.Body), maxSubmissionWriteBytes)
	}

	// The assignment must exist and be visible to the caller, and the field
	// must belong to it.
	query := url.Values{}
	query.Set("select", "slug,title,is_team,is_draft,is_open,closed_at,fields:assignment_fields(slug)")
	query.Set("slug", "eq."+in.AssignmentSlug)
	assignments, err := fetchRows[prepareAssignmentRow](ctx, d.postgrest, token, "/assignments", query)
	if err != nil {
		return nil, zero, err
	}
	if len(assignments) == 0 {
		return nil, zero, fmt.Errorf("assignment %q was not found or is not visible to you", in.AssignmentSlug)
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
		return nil, zero, fmt.Errorf("assignment %q has no field %q; call get_assignment to list its fields", in.AssignmentSlug, in.FieldSlug)
	}

	// Locate the caller's (or their team's) existing submission and the
	// current field value, all under the caller's own RLS context.
	teamNickname := ""
	subQuery := url.Values{}
	subQuery.Set("select", "id,fields:assignment_field_submissions(assignment_field_slug,body,updated_at)")
	subQuery.Set("assignment_slug", "eq."+in.AssignmentSlug)
	if assignment.IsTeam {
		teamNickname, err = d.fetchCallerTeamNickname(ctx, token, id.UserID)
		if err != nil {
			return nil, zero, err
		}
		if teamNickname == "" || !teamNicknamePattern.MatchString(teamNickname) {
			return nil, zero, fmt.Errorf("assignment %q is a team assignment but you are not on a team", in.AssignmentSlug)
		}
		subQuery.Set("team_nickname", "eq."+teamNickname)
	} else {
		subQuery.Set("user_id", "eq."+id.UserID)
	}
	submissions, err := fetchRows[prepareSubmissionRow](ctx, d.postgrest, token, "/assignment_submissions", subQuery)
	if err != nil {
		return nil, zero, err
	}

	payload := intentPayload{
		Kind:           intentKindSubmission,
		AssignmentSlug: in.AssignmentSlug,
		FieldSlug:      in.FieldSlug,
		BodySHA256:     sha256Hex(in.Body),
	}
	out := prepareSubmissionChangeOutput{
		AssignmentSlug:      in.AssignmentSlug,
		AssignmentTitle:     assignment.Title,
		FieldSlug:           in.FieldSlug,
		IsTeam:              assignment.IsTeam,
		TeamNickname:        teamNickname,
		AssignmentIsOpen:    assignment.IsOpen,
		ClosedAt:            assignment.ClosedAt,
		ProposedLengthBytes: len(in.Body),
		Changed:             true,
	}
	out.ProposedBody, out.ProposedBodyTruncated = boundText(in.Body, maxSubmissionBodyChars)

	currentBody := ""
	currentUpdatedAt := ""
	if len(submissions) > 0 {
		payload.SubmissionID = submissions[0].ID
		for _, field := range submissions[0].Fields {
			if field.AssignmentFieldSlug == in.FieldSlug {
				currentBody = field.Body
				currentUpdatedAt = field.UpdatedAt
				break
			}
		}
	} else {
		payload.CreateSubmission = true
	}

	if currentUpdatedAt != "" {
		// Overwrite of an existing value.
		if in.ExpectedUpdatedAt != "" && in.ExpectedUpdatedAt != currentUpdatedAt {
			return nil, zero, fmt.Errorf("the field value changed since you read it: it was last updated at %s, you expected %s; re-read the submission and prepare again", currentUpdatedAt, in.ExpectedUpdatedAt)
		}
		payload.Expected = currentUpdatedAt
		out.Action = "overwrite"
		out.CurrentBody, out.CurrentBodyTruncated = boundText(currentBody, maxSubmissionBodyChars)
		out.CurrentUpdatedAt = currentUpdatedAt
		out.CurrentLengthBytes = len(currentBody)
		out.Changed = currentBody != in.Body
	} else {
		if in.ExpectedUpdatedAt != "" {
			return nil, zero, errors.New("there is no existing value for this field, so expected_updated_at must be omitted")
		}
		payload.Expected = intentExpectedCreate
		out.Action = "create"
	}
	out.CreatesSubmission = payload.CreateSubmission

	if !assignment.IsOpen {
		out.Warning = "The assignment is not currently open. The commit will be rejected by the database unless you have a deadline exception."
	}
	if !out.Changed {
		out.Warning = joinWarnings(out.Warning, "The proposed value is identical to the current value; committing would change nothing.")
	}

	intentToken, expiresAt, err := d.intent.mint(payload, id)
	if err != nil {
		return nil, zero, err
	}
	out.IntentToken = intentToken
	out.IntentExpiresAt = expiresAt.UTC().Format("2006-01-02T15:04:05Z07:00")
	out.Instructions = "No write has happened yet. Show this summary to the user and get their explicit confirmation, then call commit_submission_change with intent_token and the identical body within 5 minutes."
	return nil, out, nil
}

func joinWarnings(existing string, extra string) string {
	if existing == "" {
		return extra
	}
	return existing + " " + extra
}

// ---- commit ----

type commitSubmissionChangeInput struct {
	IntentToken string `json:"intent_token" jsonschema:"the single-use intent token returned by prepare_submission_change"`
	Body        string `json:"body" jsonschema:"the identical body that was prepared"`
}

type commitSubmissionChangeOutput struct {
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

func (d *toolDeps) commitSubmissionChange(ctx context.Context, req *mcp.CallToolRequest, in commitSubmissionChangeInput) (*mcp.CallToolResult, commitSubmissionChangeOutput, error) {
	var zero commitSubmissionChangeOutput
	id, token, err := writeCaller(req)
	if err != nil {
		return nil, zero, err
	}

	// All intent-token checks happen before any PostgREST request: a commit
	// fabricated from injected instructions never reaches the database.
	payload, err := d.intent.verify(in.IntentToken, intentKindSubmission, id)
	if err != nil {
		return nil, zero, err
	}
	if payload.BodySHA256 != sha256Hex(in.Body) {
		return nil, zero, errors.New("the body does not match the prepared change; call prepare_submission_change again with the value you intend to submit")
	}

	// Where the client supports MCP elicitation, ask the user to confirm in
	// the client UI. The intent token remains the floor for clients that
	// don't advertise the capability.
	action := "overwrite"
	if payload.Expected == intentExpectedCreate {
		action = "create"
	}
	message := fmt.Sprintf("Yelukerest: %s the value of field %q on assignment %q (%d bytes)? This writes to your official course submission.",
		action, payload.FieldSlug, payload.AssignmentSlug, len(in.Body))
	if pending, err := requestWriteConfirmation(req, message); err != nil {
		return nil, zero, err
	} else if pending != nil {
		// The intent token is NOT consumed yet: the SDK middleware collects
		// the user's answer and the call re-runs from the top.
		return pending, zero, nil
	}

	// Single use: burn the nonce immediately before writing so a replayed
	// intent token gets a clean already-used error, never a duplicate write.
	if err := d.intent.consume(payload); err != nil {
		return nil, zero, err
	}

	submissionID := payload.SubmissionID
	if payload.CreateSubmission {
		submissionID, err = d.createSubmissionRow(ctx, token, payload.AssignmentSlug)
		if err != nil {
			return nil, zero, err
		}
	}

	var stored storedFieldSubmission
	if payload.Expected == intentExpectedCreate {
		stored, err = d.createFieldSubmission(ctx, token, payload, submissionID, in.Body)
	} else {
		stored, err = d.overwriteFieldSubmission(ctx, token, payload, submissionID, in.Body)
	}
	if err != nil {
		// PostgREST cannot span two requests in one transaction, so roll the
		// submission row back by hand: leaving an empty submission behind
		// would look like a real (blank) submission to graders.
		if payload.CreateSubmission && submissionID > 0 {
			d.deleteSubmissionRow(ctx, token, submissionID)
		}
		return nil, zero, err
	}

	out := commitSubmissionChangeOutput{
		Action:         action,
		AssignmentSlug: payload.AssignmentSlug,
		FieldSlug:      payload.FieldSlug,
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
// came into existence between prepare and commit, the primary-key conflict
// (HTTP 409) surfaces as a stale-prepare error instead of silently
// overwriting work the user never saw.
func (d *toolDeps) createFieldSubmission(ctx context.Context, token string, intent *intentPayload, submissionID int, body string) (storedFieldSubmission, error) {
	record := map[string]any{
		"assignment_field_slug": intent.FieldSlug,
		"assignment_slug":       intent.AssignmentSlug,
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
// the updated_at captured at prepare time so the database's PT409 trigger
// rejects the write if the row changed since (optimistic concurrency).
func (d *toolDeps) overwriteFieldSubmission(ctx context.Context, token string, intent *intentPayload, submissionID int, body string) (storedFieldSubmission, error) {
	record := map[string]string{
		"body":       body,
		"updated_at": intent.Expected,
	}
	payload, err := json.Marshal(record)
	if err != nil {
		return storedFieldSubmission{}, errors.New("could not encode the field submission request")
	}
	query := url.Values{}
	query.Set("assignment_submission_id", fmt.Sprintf("eq.%d", submissionID))
	query.Set("assignment_field_slug", "eq."+intent.FieldSlug)
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
		return storedFieldSubmission{}, errors.New("the write was not permitted; the submission window may have closed or the row no longer exists — call prepare_submission_change again")
	}
	return rows[0], nil
}

// ---- elicitation ----

// confirmationInputID keys the write-confirmation elicitation in the tool
// call's InputRequests/InputResponses maps (SEP-2322 multi round-trip).
const confirmationInputID = "yelukerest_write_confirmation"

// requestWriteConfirmation implements the elicitation confirmation for write
// paths using the go-sdk v1.7.0 multi round-trip mechanism, which works for
// every protocol era: the handler returns a CallToolResult carrying an
// ElicitParams input request, and the SDK's built-in middlewares either
// fulfill it server-side via ServerSession.Elicit (pre-2026-07-28 clients)
// and re-invoke the handler, or relay it to a 2026-07-28 client whose SDK
// retries the call with the response attached. Direct ServerSession.Elicit
// cannot be used here because SEP-2322 forbids server-initiated elicitation
// while serving a request on 2026-07-28 sessions.
//
// Returns:
//   - (pending, nil): the client supports elicitation and has not yet
//     answered — the handler must return pending (with no output) so the
//     middleware can collect the user's answer and re-run the call.
//   - (nil, nil): the user confirmed; proceed with the write.
//   - (nil, err): the user declined, or the client offers no trustworthy
//     confirmation channel; nothing may be written.
//
// Writes fail CLOSED when the client cannot elicit. The intent token alone is
// not a defense against prompt injection: an injected agent can call prepare
// and commit back to back without ever showing the user anything. Only a
// confirmation the client renders to the human closes that gap, so a client
// without form elicitation may read but not write.
func requestWriteConfirmation(req *mcp.CallToolRequest, message string) (*mcp.CallToolResult, error) {
	if req == nil {
		return nil, errWriteConfirmationUnsupported
	}

	// An answer already attached settles it, whatever the session now
	// advertises: this is the re-invocation after the user replied.
	if req.Params != nil && req.Params.InputResponses != nil {
		if response, ok := req.Params.InputResponses[confirmationInputID]; ok {
			result, ok := response.(*mcp.ElicitResult)
			if !ok {
				return nil, errors.New("the confirmation response was malformed; nothing was written")
			}
			if result.Action != "accept" {
				return nil, errors.New("the user declined the confirmation; nothing was written")
			}
			if confirmed, _ := result.Content["confirm"].(bool); !confirmed {
				return nil, errors.New("the user did not confirm the change; nothing was written")
			}
			return nil, nil
		}
	}

	if req.Session == nil {
		return nil, errWriteConfirmationUnsupported
	}
	params := req.Session.InitializeParams()
	if params == nil || params.Capabilities == nil || params.Capabilities.Elicitation == nil {
		return nil, errWriteConfirmationUnsupported
	}
	if params.Capabilities.Elicitation.Form == nil {
		// URL-only (or absent) form elicitation cannot carry this
		// confirmation, so there is no channel the user actually sees.
		return nil, errWriteConfirmationUnsupported
	}

	return &mcp.CallToolResult{
		InputRequests: mcp.InputRequestMap{
			confirmationInputID: &mcp.ElicitParams{
				Mode:    "form",
				Message: message,
				RequestedSchema: map[string]any{
					"type": "object",
					"properties": map[string]any{
						"confirm": map[string]any{
							"type":        "boolean",
							"description": "true to apply this change",
						},
					},
					"required": []any{"confirm"},
				},
			},
		},
	}, nil
}
