# ADR 0001: MCP Server And OAuth Architecture

## Status

Accepted, 2026-08-05. The architecture and its alternatives were researched and
adversarially reviewed (multi-model) on 2026-08-05. Implementation is tracked in
the "Roadmap 6: MCP and OAuth" milestone (issues #261–#278).

**Partially superseded by [ADR 0003: The Write Scope And RLS Are The MCP Write
Boundary](0003-mcp-write-boundary.md), 2026-08-06.** The MCP write-gate portions
of this ADR — the two-step prepare/commit flow, intent tokens, and elicitation
confirmation — are **no longer in force**. They were built (`9e027b0`) and
deleted a day later (`94be2f2`); ADR 0003 records why and states what bounds
writes now. Every other decision here stands. The stale passages are marked in
place rather than removed, at *Threat Model Summary* and *Escape Hatch*.

Amended 2026-08-25: phase 0 retired. The decision itself stands; only the first
step of the phased rollout is gone. See the retirement note under *Phased
rollout*.

Accuracy pass, 2026-08-25 (issue #327). Every claim in this ADR was checked
against the code. The decision stands; several of its supporting claims did not.
Corrections are marked in place, never by deleting the original: a blockquote
saying **NEVER TRUE** marks a claim that was wrong when written, and one saying
**NO LONGER TRUE** or **SUPERSEDED** marks a claim that has since changed —
which of the two it was is itself part of the record. Markers were added under
*MCP server* (protocol eras), *Token exchange*, *Phased rollout* (phase 2),
*Threat Model Summary*, *Policy Note*, *Consequences*, and the *Caveats
Register*. A new subsection, *Controls the code has that this ADR did not name*,
records load-bearing controls this ADR omitted entirely.

## Context

Students should be able to connect AI agents — Claude Desktop, claude.ai,
ChatGPT, Claude Code, and self-written clients — to the course app via MCP
(Model Context Protocol) to read assignments and grades and to submit work.

Yelukerest is database-centric: PostgREST exposes the API, and PostgreSQL
grants plus row-level security are the sole authorization authority
(`docs/auth-jwt-flow.md`). Browser auth is a CAS-backed `authapp` session that
mints short-lived internal user JWTs for PostgREST. Any MCP design must
preserve that model: no second authorization system, no bypass of RLS, and no
new long-lived credentials.

The MCP spec's remote-server auth story is OAuth 2.1 with Dynamic Client
Registration (DCR), RFC 9728 protected-resource metadata, and RFC 8707
`resource` binding. Real clients in mid-2026 implement this unevenly (see the
caveats register below), which shaped both the phasing and the alternatives
analysis.

## Decision

### MCP server: a new Go `mcpapp` with curated tools

A new top-level Go service `mcpapp` (vendored, stdlib-first, matching authapp
conventions) serves a small set of curated tools using the official
[`modelcontextprotocol/go-sdk`](https://github.com/modelcontextprotocol/go-sdk),
pinned to a stable (non-pre-release) version. Every tool is a thin call to
PostgREST over the internal network carrying the calling student's own internal
JWT, so RLS remains the sole authorization authority — mcpapp adds intent and
presentation controls, never permissions.

> **"intent controls" is HISTORICAL.** It meant the intent-token write gate,
> removed 2026-08-06 ([ADR 0003](0003-mcp-write-boundary.md)). What mcpapp adds
> today is curation, scope checks and presentation — still never permissions,
> which is the part of this sentence that matters and still holds.

Protocol eras: mcpapp serves the 2025-11-25 protocol era by default. The
2026-07-28 stateless era sits behind an env feature flag because go-sdk support
for it (`StreamableHTTPOptions.Stateless`) is pre-release and observed
Claude/ChatGPT traffic is still legacy-era. The flag flips to default only when
both conditions clear (issue #278).

> **SUPERSEDED BY WHAT SHIPPED — the flag has already flipped.**
> `MCP_STATELESS_ENABLED` defaults to **true** as of 2026-08-07 (`26ebcd2`,
> `mcpapp/main.go`), and go-sdk is pinned to the stable **v1.7.0**, in which
> `StreamableHTTPOptions.Stateless` is no longer pre-release. The stateful
> handler is what now sits behind a flag: `MCP_STATELESS_ENABLED=false`. See the
> marker on *Phase 2* below for how the second gating condition was resolved.

### OAuth: Ory Hydra with login/consent delegated to authapp

[Ory Hydra](https://github.com/ory/hydra) v26.2.0 (pinned) is the OAuth 2.1
authorization server. Hydra is a good fit precisely because it is *only* an
OAuth/OIDC engine: it owns clients, codes, tokens, DCR, and PKCE, and delegates
login and consent to redirect URLs we control. authapp implements those
handlers against its existing CAS session — no user database duplication, no
identity-provider migration, no CAS plugin. The consent page names the client
and the data categories shared (see the policy note below).

### Token exchange: Hydra tokens never reach PostgREST

Hydra-issued access tokens are validated by mcpapp (JWKS, issuer, expiry,
strict audience) and go no further. mcpapp exchanges the verified identity for
an internal user JWT by calling a new dedicated DB function,
`api.issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb DEFAULT NULL)`:

- Admits only a distinct `app_name=mcpapp` service credential — never
  authapp's — so either credential can be revoked independently.

  > **"REVOKED INDEPENDENTLY" WAS NEVER TRUE.** This was wrong the day it was
  > written; it is not a claim that stopped being true later. Both service
  > credentials are stateless HS256 JWTs signed by the same `JWT_SECRET`
  > (`bin/jwt.sh`, five-year default expiry) and accepted on signature, expiry,
  > role and `app_name` alone. There is no credential-version table, no `jti`
  > registry and no `revoked_at` for service tokens, so minting a replacement
  > `mcpapp` credential invalidates nothing — the stolen one is still validly
  > signed and still carries `app_name = 'mcpapp'`. The only actual revocation
  > is rotating `JWT_SECRET`, which invalidates every student session. The one
  > independent lever that does exist is
  > `REVOKE EXECUTE ON FUNCTION api.issue_user_jwt_for_mcp(text, text[], jsonb) FROM app`,
  > which withdraws the *capability* from both service credentials at once —
  > not the credential from one of them.
  >
  > What the separate path does buy is real and still holds: authapp's
  > credential cannot mint through this function, so a compromise of authapp is
  > not automatically a compromise of this path, and every mint here is audited.
  > [ADR 0002](0002-admin-api-authentication.md), under *Revocation needs
  > database state, not just a new token*, documents this exact gap and states
  > that it applies to the mcpapp path too. Closing it is a code change tracked
  > separately, not a documentation change.

- Mints a short internal JWT (~10 minutes, not the browser flow's 1 hour) with
  a `scopes` claim.
- Writes an append-only mint-audit row in the same transaction: subject,
  caller app name, jti, granted scopes, external issuer/sub/jti and OAuth
  client id when present, timestamp.
- The netid comes only from verified token claims, never from request input.

PostgREST therefore sees exactly the token shapes it sees today, and the JWT
validation discipline in `api.check_request_jwt` is unchanged. Keeping the two
token domains separate means a Hydra misconfiguration (or one of its known
client-compatibility bugs) can never produce a token PostgREST accepts.

> **NO LONGER TRUE — AND THE DRIFT IS TOWARD STRICTNESS.** Two halves of the
> first sentence have both stopped being accurate.
>
> `api.check_request_jwt` is **not** unchanged. Migration
> `01a02545-…-enforce-scopes-on-writes` (2026-08-21, `302e775`, issue #317)
> rewrote it: a token carrying a non-empty `scopes` claim is now refused on any
> request method other than `GET`, `HEAD` or `OPTIONS` unless the claim contains
> `submissions:write`. Tokens with no `scopes` claim — the browser JWT and the
> service credentials — are unaffected.
>
> And PostgREST does **not** see only the token shapes it saw before. An
> MCP-minted JWT carries an array `aud` and a `scopes` claim the browser JWT has
> never had; `check_request_jwt` accepts audience by string equality *or* array
> membership for exactly that reason.
>
> Both differences make PostgREST stricter than this paragraph describes, so
> nothing built on the paragraph is unsafe. It is corrected rather than left
> alone because this paragraph is the ADR's entire argument for the two token
> domains staying disjoint, and an argument that cannot be checked against the
> code is not an argument. The conclusion itself still holds, on firmer ground
> than stated: a Hydra token is signed asymmetrically against Hydra's JWKS and
> PostgREST verifies HS256 against `JWT_SECRET`, so no Hydra misconfiguration
> can produce a token PostgREST accepts.

### Phased rollout

- **Phase 0 — bearer tokens.** Session-gated `/auth/mcp-token` endpoint mints
  bearer tokens via the audited function. Their audience is an array holding
  both `yelukerest-mcp` and `yelukerest-postgrest`: mcpapp accepts the token
  and forwards that same token to PostgREST, and both verifiers check
  audience by membership. Serves Claude Code, Cursor, VS Code, curl, and
  self-written clients before OAuth lands.
- **Phase 1 — Hydra OAuth.** DCR + PKCE + delegated CAS consent for Claude
  Desktop, claude.ai, and ChatGPT. Gated by a spike proving the audience/RFC
  8707 story end-to-end (issue #271) and a real-client pilot on low-stakes
  accounts (issue #276).
- **Phase 2 — 2026-07-28 stateless era by default**, once go-sdk support is a
  stable release and a major client is observed speaking it.

  > **DONE, 2026-08-07 (`26ebcd2`) — and the second gate was resolved rather
  > than met.** The first condition cleared as written: go-sdk v1.7.0 is a
  > stable release. The second — "a major client is observed speaking it" — was
  > never satisfied and turned out not to need to be. It was a proxy for a
  > different worry: a stateless server cannot hold a session, and the only
  > thing in this design that needed one was the elicitation write gate, which
  > held a tool call open on the SSE stream. That gate was deleted on
  > 2026-08-06 ([ADR 0003](0003-mcp-write-boundary.md)), so the condition
  > dissolved instead of being waited out. Stateless is now the default and the
  > stateful handler is the fallback.

**Phase 0 retired, 2026-08-25** (commits `59325c3`, `d0c7a64`, `bcccd0b`,
closing issues #321, #322, #323 and #324 under umbrella issue #320).
`/auth/mcp-token` is gone and `/mcp` accepts OAuth alone. The plan above is left as written because it is what
was decided and it is why the code was built in that order; this note records
that its first step has been carried out and then withdrawn.

Two facts made the withdrawal safe rather than risky. It had **never been used**:
production `data.mcp_jwt_mint_event` held exactly one row, and it was an OAuth
mint (`external_client_id` populated), so no phase 0 token had ever been issued
and no student held one. And phase 1 was **proven end to end** — a real client
completed discovery, DCR, CAS login, consent, token exchange, and tool calls
against production — so the clients phase 0 existed to serve before OAuth landed
had a working path.

That left phase 0 strictly worse than both of its neighbours: 10 minutes with no
refresh against OAuth's sliding 30 days, and no revocation list or visible expiry
against a personal access token's. It was a second, weaker credential class
reaching the same authorization model, and it cost a shared-secret verifier on
the public `/mcp` surface for as long as it existed. Clients that cannot run the
OAuth flow use [`mcp-remote`](https://www.npmjs.com/package/mcp-remote); code a
student writes uses a personal access token against `/rest`. The accepted risk is
a client that can do neither; none is known.

Default-deny changed meaning with it. Phase 0 tokens carried no scopes claim, so
the rule as written then read *a token whose scope claim is missing or empty is
read-only at most* — that grandfathering applied to phase 0 bearer tokens and to
nothing else. With OAuth the only credential `/mcp` accepts, a token that grants
no recognised scope now gets no access at all.

Mint-audit rows written before that date may still carry
`client_id = authapp:/auth/mcp-token`; `docs/hydra.md` explains the value.

## Rejected Alternatives

- **Embed `zitadel/oidc` in authapp** — the runner-up. A maintained, certified
  Go library that would keep the stack at zero new containers. Rejected because
  it makes authapp implement and maintain the full AS surface (DCR, token
  storage, refresh rotation, revocation, discovery) in-process, coupling our
  most security-sensitive service to a fast-moving spec. Revisit if Hydra's
  operational cost exceeds its value.
- **Keycloak** — capable but heavy: a JVM service larger than the rest of the
  stack combined, and CAS federation requires building and maintaining a
  third-party plugin against Keycloak's release cadence.
- **Dex** — no Dynamic Client Registration, no CAS connector, no custom access
  token claims; three hard requirements missed.
- **Authentik** — DCR is gated behind the enterprise tier and there is no CAS
  federation path.
- **Casdoor, Pocket ID** — cannot federate to an upstream CAS server; both
  want to *be* the identity provider, which duplicates the user database.
- **MCP auth proxies (sigbit/mcp-oauth-proxy, obot)** — these translate MCP
  OAuth to an *upstream OIDC* provider. Yale CAS is not OIDC, so a proxy would
  still need an AS in front of CAS — the very component being chosen.
- **OpenAPI→MCP tool generation** — generating one tool per PostgREST
  endpoint produces on the order of a hundred CRUD tools. Tool-sprawl research
  and vendor guidance agree that model tool-selection accuracy collapses well
  before that; a curated set of ~10–20 richly described tools outperforms it.
  The escape hatch below covers the long tail.
- **Build the AS on `ory/fosite` or `go-oauth2/oauth2` directly** — both
  libraries are effectively dormant; assembling an AS from a dormant toolkit is
  worse than either embedding a maintained library or running Hydra.

## Threat Model Summary

- **Prompt injection via course content.** Tool results include text written
  by other people: teammate submissions, faculty comments, discussion content.
  An injected instruction can steer a victim's agent. RLS bounds any resulting
  write to the *student's own privileges* — but not to the *student's intent*:
  team RLS policies make shared submissions writable by any member, so an
  injected agent can corrupt the victim's or their team's own work while
  staying entirely inside RLS. Mitigation: writes use a two-step
  prepare/commit flow with short-lived single-use intent tokens bound to
  (user, client, assignment, field, expected version, content hash), plus MCP
  elicitation confirmation where clients support it (issue #267). Client-side
  annotations are advisory and are never relied on.

  > **HISTORICAL — NOT CURRENT BEHAVIOUR.** Everything from "Mitigation:"
  > onward was reversed on 2026-08-06 by `94be2f2` and is superseded by
  > [ADR 0003](0003-mcp-write-boundary.md). There is no prepare/commit flow, no
  > intent token, and no elicitation confirmation. Writes are bounded by the
  > `submissions:write` scope — unticked by default at consent — and by RLS;
  > `destructiveHint` on the write tools asks the *host* to confirm, and that
  > client-side annotation **is** now relied on for the prompt, which is the
  > opposite of the last sentence above. The threat described in the first half
  > of this bullet is real and is accepted; see ADR 0003's threat model. ADR 0003
  > also records two ways this sentence misdescribed the gate even while it
  > existed: the binding was to the access token's `jti`, not the OAuth client,
  > and "where clients support it" was in fact fail-closed.

- **mcpapp minting-credential blast radius.** mcpapp is a public endpoint
  holding a credential that mints user JWTs. If it reused authapp's
  unrestricted credential, compromise would mean minting faculty tokens.
  Mitigations: a distinct `app_name=mcpapp` credential, independently
  revocable; minting restricted to student/ta subjects initially (faculty
  access is an explicit opt-in decision, issue #263); ~10-minute token TTL;
  every mint audited, with an alert query for one credential minting unusually
  many distinct subjects in a short window.

  > **TWO OF THESE MITIGATIONS WERE NEVER TRUE.** Not stale — wrong when
  > written.
  >
  > *"Independently revocable."* See the marker under *Token exchange* above.
  > Both service credentials are stateless HS256 JWTs under the same
  > `JWT_SECRET` with a five-year default lifetime, and there is no state that
  > could invalidate one of them.
  >
  > *"Minting restricted to student/ta subjects initially."* It never was.
  > `api.issue_user_jwt_for_mcp` reads the allowlist from the course setting
  > `mcp_mintable_roles`, which **defaults to `'student,ta,faculty'`**, and
  > nothing in the schema, migrations, or sample data seeds that setting — so
  > the default is what runs (`db/src/api/yeluke/mcp_jwt.sql`). This has been
  > the behaviour since the first implementation commit (`4af2e45`,
  > 2026-08-05), whose own inline comment says faculty are included because the
  > pilot runs on faculty accounts. It matters precisely here, because the
  > mintable-role set is what bounds a compromised `MCPAPP_JWT`: today that
  > compromise does mean minting faculty tokens, which is the outcome this
  > bullet says was avoided. Tightening it is one statement —
  > `select settings.set('mcp_mintable_roles', 'student,ta');` — and is an
  > operational decision the course operator must take deliberately; this ADR
  > never established it.
  >
  > The remaining mitigations in this bullet are real and in force: the
  > ~10-minute TTL, the same-transaction append-only mint audit
  > (`data.mcp_jwt_mint_event`), and the alert query
  > (`api.mcp_jwt_mint_anomalies`, >10 distinct subjects in a sliding 10-minute
  > window).

- **Grade-data exfiltration channels.** Once grades flow through an agent,
  they can leak via model context sent to third-party providers, via tool
  results echoed into other tools, or via the escape hatch. Mitigations:
  grades appear only in the two dedicated grades tools, `get_my_grades` and
  `get_my_quiz_grades` (never in broad "course context" responses) — with one
  deliberate exception, the anonymized class distribution `get_assignment`
  includes once at least three grades exist; output size caps with explicit
  truncation markers, no auto-fetching of URLs found in database text,
  structured audit logs with grade/submission-body redaction, and the consent
  screen naming grades as a shared data category.

  > **THE CONSENT CLAUSE OVERSTATES THE GRANULARITY, AND ALWAYS DID.** The
  > consent screen does name grades as a separate category with its own
  > checkbox, but mcpapp does not enforce that separation: `scopeAliases` in
  > `mcpapp/tools.go` collapses `course:read`, `grades:read` and
  > `submissions:read` into a single `read` requirement, so a token granted only
  > `course:read` can call `get_my_grades`. The read scopes are one scope in
  > effect. This is a code defect, filed separately; it is recorded here so the
  > ADR is not read as promising per-category read enforcement that the server
  > does not perform.

### Controls the code has that this ADR did not name

Added 2026-08-25. None of the following were part of the original write-up, and
all of them are load-bearing today. An ADR that omits a control is an invitation
to delete it during a cleanup, which is the failure mode
[ADR 0003](0003-mcp-write-boundary.md) records under *Consequences*. Each entry
names the code so a reader can check it rather than trust this list.

- **Grant revocation on disconnect** (`data.mcp_grant_revocation`;
  `db/src/api/yeluke/mcp_jwt.sql`, the revocation block inside
  `api.issue_user_jwt_for_mcp`). Disconnecting an application at
  `/auth/connected-apps` revokes Hydra's consent sessions and appends a
  revocation row. Hydra kills the refresh token at once, but an access token
  already issued keeps verifying offline against the JWKS — so this check is
  **the only thing that stops an already-issued OAuth token**. It compares the
  external token's `iat` against `revoked_at` rather than merely asking whether
  a revocation exists, so reconnecting works: a token from a new grant is newer
  than the revocation. A five-second allowance absorbs clock skew between
  Hydra's clock and Postgres's, closing a bypass in which a token issued just
  before the disconnect carries an `iat` just after it; the cost is that a
  reconnection finished within five seconds is refused and the user clicks
  again. Removing or "simplifying" either the `iat` comparison or the skew
  allowance reopens a real hole.
- **Two-tier rate limiting** (`mcpapp/security.go`, wired in `mcpapp/main.go`).
  A coarse pre-auth limiter keyed on client IP runs *before* any signature
  verification, so an unauthenticated caller cannot spend unbounded CPU on
  JWKS-backed signature checks; a finer post-auth limiter is keyed on the
  **verified** token subject, never on a client-controlled header, with the IP
  as a fallback only. Both must stay: the outer one protects the verifier, the
  inner one protects the database from one authenticated account.
- **JWKS cache bounds** (`mcpapp/hydra.go`). A 15-minute maximum cache age, so a
  key withdrawn after a compromise cannot keep verifying tokens for the life of
  the process; a 30-second minimum refresh interval, so tokens carrying random
  `kid` values cannot drive one upstream fetch per request; a 1 MiB response
  cap; and a 2048-bit floor on RSA keys regardless of what the authorization
  server publishes. `kid` is required, because Hydra publishes both the id-token
  and access-token signing keys and rotation adds more.
- **ID-token rejection, on two independent grounds** (`mcpapp/hydra.go`). The
  `typ` header must be an accepted access-token type, and any token carrying an
  `at_hash` claim is refused as an id token. The audience check already refuses
  an id token, whose `aud` is the client id; these are deliberate belt and
  braces on the classic confused-deputy substitution.
- **Exchange cache keyed on the external token's `iat`**
  (`exchangeCacheKey`, `mcpapp/exchange.go`). The cache spares a database mint
  per request, and a cache hit never reaches the database — so it never meets
  the revocation check above. Including `iat` in the key confines each grant's
  internal credentials to itself, so a hit cannot outlive the grant it came
  from. The key also carries the OAuth `client_id`, so the mint-audit trail
  keeps naming the client that actually reached the data, and every component is
  length-prefixed so no value can be arranged to impersonate another tuple.

## Policy Note (FERPA / Institutional)

Sending grade data to third-party AI providers is a policy boundary, not just
a technical one. The consent screen must name the data categories being shared
(assignments, submissions, grades) and the third party receiving them.
Institutional/FERPA requirements must be confirmed before write scopes are
enabled for students in production (tracked in issue #276). Until then, writes
stay behind the pilot.

> **RESOLVED 2026-08-25: THERE WILL BE NO SUCH GATE, BY DECISION.** The
> paragraph above described a policy hold that was never implemented, and the
> course owner has now decided not to implement one: students are adults, and
> write access is theirs to grant on the consent screen. Issue #276 is closed on
> that basis. The consent page's obligations in the first two sentences stand —
> it names the data categories and the third party receiving them — and the write
> checkbox stays unticked by default, so granting it remains a deliberate act.
> What is gone is the idea that some further institutional gate stands behind it.
>
> The description of the implementation below was written before that decision
> and remains accurate as a statement of what the code does.
>
> **NO SUCH GATE EXISTS IN THE CODE, AND NONE EVER DID.** "Writes stay behind
> the pilot" describes a policy hold. In the implementation it is a checkbox
> default, and nothing more. Hydra's `default_scope` grants `submissions:write`
> to every client that registers through DCR (`hydra/hydra.yml`);
> `mcpapp/prm.go` advertises it in the RFC 9728 metadata so clients know to ask
> for it; the consent page renders its checkbox unticked (`authapp/oauth.go`)
> and a single tick is the only barrier between any student and a write-capable
> token. Separately and entirely outside this path,
> `api.create_user_api_token` — granted to `student`, `ta` and `faculty` — lets
> any student mint a personal access token carrying `submissions:write` with no
> consent screen involved at all. Nothing in the repository reads a pilot flag,
> a pilot roster, or an institutional-approval setting.
>
> The first half of this note *is* implemented: the consent screen names the
> client and the data categories. The FERPA obligation in issue #276 remains a
> real obligation. It is simply not enforced by anything here, and describing an
> unticked default as a policy gate is how a control comes to be believed in
> without being built.

## Escape Hatch: `postgrest_request` Kept, Gated

A `postgrest_request(method, path, query, body)` tool plus a trimmed
`get_api_schema` resource expose the full API for power users. One adversarial
review (Codex/gpt-5.6-sol) recommended removing this tool from the
student-facing server entirely, arguing it defeats curated scopes/validation
and exposes side-effecting RPCs that don't look like writes. **Decision: keep
it** (Kyle): it grants no capability a student lacks via the direct API —
students can already `curl` PostgREST with their own JWT today
(`docs/api-client-security.md`) — and RLS applies identically. Mitigations
adopted from the dissent:

- GET-only by default.
- Any non-GET verb requires write scope *and* the same intent-token/elicitation
  confirmation gate as the curated write tools, keyed on HTTP verb.

  > **HISTORICAL — NOT CURRENT BEHAVIOUR.** The gate in this bullet was
  > deleted on 2026-08-06 by `94be2f2`; see
  > [ADR 0003](0003-mcp-write-boundary.md). `prepare_api_request` no longer
  > exists. A non-GET `postgrest_request` requires `submissions:write` and
  > nothing else (`mcpapp/escape_hatch.go`). The rest of this section — keep the
  > tool, GET-only default, `/rest/*`, caller's own JWT, size caps, audit
  > logging — is unchanged and in force. The irony is recorded in ADR 0003: this
  > section's own argument, that the front door must not grant less than the side
  > door a student can already `curl`, is what removed the gate.

- Constrained to `/rest/*` — in practice tighter than that phrase suggests.
  `mcpapp/escape_hatch.go` admits only a single lowercase path segment
  (`^/[a-z_][a-z0-9_]*$`): one PostgREST view or table, no traversal, no dots,
  and **no `/rpc/*` function calls by construction**. That is exactly the
  side-effecting-RPC concern the recorded dissent raised, closed by the shape
  of the pattern rather than by a list of blocked names. Plus the caller's own
  internal JWT, response size caps, and every call audit-logged.

The dissent is recorded on issue #268; revisit before Phase 1 student rollout.

## Consequences

- One new Go service (mcpapp) in Phase 0; one new container (Hydra) plus a
  Postgres database for it in Phase 1. Compose, Caddy, doctor, and runbook
  work scale accordingly.
- The DB gains a second service role and an audited minting function; the
  existing authapp path is untouched.

  > **"A SECOND SERVICE ROLE" WAS NEVER TRUE.** There is one `app` role.
  > mcpapp holds a second *credential* in that same role, distinguished only by
  > its `app_name` claim, which `api.issue_user_jwt_for_mcp` checks in the
  > function body. Every `GRANT … TO app` is therefore shared by authapp and
  > mcpapp — including `GRANT EXECUTE … TO app` on the minting function itself
  > (`db/src/authorization/yeluke/mcp_jwt.sql`) — and the separation between the
  > two services is enforced inside the function, not by the grant system.
  > [ADR 0002](0002-admin-api-authentication.md) states it correctly: "a
  > dedicated service credential **in the `app` role**". This is the same family
  > of overstatement as "independently revocable" above. The rest of this bullet
  > — the audited minting function, the untouched authapp path — is accurate.

- Scope enforcement is default-deny: a token whose granted scopes map to nothing
  this server exposes gets no access at all, reads included (this also defuses
  the Claude Code scope-omission bug below).

  > **THE PARENTHESIS IS WRONG ABOUT WHICH CONTROL DOES THE WORK.**
  > Default-deny is real and in force (`authorizeScope`, `mcpapp/tools.go`),
  > but it fails **closed**: a client that omits scopes connects successfully
  > and then has every tool call refused. It does not defuse the scope-omission
  > bug — it is what makes that bug visible to the student as a server that
  > answers nothing. The control that makes such a connection actually *work* is
  > scope **advertisement**: `prmScopesSupported` in `mcpapp/prm.go` and
  > `default_scope` in `hydra/hydra.yml`, both added 2026-08-21 in `4a763e5`.
  > Neither was in the caveats register, which this ADR tells a reader to
  > re-check and prune every semester — so both are now registered explicitly as
  > permanent and load-bearing.

- Client bugs become our operational surface: the caveats register below must
  be re-checked each semester, and a DCR response-cleaning proxy plus a
  client-pruning job exist to work around upstream defects (issue #272). The
  client-pruning job is deletable once upstream fixes ship. **The register
  proxy is not.** Its response *cleaning* goes away with
  [ory/hydra#4044](https://github.com/ory/hydra/issues/4044), but the same
  proxy also injects the client `audience` allowlist
  (`injectRegistrationAudience`, `authapp/register.go`), which Hydra requires
  by design and not by defect: without it the initial token exchange succeeds
  and every refresh fails (spike finding 2 below, and the caveats row that
  records the injection). Deleting the proxy wholesale on the day #4044 merges
  would break refresh for every DCR client.

## Caveats Register

Re-check every entry at the start of each semester and before flipping any
feature flag. Append pilot and spike findings here (issues #271, #276).

| Caveat | Upstream | Status 2026-08-05 | Our workaround |
| --- | --- | --- | --- |
| Hydra DCR responses include null/empty optional fields that break strict-parser MCP clients (mcp-remote, Cursor, TS-SDK-based); confirmed in a comparable Hydra+MCP deployment (getlarge.eu) | [ory/hydra#4044](https://github.com/ory/hydra/issues/4044), fix [PR #4050](https://github.com/ory/hydra/pull/4050) | Open; PR unmerged, no nightly images | Response-cleaning proxy on `/oauth2/register` implemented in authapp (`authapp/register.go`, issue #272; also injects the audience allowlist from the #271 spike); remove the cleaning when fixed upstream |
| Hydra lacks Client ID Metadata Documents (CIMD); may matter as DCR sunsets | [ory/hydra#4061](https://github.com/ory/hydra/issues/4061) | Open | None needed yet; re-check at Phase 2 |
| Hydra does not implement RFC 8707 `resource`; it has its own `audience` mechanism | Hydra docs / #4061 discussion | No RFC 8707 support | Spike (issue #271) proves audience binding end-to-end or adds an adapter; mcpapp rejects missing/empty `aud` — audience validation is never disabled |
| go-sdk 2026-07-28 stateless-era support is pre-release | [modelcontextprotocol/go-sdk](https://github.com/modelcontextprotocol/go-sdk) | ~~Pre-release~~ **Resolved 2026-08-07 (`26ebcd2`): stable in the pinned v1.7.0** | ~~Pin stable release; 2026 era behind env flag~~ **Now inverted: `MCP_STATELESS_ENABLED` defaults to true and the stateful handler is what sits behind the flag** |
| Claude Code: localhost-loopback redirect handling and scope omission on connect | [anthropics/claude-code#42765](https://github.com/anthropics/claude-code/issues/42765) | Open | Register both 127.0.0.1 (port-agnostic) and localhost redirect forms; default-deny on missing scope claim |
| Claude Code registers a new DCR client on every fresh connection — unbounded client-table growth | [anthropics/claude-code#59460](https://github.com/anthropics/claude-code/issues/59460) | Open | Implemented (issue #272): `bin/prune-hydra-clients.sh` (dry-run by default) deletes clients idle >30 days with no consent sessions; `bin/doctor.sh` warns above `HYDRA_CLIENT_COUNT_WARN` (default 500) |
| claude.ai inconsistently sends the RFC 8707 `resource` parameter | Observed in the field; no single upstream issue | Ongoing | Never disable audience validation; consent-accept grants audience server-side |
| MCP scopes must be advertised in two places or a connection grants nothing | Not an upstream bug — Hydra's DCR grants only `openid`/`offline_access` by design, and a scope a client was never granted cannot be requested at authorization | Permanent; added 2026-08-21 (`4a763e5`) | `prmScopesSupported` in `mcpapp/prm.go` (RFC 9728 metadata) **and** `default_scope` in `hydra/hydra.yml`. **Load-bearing — do not remove either when pruning this register.** Without them a client completes discovery, DCR, CAS login and consent and then has every tool call refused with "the OAuth access token granted no yelukerest scopes", which reads to the student as a broken server. Advertising is not granting: write scopes still start unticked at consent |
| Self-hosted DCR connectors intermittently fail with claude.ai (zero inbound traffic or `McpAuthorizationError` after apparently-successful OAuth) | [anthropics/claude-ai-mcp#207](https://github.com/anthropics/claude-ai-mcp/issues/207), [#227](https://github.com/anthropics/claude-ai-mcp/issues/227), [#196](https://github.com/anthropics/claude-ai-mcp/issues/196) | Intermittent | Faculty/TA pilot on low-stakes accounts before student rollout (issue #276) |

### Spike findings — issue #271 (2026-08-05, Hydra v26.2.0, live dev stack)

**Verdict: GO on Hydra's audience mechanism** — with one mandatory,
non-obvious requirement: the OAuth client's `audience` allowlist (client
metadata, not a request parameter) **must contain the canonical MCP
resource, or refresh breaks**. All results below were produced
empirically against the running dev stack (DCR client, PKCE S256 code
flow, login/consent accepted via the admin API exactly as authapp will
in issue #273).

1. **RFC 8707 `resource` parameter: silently ignored.** Sent on both
   `/oauth2/auth` and `/oauth2/token`; never an error, echoed through
   the login/consent resume redirects, never reaches
   `requested_access_token_audience` (stays `[]`) or the token's `aud`.
   No adapter can make it bind; use Hydra's audience mechanism.
2. **Recipe for #273/#274 (works for clients that send nothing, i.e.
   claude.ai):** consent-accept with
   `grant_access_token_audience: ["https://<FQDN>/mcp"]` plus
   `session.access_token` claims yields a JWT with
   `aud=["https://<FQDN>/mcp"]` even when the client requested no
   audience. **But** Hydra re-validates the granted audience against the
   client's `audience` allowlist at **refresh** time: with the default
   empty allowlist, the initial exchange succeeds and every refresh
   fails (`invalid_request`, "Requested audience … has not been
   whitelisted by the OAuth 2.0 Client"). Fixes, both verified: (a) DCR
   accepts an `audience` field — the #272 register proxy can inject
   `"audience": ["https://<FQDN>/mcp"]` into registration requests; (b)
   an admin-API `PATCH /admin/clients/{id}` setting `audience`
   retroactively repairs already-issued refresh tokens with no
   re-registration or re-consent — authapp should ensure-patch the
   client at consent time as a belt-and-suspenders.
3. **Hydra's `audience` request parameter** works only for clients whose
   allowlist already contains the value (otherwise: `invalid_request`
   error redirect from `/oauth2/auth`). When present it populates the
   consent request's `requested_access_token_audience`, which authapp
   may display; it is not required for binding — the consent-accept
   grant alone suffices.
4. **Refresh preserves everything (no token_hook needed on v26.2.0):**
   `aud`, `scp`, and all consent-accept `session.access_token` claims
   survive `grant_type=refresh_token` unchanged; the refresh token
   rotates. The "claims lost on refresh, need token_hook" caveat does
   **not** reproduce on v26.2.0 — re-verify on every Hydra upgrade.
5. **Claims placement:** `allowed_top_level_claims` *duplicates* claims —
   they appear top-level (`role`, `user_id`, `netid`, `scopes`) *and*
   under `ext.*`. Scopes are `scp` as a JSON array
   (`["openid","offline_access"]`); there is no `scope` string claim.
   `sub` is the consent-accepted subject; `iss` is the bare root issuer.
6. **No-audience token shape (mcpapp rejection target):** a plain flow
   with no grant yields `"aud": []` — an *empty array present in the
   claims*, not an absent claim. mcpapp must reject `aud` that is
   missing, empty, or lacking the exact canonical resource.
7. **RFC 9207: NOT implemented.** No `iss` parameter on the
   authorization response, success or error
   (`?code=…&scope=…&state=…` only). Clients cannot rely on it; mix-up
   defense rests on the single-issuer deployment and exact
   redirect-URI matching.
8. **DCR response null/empty fields (verbatim, for #272 to strip):**
   null → `contacts`, `skip_logout_consent`, and all 13 lifespan fields
   (`authorization_code_grant_{access,id,refresh}_token_lifespan`,
   `client_credentials_grant_access_token_lifespan`,
   `implicit_grant_{access,id}_token_lifespan`,
   `jwt_bearer_grant_access_token_lifespan`,
   `refresh_token_grant_{id,access,refresh}_token_lifespan`,
   `device_authorization_grant_{id,access,refresh}_token_lifespan`);
   empty string → `owner`, `policy_uri`, `tos_uri`, `client_uri`,
   `logo_uri`; empty array → `audience`, `allowed_cors_origins`; empty
   object → `jwks`, `metadata`; and `client_secret_expires_at: 0`. The
   response also includes `registration_access_token` and
   `registration_client_uri` (keep those).
9. **Sanity:** access-token `expires_in` 3600 s and refresh-token
   lifetime exactly 720 h (admin introspection), matching `hydra.yml`.
   The public `/.well-known/jwks.json` publishes **both** the id-token
   and access-token signing keys — mcpapp must select by `kid` from the
   JWT header, never assume a single key; a key added to
   `hydra.jwt.access-token` via the admin API is published immediately
   alongside the old one (rotation-safe).

### Implementation notes — issue #273 (2026-08-05, live dev stack)

The spike recipe is implemented in `authapp/oauth.go`
(`/auth/oauth/login`, `/auth/oauth/consent`; see `docs/hydra.md` for the
handler contract) and was confirmed end to end against the running
stack: DCR registration, PKCE S256 authorization, CAS login through the
delegated handler, the consent form, code exchange, and refresh. The
issued access token carried `aud: ["https://localhost/mcp"]`,
`scp` as an array, and `netid`/`user_id`/`role`/`scopes` both top-level
and under `ext.*`; every one of those survived a refresh unchanged,
re-confirming finding 4. Two additions to the register:

- **The consent-time audience ensure-patch is not theoretical.** A
  client whose `audience` allowlist was emptied out of band had it
  repaired by the consent handler (`PATCH /admin/clients/{id}` with a
  JSON Patch `replace` on `/audience`) and then refreshed successfully.
  Without the patch that refresh is the failure described in finding 2.
- **Challenges are not short ids.** With `DSN=memory` Hydra encodes the
  entire authorization request into the challenge: a measured
  `login_challenge` was 1168 characters of base64url plus `==` padding,
  and it round-trips through the CAS `next` parameter double-encoded.
  Anything that validates, stores, or proxies a challenge must budget
  kilobytes, and a Postgres-backed Hydra will produce a different
  (shorter) shape — do not encode an assumption about either.
