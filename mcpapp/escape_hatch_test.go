package main

// Tests for the escape hatch (issue #268): GET happy path and query
// building, path constraints, the verb-keyed scope gate for non-GET requests,
// response size caps, audit logging, and the schema tool bound. Since issue
// #331 the mutating verbs are also gated on escapeHatchWritesEnabled, so
// tests that expect a write to execute have to turn it on.

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"strings"
	"testing"
)

// ---- GET path ----

func TestPostgrestRequestGETHappyPath(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respond("/assignments", `[{"slug":"proj1","title":"Project 1"}]`)
	req, token := readToolRequest(t, nil) // carries the read scopes consent grants

	_, out, err := fake.deps(t).postgrestRequest(context.Background(), req, postgrestRequestInput{
		Method: "get", // lowercase is normalized
		Path:   "/assignments",
		Query:  map[string]string{"slug": "eq.proj1", "select": "slug,title", "order": "slug.asc"},
	})
	if err != nil {
		t.Fatalf("tool error: %v", err)
	}
	if out.Status != http.StatusOK || out.BodyTruncated {
		t.Fatalf("output = %+v", out)
	}
	if !strings.Contains(out.Body, `"slug":"proj1"`) {
		t.Fatalf("body = %q", out.Body)
	}

	recorded := fake.recorded()
	if len(recorded) != 1 {
		t.Fatalf("requests = %+v", recorded)
	}
	got := recorded[0]
	if got.method != http.MethodGet || got.path != "/assignments" {
		t.Fatalf("request = %s %s", got.method, got.path)
	}
	if got.auth != "Bearer "+token {
		t.Fatal("GET did not forward the caller's bearer token")
	}
	if got.query.Get("slug") != "eq.proj1" || got.query.Get("select") != "slug,title" || got.query.Get("order") != "slug.asc" {
		t.Fatalf("query = %v", got.query)
	}
	if len(got.prefer) != 0 {
		t.Fatalf("GET must not carry a Prefer header, got %v", got.prefer)
	}
}

func TestPostgrestRequestGETRequiresReadScope(t *testing.T) {
	fake := newFakePostgREST(t)
	req, _ := readToolRequest(t, func(claims map[string]any) {
		claims["scopes"] = []string{"write"} // write alone does not imply read
	})
	_, _, err := fake.deps(t).postgrestRequest(context.Background(), req, postgrestRequestInput{
		Method: "GET", Path: "/assignments",
	})
	if err == nil || !strings.Contains(err.Error(), "scope") {
		t.Fatalf("expected a scope error, got %v", err)
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("scope-denied GET reached PostgREST")
	}
}

// ---- path and method validation ----

func TestPostgrestRequestRejectsBadPathsAndMethods(t *testing.T) {
	badPaths := []string{
		"", "assignments", "/", "/a/b", "/rpc/sync_meetings", "/../etc",
		"/assignments/", "/Assignments", "/a.b", "/a b", "/a?x=1", "/1abc",
		"/assignments%2F..", "/assignments\n",
	}
	fake := newFakePostgREST(t)
	deps := fake.deps(t)
	req, _ := readToolRequest(t, nil)
	ctx := context.Background()

	for _, path := range badPaths {
		if _, _, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{Method: "GET", Path: path}); err == nil {
			t.Fatalf("path %q was accepted", path)
		}
	}
	for _, method := range []string{"PUT", "HEAD", "OPTIONS", "TRACE", ""} {
		if _, _, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{Method: method, Path: "/assignments"}); err == nil {
			t.Fatalf("method %q was accepted", method)
		}
	}
	// Bodies are only allowed on POST and PATCH.
	if _, _, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{Method: "GET", Path: "/assignments", Body: `{"x":1}`}); err == nil {
		t.Fatal("GET with a body was accepted")
	}
	// The escape hatch shares the curated write tools' 64KB ceiling, which
	// mirrors the database CHECK constraint on submission bodies.
	writeReq, _ := writeToolRequest(t, nil)
	oversized := `{"body":"` + strings.Repeat("a", maxSubmissionWriteBytes) + `"}`
	if _, _, err := deps.postgrestRequest(ctx, writeReq, postgrestRequestInput{Method: "POST", Path: "/assignments", Body: oversized}); err == nil || !strings.Contains(err.Error(), "64KB") {
		t.Fatalf("oversized body: %v", err)
	}
	// An empty query parameter name would build a nonsense upstream URL.
	if _, _, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{Method: "GET", Path: "/assignments", Query: map[string]string{"": "eq.1"}}); err == nil {
		t.Fatal("an empty query parameter name was accepted")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("invalid requests reached PostgREST")
	}
}

// ---- non-GET gate ----

// The verb, not the tool identity, decides which scope is required: a PATCH
// through the escape hatch is exactly as consequential as one through the
// curated write tool, so it demands the same write scope.
func TestPostgrestRequestNonGETRequiresWriteScope(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{name: "no recognised scopes", mutate: func(c map[string]any) { delete(c, "scopes") }},
		{name: "the read scopes consent grants", mutate: nil},
		{name: "read scope only", mutate: func(c map[string]any) { c["scopes"] = []string{"read"} }},
	}
	for _, method := range []string{http.MethodPost, http.MethodPatch, http.MethodDelete} {
		for _, tt := range tests {
			t.Run(method+"/"+tt.name, func(t *testing.T) {
				fake := newFakePostgREST(t)
				req, _ := readToolRequest(t, tt.mutate)
				in := postgrestRequestInput{Method: method, Path: "/assignment_field_submissions"}
				if method != http.MethodDelete {
					in.Body = `{"body":"x"}`
				}
				_, _, err := fake.deps(t).postgrestRequest(context.Background(), req, in)
				if err == nil || !strings.Contains(err.Error(), "denied") && !strings.Contains(err.Error(), "scope") {
					t.Fatalf("expected a scope denial, got %v", err)
				}
				if len(fake.recorded()) != 0 {
					t.Fatal("a scope-denied request reached PostgREST")
				}
			})
		}
	}
}

// On a deployment that has enabled the mutating verbs, the write scope is the
// whole remaining gate: there is no intent token, no preparation step, and no
// confirmation round trip on this path. The scope the student granted on the
// consent screen is what authorizes it, and RLS enforces the rest.
func TestPostgrestRequestNonGETWithWriteScopeExecutes(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK,
		`[{"assignment_submission_id":1,"assignment_field_slug":"secret","body":"new"}]`)

	logs := &safeBuffer{}
	deps := fake.deps(t)
	deps.escapeHatchWritesEnabled = true
	deps.logger = slog.New(slog.NewJSONHandler(logs, nil))
	req, token := writeToolRequest(t, nil)
	ctx := context.Background()

	query := map[string]string{"assignment_slug": "eq.team-selection"}
	body := `{"body":"new"}`
	_, out, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{
		Method: "PATCH", Path: "/assignment_field_submissions", Query: query, Body: body,
	})
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	if out.Status != http.StatusOK || !strings.Contains(out.Body, `"body":"new"`) {
		t.Fatalf("output = %+v", out)
	}

	recorded := fake.recorded()
	if len(recorded) != 1 {
		t.Fatalf("requests = %+v", recorded)
	}
	got := recorded[0]
	if got.method != http.MethodPatch || got.path != "/assignment_field_submissions" {
		t.Fatalf("request = %s %s", got.method, got.path)
	}
	if got.auth != "Bearer "+token {
		t.Fatal("PATCH did not forward the caller's bearer token")
	}
	if got.query.Get("assignment_slug") != "eq.team-selection" {
		t.Fatalf("query = %v", got.query)
	}
	if got.body != body {
		t.Fatalf("body = %q", got.body)
	}
	if len(got.prefer) != 1 || got.prefer[0] != "return=representation" {
		t.Fatalf("Prefer = %v", got.prefer)
	}

	// Audit log carries subject, method, and path — never the body.
	logText := logs.String()
	if !strings.Contains(logText, "escape_hatch_request") ||
		!strings.Contains(logText, `"subject":"user:42"`) ||
		!strings.Contains(logText, `"method":"PATCH"`) ||
		!strings.Contains(logText, `"path":"/assignment_field_submissions"`) {
		t.Fatalf("audit log missing fields: %s", logText)
	}
	if strings.Contains(logText, `"body":"new"`) || strings.Contains(logText, "team-selection") {
		t.Fatalf("audit log leaks request contents: %s", logText)
	}
}

// The shipped posture (issue #331): the hatch reads, and a write is refused
// even for a caller holding the write scope. Scope parity with the curated
// tool is not blast-radius parity — a raw PATCH can omit filters and skips the
// stale-write check — so the refusal has to name the tool that does neither.
func TestPostgrestRequestRefusesMutatingVerbsByDefault(t *testing.T) {
	fake := newFakePostgREST(t)
	deps := fake.deps(t) // the zero value is the default: writes disabled
	req, _ := writeToolRequest(t, nil)
	ctx := context.Background()

	for _, method := range []string{http.MethodPost, http.MethodPatch, http.MethodDelete} {
		t.Run(method, func(t *testing.T) {
			in := postgrestRequestInput{Method: method, Path: "/assignment_field_submissions"}
			if method != http.MethodDelete {
				in.Body = `{"body":"x"}`
			}
			_, _, err := deps.postgrestRequest(ctx, req, in)
			if err == nil {
				t.Fatal("a mutating verb was accepted with writes disabled")
			}
			if !strings.Contains(err.Error(), "submit_submission_change") {
				t.Fatalf("refusal does not point at the curated tool: %v", err)
			}
			if !strings.Contains(err.Error(), method) {
				t.Fatalf("refusal does not name the verb: %v", err)
			}
		})
	}
	if len(fake.recorded()) != 0 {
		t.Fatalf("a refused write reached PostgREST: %+v", fake.recorded())
	}

	// The read hatch is untouched: it is what keeps the MCP front door no
	// worse than the caller's own token against the REST API.
	fake.respond("/assignments", `[{"slug":"proj1"}]`)
	readReq, _ := readToolRequest(t, nil)
	_, out, err := deps.postgrestRequest(ctx, readReq, postgrestRequestInput{Method: http.MethodGet, Path: "/assignments"})
	if err != nil {
		t.Fatalf("GET with writes disabled: %v", err)
	}
	if out.Status != http.StatusOK || !strings.Contains(out.Body, `"slug":"proj1"`) {
		t.Fatalf("output = %+v", out)
	}
}

// The advertised tool has to match the configured tool, or a model spends its
// turn attempting a write this deployment will refuse.
func TestPostgrestRequestToolDescriptionTracksSetting(t *testing.T) {
	readOnly := postgrestRequestTool(false)
	if !readOnly.Annotations.ReadOnlyHint {
		t.Fatal("with writes disabled the tool must advertise readOnlyHint")
	}
	if readOnly.Annotations.DestructiveHint == nil || *readOnly.Annotations.DestructiveHint {
		t.Fatal("with writes disabled the tool must advertise destructiveHint=false")
	}
	if !strings.Contains(readOnly.Description, "GET only") || !strings.Contains(readOnly.Description, "submit_submission_change") {
		t.Fatalf("description = %q", readOnly.Description)
	}

	writable := postgrestRequestTool(true)
	if writable.Annotations.ReadOnlyHint {
		t.Fatal("with writes enabled the tool must not advertise readOnlyHint")
	}
	if writable.Annotations.DestructiveHint == nil || !*writable.Annotations.DestructiveHint {
		t.Fatal("with writes enabled the tool must advertise destructiveHint=true")
	}
	if !strings.Contains(writable.Description, "POST, PATCH, and DELETE require the write scope") {
		t.Fatalf("description = %q", writable.Description)
	}
}

// /rpc/* function calls are excluded by the path pattern rather than by a
// denylist, because server functions carry side effects (bulk imports,
// credential minting) that no student-facing agent should be able to trigger
// from instructions found in course content.
func TestPostgrestRequestRejectsRPCForEveryVerb(t *testing.T) {
	fake := newFakePostgREST(t)
	deps := fake.deps(t)
	req, _ := writeToolRequest(t, nil)
	ctx := context.Background()

	for _, method := range allowedAPIMethods {
		for _, path := range []string{"/rpc/sync_meetings", "/rpc/sync_assignments", "/rpc/issue_user_jwt"} {
			if _, _, err := deps.postgrestRequest(ctx, req, postgrestRequestInput{Method: method, Path: path}); err == nil {
				t.Fatalf("%s %s was accepted", method, path)
			}
		}
	}
	if len(fake.recorded()) != 0 {
		t.Fatalf("an RPC path reached PostgREST: %+v", fake.recorded())
	}
}

// ---- size caps ----

func TestPostgrestRequestCapsResponseSize(t *testing.T) {
	huge := `[{"body":"` + strings.Repeat("x", 200*1024) + `"}]`
	fake := newFakePostgREST(t)
	fake.respond("/assignments", huge)
	req, _ := readToolRequest(t, nil)

	_, out, err := fake.deps(t).postgrestRequest(context.Background(), req, postgrestRequestInput{
		Method: "GET", Path: "/assignments",
	})
	if err != nil {
		t.Fatalf("tool error: %v", err)
	}
	if !out.BodyTruncated {
		t.Fatal("expected body_truncated = true")
	}
	if !strings.HasSuffix(out.Body, "...[truncated]") {
		t.Fatal("body does not end with the truncation marker")
	}
	encoded, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > maxToolResultBytes {
		t.Fatalf("output is %d bytes, cap is %d", len(encoded), maxToolResultBytes)
	}
}

func TestTruncateBytesRespectsRuneBoundaries(t *testing.T) {
	s := strings.Repeat("é", 100) // 2 bytes per rune
	out, truncated := truncateBytes(s, 51)
	if !truncated {
		t.Fatal("expected truncation")
	}
	prefix := strings.TrimSuffix(out, " ...[truncated]")
	if len(prefix) != 50 {
		t.Fatalf("prefix = %d bytes, want 50 (rune boundary)", len(prefix))
	}
	if !json.Valid([]byte(`"` + prefix + `"`)) {
		t.Fatal("truncated prefix is not valid UTF-8 in JSON")
	}
}

// ---- schema tool ----

func TestGetAPISchemaSizeAndScope(t *testing.T) {
	if len(apiSchemaDocument) > 8*1024 {
		t.Fatalf("schema document is %d bytes, budget is 8KB", len(apiSchemaDocument))
	}
	for _, want := range []string{
		"assignment_field_submissions",
		"eq.",
		"select=",
		"order=",
		"rpc/sync_meetings",
		"postgrest_request",
	} {
		if !strings.Contains(apiSchemaDocument, want) {
			t.Fatalf("schema document missing %q", want)
		}
	}

	fake := newFakePostgREST(t)
	deps := fake.deps(t)
	ctx := context.Background()

	req, _ := readToolRequest(t, nil)
	_, out, err := deps.getAPISchema(ctx, req, nil)
	if err != nil {
		t.Fatalf("get_api_schema: %v", err)
	}
	if out.Schema != apiSchemaDocument {
		t.Fatal("schema output mismatch")
	}

	denied, _ := readToolRequest(t, func(claims map[string]any) {
		claims["scopes"] = []string{"openid"}
	})
	if _, _, err := deps.getAPISchema(ctx, denied, nil); err == nil {
		t.Fatal("get_api_schema without read scope accepted")
	}
	if len(fake.recorded()) != 0 {
		t.Fatal("get_api_schema must not reach PostgREST")
	}
}

// The flag that keeps raw writes off must fail closed on anything it does not
// recognise. envBoolOrDefault reads every unknown value as true, so a typo
// there would silently open POST/PATCH/DELETE; this is the one flag that
// cannot afford that, and the operator has to be told why their value was
// ignored.
func TestEscapeHatchWritesEnabledFailsClosed(t *testing.T) {
	cases := []struct {
		value   string
		set     bool
		want    bool
		wantLog bool
	}{
		{value: "", set: false, want: false},
		{value: "true", set: true, want: true},
		{value: "1", set: true, want: true},
		{value: "TRUE", set: true, want: true},
		{value: "on", set: true, want: true},
		{value: "false", set: true, want: false},
		{value: "0", set: true, want: false},
		{value: "off", set: true, want: false},
		{value: "flase", set: true, want: false, wantLog: true},
		{value: "disabled", set: true, want: false, wantLog: true},
		{value: "nope", set: true, want: false, wantLog: true},
		{value: "yes please", set: true, want: false, wantLog: true},
	}
	for _, testCase := range cases {
		name := testCase.value
		if !testCase.set {
			name = "unset"
		}
		t.Run(name, func(t *testing.T) {
			if testCase.set {
				t.Setenv("MCP_ESCAPE_HATCH_WRITES_ENABLED", testCase.value)
			} else {
				t.Setenv("MCP_ESCAPE_HATCH_WRITES_ENABLED", "")
			}
			logs := &safeBuffer{}
			restore := log.Writer()
			log.SetOutput(logs)
			defer log.SetOutput(restore)

			if got := escapeHatchWritesEnabled(); got != testCase.want {
				t.Fatalf("escapeHatchWritesEnabled() = %v, want %v", got, testCase.want)
			}
			logged := strings.Contains(logs.String(), "MCP_ESCAPE_HATCH_WRITES_ENABLED")
			if logged != testCase.wantLog {
				t.Fatalf("logged = %v, want %v (log: %q)", logged, testCase.wantLog, logs.String())
			}
			if testCase.wantLog && !strings.Contains(logs.String(), testCase.value) {
				t.Fatalf("the log does not name the rejected value: %q", logs.String())
			}
		})
	}
}

// The tool's input schema is the other place the model reads the accepted
// verbs. With writes off it must offer GET alone, or the model is invited to
// attempt a request the handler will refuse.
func TestPostgrestRequestSchemaTracksSetting(t *testing.T) {
	readOnly := postgrestRequestSchema(false).Properties["method"]
	if got := fmt.Sprint(readOnly.Enum); got != "[GET]" {
		t.Fatalf("read-only method enum = %v, want [GET]", readOnly.Enum)
	}
	for _, verb := range []string{"POST", "PATCH", "DELETE"} {
		if strings.Contains(readOnly.Description, verb) {
			t.Fatalf("read-only method description still advertises %s: %q", verb, readOnly.Description)
		}
	}

	writable := postgrestRequestSchema(true).Properties["method"]
	if got := fmt.Sprint(writable.Enum); got != "[GET POST PATCH DELETE]" {
		t.Fatalf("writable method enum = %v", writable.Enum)
	}
}

// Same reasoning for the server instructions, which every client reads once at
// initialize and which used to say other verbs need only the write scope.
func TestServerInstructionsTrackEscapeHatchSetting(t *testing.T) {
	readOnly := serverInstructions(false)
	if !strings.Contains(readOnly, "accepts GET only") || !strings.Contains(readOnly, "submit_submission_change") {
		t.Fatalf("read-only instructions = %q", readOnly)
	}
	if strings.Contains(readOnly, "other verbs need the write scope") {
		t.Fatal("read-only instructions still advertise the mutating verbs")
	}

	writable := serverInstructions(true)
	if !strings.Contains(writable, "other verbs need the write scope") {
		t.Fatalf("writable instructions = %q", writable)
	}

	// Both postures keep the untrusted-content warning and the call order.
	for _, instructions := range []string{readOnly, writable} {
		if !strings.Contains(instructions, "untrusted data written by course participants") {
			t.Fatalf("instructions lost the untrusted-content warning: %q", instructions)
		}
		if !strings.Contains(instructions, "Suggested call order") {
			t.Fatalf("instructions lost the call order: %q", instructions)
		}
	}
}
