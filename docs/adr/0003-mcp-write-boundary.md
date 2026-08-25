# ADR 0003: The Write Scope And RLS Are The MCP Write Boundary

## Status

Accepted, 2026-08-25. Records a decision taken on 2026-08-06 (commit `94be2f2`,
closing issues #284, #285, #286) and written up here in issue #327, nineteen days
late.

Partially supersedes [ADR 0001](0001-mcp-and-oauth.md) — only its write-gate
portions: the prompt-injection mitigation in *Threat Model Summary* and the
non-GET clause of *Escape Hatch: `postgrest_request` Kept, Gated*. Everything
else in ADR 0001 — Hydra, the token exchange, the audited minting function, the
curated-tool decision, the escape hatch itself — stands unchanged.

## Context

ADR 0001 was accepted on 2026-08-05 and said that MCP writes are protected by a
two-step prepare/commit flow with short-lived single-use intent tokens, plus MCP
elicitation confirmation where clients support it.

That was not aspirational. It was built the same morning. Commit `9e027b0`
(2026-08-05 11:49, roughly 2,749 added lines) added
`prepare_submission_change`/`commit_submission_change`, `prepare_api_request`, a
gated non-GET `postgrest_request`, five-minute HMAC intent tokens keyed off a
per-process salt, single-use nonce tracking, and real MCP form elicitation. The
tests covered expiry, replay, tampering, a different user, a different access
token, content and request mismatch, scope denial, and confirmation. The design
was implemented and it worked.

Commit `94be2f2` deleted it the next day, 2026-08-06 11:41, after the agent
dogfood suite ran against it. `prepare_submission_change` and
`commit_submission_change` became `preview_submission_change` and
`submit_submission_change`; `prepare_api_request` and `intent.go` were removed
outright.

That commit updated `docs/api-client-security.md`, `docs/mcp-for-students.md` and
`docs/testing-agents.md`, and added `docs/mcp-writes.md`. It did not update ADR
0001, so the ADR went on describing a control the code no longer had until issue
#327 caught it. The lesson is recorded under *Consequences*.

One thing git proves and one it does not. It proves the gate existed in this
repository, fully implemented and tested, for about twenty-six hours. It does not
prove that version was ever deployed to production; no deployment record was
consulted for this ADR, and nothing here should be read as a claim that students
ever met the confirmation flow.

## Decision

**The OAuth write scope and PostgreSQL row-level security are the boundary on
MCP writes.** A write requires `submissions:write`, granted by the student on the
consent screen for that specific client, and RLS underneath it. There is no
confirmation dialog, no intent token, and no two-step commit on the server.

That is deliberately the same authority the student already has through the
course website, or by calling PostgREST directly with their own JWT
(`docs/api-client-security.md`). `docs/mcp-writes.md` is the operational
statement of this decision; two test suites assert against it.

### Why the gate was removed

Four reasons, all surfaced by the agent dogfood suite.

1. **It granted less than the API it fronts.** A student can already `PATCH`
   their own submission from curl with no ceremony. A gate that exists only on
   the MCP path removes no capability; it only makes the front door worse than
   the side door. The escape hatch was kept on exactly that principle (ADR 0001,
   *Escape Hatch*), and the write gate violated it.
2. **Confirming a tool call is the host's job, and hosts show the arguments.**
   The MCP specification puts a human in the loop at the client, and clients
   SHOULD display tool inputs before calling the server — the actual text being
   written. Our own server-generated confirmation message never showed the
   arguments (issue #284). `destructiveHint: true` on the write tools is the
   standardized way to ask a host for that prompt, and we already publish it.
3. **The mechanism was withdrawn from the protocol.** Elicitation reached the
   client as a server-initiated request on a held-open SSE stream, and the
   current revision forbids servers sending independent requests on that stream.
   Ours also broke in practice: holding a tool call open while waiting for a
   human wedged sessions and leaked them until the process restarted (issue
   #286).
4. **Almost no client implements elicitation, and we failed closed.** A client
   without form elicitation could not write at all. That meant writes did not
   work in the clients students actually use, while any student who reached for
   curl was unaffected — cost with no corresponding protection.

### What protects a write now

- **The `submissions:write` scope.** Advertised so a client can ask for it, but
  its checkbox on the consent page starts **unticked** — permissions that change
  data are never granted by default (`authapp/oauth.go`). A read-only token
  cannot write however the agent is prompted or fooled.
- **Row-level security.** Every tool call runs under the student's own internal
  JWT, so an agent reaches only rows the student reaches. This is the guarantee
  that holds when the model does something stupid.
- **`destructiveHint: true`** on `submit_submission_change` and on
  `postgrest_request`, requesting the host's confirmation prompt.
- **The append-only mint ledger `data.mcp_jwt_mint_event`**, which records every
  internal JWT minted for MCP: subject, caller app, jti, granted scopes, external
  issuer/sub/jti and OAuth client id. It answers who could have acted.
- **Revocation.** A student disconnecting an application at
  `/auth/connected-apps` revokes Hydra's consent sessions and appends to
  `data.mcp_grant_revocation`, which `api.issue_user_jwt_for_mcp` reads before
  minting. An already-issued access token stops working within the internal
  credential's ten-minute lifetime (`docs/hydra.md`).

### What is deliberately not a security control

- **Optimistic concurrency.** `preview_submission_change` returns
  `current_updated_at` and a write may pass it back as `expected_updated_at`, so
  a write that would clobber a value that moved is rejected. This is a
  correctness feature for concurrent writers. It is **not** a security control:
  an injected agent can preview and submit back to back, and nothing requires it
  to preview at all.
- **Host confirmation.** We expect hosts to prompt, and we annotate the tools to
  ask for it. But it is the host's behaviour, not ours: a client that ignores
  `destructiveHint` writes without prompting, and the server cannot tell. Host
  confirmation is good agent design and must never be described as a
  server-enforced property.

## Consequences

- Writes work in the clients students actually use, because nothing depends on
  an elicitation capability those clients lack.
- The MCP surface grants exactly what the student's own credential grants, which
  makes it reviewable against one rule instead of two.
- `mcpapp` no longer carries intent-token key material, a nonce store, or an
  assumption of a single replica — the nonce set was in-memory, so the old design
  would have had to grow shared state before mcpapp could ever run replicated.
- The residual risk below is accepted rather than mitigated in the server. If it
  ever becomes unacceptable, the answer is not to rebuild this gate; reasons 1–4
  will still hold. It is to narrow what the write scope can reach.
- A commit that changes an architectural decision must change the ADR in the same
  commit. `94be2f2` updated four documents and missed the one whose entire job is
  recording decisions, and nobody noticed for nineteen days. Issue #327 asks for
  some check on ADR claims that quietly stop being true.

## Threat Model Summary

**Prompt injection via course content — accepted residual risk.** Tool results
include text written by other people: teammate submissions, faculty comments,
discussion content. An injected instruction can steer a victim's agent. If that
agent holds `submissions:write`, it can alter coursework reachable through the
student's own privileges — including team submissions, which team RLS policies
make writable by any member.

RLS bounds this to the *student's privileges*. It does not bound it to the
*student's intent*. That gap is the accepted risk, and it is the same exposure a
student accepts by running any script with their own API credential.

What stands against it: the student decides at consent whether to grant the write
scope at all, and the box starts unticked; the host prompts on a tool annotated
destructive; `serverInstructions` tells the model to treat tool results as
untrusted data; RLS bounds the blast radius; the mint ledger and
`data.mcp_grant_revocation` give an after-the-fact record and a way to cut the
application off. `tests/agent/prompt-injection.js` asserts the division: with a
read-only token an injection can never produce a write, and with a write token
the damage stays inside the student's own rows however thoroughly the model is
fooled. Whether the model falls for the injection is recorded, not asserted.

Deletion is narrower than the `DELETE` grant suggests: `NO ACTION` foreign keys
from `assignment_field_submission` and `assignment_grade` mean a submission
holding content, or carrying a grade, cannot be deleted through this path
(`docs/mcp-writes.md`).

## Accuracy Defects In ADR 0001's Original Wording

Two claims in ADR 0001 were wrong about the gate even while the gate existed.
Recording them so the superseded text is not read as an accurate description of
what was built.

1. **The intent token was not bound to the OAuth `client_id`.** ADR 0001 said the
   binding was "(user, client, assignment, field, expected version, content
   hash)". The signed payload in `mcpapp/intent.go` carried the `jti` of the
   *access token* used to prepare — not a client identifier. Practically that was
   tighter, not looser: a second token issued to the same OAuth client could not
   commit a change the first one prepared. But the ADR described a binding the
   code did not have.
2. **"Elicitation confirmation where clients support it" understated the
   consequence.** The implementation failed **closed**: a client that did not
   advertise MCP form elicitation could read but could not write at all
   (`errWriteConfirmationUnsupported`). ADR 0001's phrasing reads as graceful
   degradation. It was not, and reason 4 above is precisely the fallout the ADR
   never recorded.

## Related Decisions

- Partially supersedes [ADR 0001: MCP Server And OAuth Architecture](0001-mcp-and-oauth.md).
- [ADR 0002: Authentication For Admin API Commands](0002-admin-api-authentication.md)
  borrows ADR 0001's minting pattern; nothing here changes it.

## References

- `docs/mcp-writes.md` — the operational statement of this decision.
- `docs/api-client-security.md` — what a student can already do with their own JWT.
- `docs/hydra.md` — consent, disconnection, and the revocation ledger.
- `mcpapp/write_tools.go`, `mcpapp/escape_hatch.go` — the code this ADR describes.
- Commits `9e027b0` (built the gate), `94be2f2` (removed it).
- Issues #267, #268 (the gate), #284, #285, #286 (its removal), #327 (this ADR).
