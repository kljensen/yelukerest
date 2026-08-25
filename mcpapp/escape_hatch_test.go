package main

// Tests for the escape hatch (issue #268): GET happy path and query
// building, path constraints, the verb-keyed scope gate for non-GET requests,
// response size caps, audit logging, and the schema tool bound.

import (
	"context"
	"encoding/json"
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

// With the write scope the request simply executes: there is no intent token,
// no preparation step, and no confirmation round trip left on this path. The
// scope the student granted on the consent screen is the whole gate, and RLS
// enforces the rest.
func TestPostgrestRequestNonGETWithWriteScopeExecutes(t *testing.T) {
	fake := newFakePostgREST(t)
	fake.respondMethod(http.MethodPatch, "/assignment_field_submissions", http.StatusOK,
		`[{"assignment_submission_id":1,"assignment_field_slug":"secret","body":"new"}]`)

	logs := &safeBuffer{}
	deps := fake.deps(t)
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
