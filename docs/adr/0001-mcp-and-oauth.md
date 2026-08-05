# ADR 0001: MCP Server And OAuth Architecture

## Status

Accepted, 2026-08-05. The architecture and its alternatives were researched and
adversarially reviewed (multi-model) on 2026-08-05. Implementation is tracked in
the "Roadmap 6: MCP and OAuth" milestone (issues #261–#278).

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

Protocol eras: mcpapp serves the 2025-11-25 protocol era by default. The
2026-07-28 stateless era sits behind an env feature flag because go-sdk support
for it (`StreamableHTTPOptions.Stateless`) is pre-release and observed
Claude/ChatGPT traffic is still legacy-era. The flag flips to default only when
both conditions clear (issue #278).

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
`api.issue_user_jwt_for_mcp(netid, scopes)`:

- Admits only a distinct `app_name=mcpapp` service credential — never
  authapp's — so either credential can be revoked independently.
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
- **mcpapp minting-credential blast radius.** mcpapp is a public endpoint
  holding a credential that mints user JWTs. If it reused authapp's
  unrestricted credential, compromise would mean minting faculty tokens.
  Mitigations: a distinct `app_name=mcpapp` credential, independently
  revocable; minting restricted to student/ta subjects initially (faculty
  access is an explicit opt-in decision, issue #263); ~10-minute token TTL;
  every mint audited, with an alert query for one credential minting unusually
  many distinct subjects in a short window.
- **Grade-data exfiltration channels.** Once grades flow through an agent,
  they can leak via model context sent to third-party providers, via tool
  results echoed into other tools, or via the escape hatch. Mitigations:
  grades appear only in a dedicated grades tool (never in broad "course
  context" responses), output size caps with explicit truncation markers, no
  auto-fetching of URLs found in database text, structured audit logs with
  grade/submission-body redaction, and the consent screen naming grades as a
  shared data category.

## Policy Note (FERPA / Institutional)

Sending grade data to third-party AI providers is a policy boundary, not just
a technical one. The consent screen must name the data categories being shared
(assignments, submissions, grades) and the third party receiving them.
Institutional/FERPA requirements must be confirmed before write scopes are
enabled for students in production (tracked in issue #276). Until then, writes
stay behind the pilot.

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
- Constrained to `/rest/*`, caller's own internal JWT, response size caps,
  every call audit-logged.

The dissent is recorded on issue #268; revisit before Phase 1 student rollout.

## Consequences

- One new Go service (mcpapp) in Phase 0; one new container (Hydra) plus a
  Postgres database for it in Phase 1. Compose, Caddy, doctor, and runbook
  work scale accordingly.
- The DB gains a second service role and an audited minting function; the
  existing authapp path is untouched.
- Scope enforcement is default-deny: a token whose scope claim is missing or
  empty is read-only at most (this also defuses the Claude Code scope-omission
  bug below).
- Client bugs become our operational surface: the caveats register below must
  be re-checked each semester, and a DCR response-cleaning proxy plus a
  client-pruning job exist solely to work around upstream defects (issue
  #272) — both are deletable once upstream fixes ship.

## Caveats Register

Re-check every entry at the start of each semester and before flipping any
feature flag. Append pilot and spike findings here (issues #271, #276).

| Caveat | Upstream | Status 2026-08-05 | Our workaround |
| --- | --- | --- | --- |
| Hydra DCR responses include null/empty optional fields that break strict-parser MCP clients (mcp-remote, Cursor, TS-SDK-based); confirmed in a comparable Hydra+MCP deployment (getlarge.eu) | [ory/hydra#4044](https://github.com/ory/hydra/issues/4044), fix [PR #4050](https://github.com/ory/hydra/pull/4050) | Open; PR unmerged, no nightly images | Response-cleaning proxy on `/oauth2/register` implemented in authapp (`authapp/register.go`, issue #272; also injects the audience allowlist from the #271 spike); remove the cleaning when fixed upstream |
| Hydra lacks Client ID Metadata Documents (CIMD); may matter as DCR sunsets | [ory/hydra#4061](https://github.com/ory/hydra/issues/4061) | Open | None needed yet; re-check at Phase 2 |
| Hydra does not implement RFC 8707 `resource`; it has its own `audience` mechanism | Hydra docs / #4061 discussion | No RFC 8707 support | Spike (issue #271) proves audience binding end-to-end or adds an adapter; mcpapp rejects missing/empty `aud` — audience validation is never disabled |
| go-sdk 2026-07-28 stateless-era support is pre-release | [modelcontextprotocol/go-sdk](https://github.com/modelcontextprotocol/go-sdk) | Pre-release | Pin stable release; 2026 era behind env flag |
| Claude Code: localhost-loopback redirect handling and scope omission on connect | [anthropics/claude-code#42765](https://github.com/anthropics/claude-code/issues/42765) | Open | Register both 127.0.0.1 (port-agnostic) and localhost redirect forms; default-deny on missing scope claim |
| Claude Code registers a new DCR client on every fresh connection — unbounded client-table growth | [anthropics/claude-code#59460](https://github.com/anthropics/claude-code/issues/59460) | Open | Implemented (issue #272): `bin/prune-hydra-clients.sh` (dry-run by default) deletes clients idle >30 days with no consent sessions; `bin/doctor.sh` warns above `HYDRA_CLIENT_COUNT_WARN` (default 500) |
| claude.ai inconsistently sends the RFC 8707 `resource` parameter | Observed in the field; no single upstream issue | Ongoing | Never disable audience validation; consent-accept grants audience server-side |
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
