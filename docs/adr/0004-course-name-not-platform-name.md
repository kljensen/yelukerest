# ADR 0004: Students See The Course's Name; Compatibility Identifiers Keep The Platform's

## Status

Accepted, 2026-09-02. Records the decision behind milestone "Roadmap 17: MCP
Naming And Discovery" (issues #371–#375). Plan reviewed with codex over two
rounds.

## Context

The platform is called `yelukerest`. Students are taking MGT656 and have never
heard of it. Until now the name reached them anyway: the MCP server introduced
itself to their AI assistant as `yelukerest-mcp` / "Yelukerest MCP Server", the
error shown when a connection is misconfigured said "the access token granted no
yelukerest scopes", and the schema document returned by `get_api_schema` was
headed "# Yelukerest REST API".

The obvious response — replace every occurrence — is wrong, because the name is
doing two unrelated jobs. In some places it is a label a person reads. In others
it is an identifier two systems agree on.

## Decision

**Presentation strings take the course's name.** Anything a student or their
assistant reads says MGT656, or simply "course". The MCP server's
`Implementation.Title` is derived from `COURSE_TITLE`, which the web client and
`authapp/openapi.go` already use for the same purpose.

**`Implementation.Name` is configured, not derived.** The vendored SDK describes
`Name` as "intended for programmatic or logical use" and `Title` as "intended
for UI and end-user contexts". A machine identifier that changed every August,
as a course title does, would be the wrong kind of stable. It comes from
`MCP_SERVER_NAME`, set to `mgt656-mcp`, and is expected to outlive any one term.

**These keep the platform name, deliberately and permanently:**

| identifier | why it cannot move |
| --- | --- |
| `JWT_ISSUER`, `JWT_AUDIENCE` | The database pre-request hook and authapp validate tokens against them. Renaming invalidates every token in circulation and needs a coordinated DB settings change, an `AUTHAPP_JWT` remint, and a rollout window. |
| the MCP JWT audience | Same contract, minted side. |
| `api.platform_version.platform` | Explicitly a compatibility identifier, read by admin tooling to decide what the schema supports. It is granted to `anonymous` and `student`, so it is genuinely visible — and still must not change. |
| `WWW-Authenticate: Bearer realm="yelukerest"` | A protocol label on `/auth/token`, not part of the MCP flow and not prose anyone reads. Left alone rather than churned for consistency's sake. |

The next person who greps for `yelukerest` and decides to finish the job should
read this table first. Finishing the job breaks token validation.

## Consequences

A student now sees one name for the course everywhere, and the identifiers two
machines agree on stay put. The cost is that "is this string presentation or
protocol?" becomes a question every future contributor has to ask, which is why
the table above is exhaustive rather than illustrative.

Separately, and found while doing this: the server instructions claimed
"curated read-only tools" while `registerWriteTools` was registering
`submit_submission_change`. That is not a naming problem — server instructions
are injected into the calling model's context, so the server was understating
its own capability to a model acting on a student's behalf. Fixed under #372 and
recorded here only because it was found by the same audit. The write boundary
itself is unchanged and still governed by [ADR 0003](0003-mcp-write-boundary.md).
