# ADR 0002: Authentication For Admin API Commands

## Status

Accepted, 2026-08-16. Decided in issue #298, under the "Roadmap 9: Admin API
Surface" milestone. Phase 1 is in force today; phase 2 is required before any
unattended run and is not yet implemented.

## Context

`pythonclient/api_client.py` is replacing direct `psql` access for course
administration (issues #299–#304). Every command it runs needs faculty
authority against PostgREST.

Today it reads `YELUKEREST_CLIENT_JWT` (or `--jwt`). But ordinary user JWTs
expire in about an hour (`docs/api-client-security.md`). That leaves three
options, and the failure mode is that nobody chooses deliberately — someone
picks the easy one at 11pm during grading:

1. **Paste a fresh JWT before every command.** Works today. Nobody will keep
   doing it under deadline pressure.
2. **Put a long-lived faculty bearer token in `.env`.** A standing credential
   with full faculty CRUD, in a dotfile on a laptop. In the MGT656 case `.env`
   is a symlink into an **iCloud-synced** secrets directory, so this is a
   standing faculty credential replicated to Apple's servers and to every
   device on the account.
3. **Give up and go back to `psql`**, which defeats the entire milestone.

Yelukerest is database-centric: PostgreSQL grants and RLS are the sole
authorization authority (`docs/auth-jwt-flow.md`). Any answer must preserve
that — no second authorization system, and no new long-lived credential that
sidesteps it.

There is a precedent in this codebase. ADR 0001 faced the same shape of problem
for MCP and solved it with `api.issue_user_jwt_for_mcp`
(`db/src/api/yeluke/mcp_jwt.sql`): a **service credential** exchanges a verified
identity for a **short-lived internal user JWT**, every mint is recorded in an
append-only audit table (`data.mcp_jwt_mint_event`), and the path is deliberately
separate from `api.issue_user_jwt` (authapp's credential) "so either service
credential can be revoked independently." There is even a mint-rate anomaly view
for detecting a compromised minting credential.

## Decision

### Rejected outright: a standing faculty bearer token in `.env`

Option 2 is rejected as the steady state. The objection is not that it is a
long-lived secret — phase 2 has one of those too. The objections are specific:

- **It cannot be revoked without collateral damage.** A faculty JWT is verified
  by `JWT_SECRET`. Revoking one means rotating that secret, which invalidates
  every student session simultaneously. So in practice it would never be
  revoked.
- **It is unauditable.** A leaked faculty JWT is indistinguishable from the
  legitimate holder. There is no record of use, so there is nothing to review
  after a suspected exposure.
- **It has full faculty CRUD**, including grade mutation, for its whole life.
- **In MGT656 it would be synced to iCloud**, so its blast radius includes
  Apple's storage and every device on the account.

### Phase 1 (in force now): short-lived, hand-pasted, never persisted

For attended use — a human at a terminal running an import — keep
`YELUKEREST_CLIENT_JWT` / `--jwt` with an ordinary ~1h faculty user JWT.

This is not a placeholder that will quietly become permanent, because it is
*incapable* of becoming the unattended answer: the token expires in an hour, so
it cannot be baked into a cron job. The pain is load-bearing.

Rules:

- The token **must not** be written into a synced `.env`. Export it into the
  shell for the session, or pass `--jwt`.
- Every admin command must fail with a clear, actionable message when it is
  missing or expired, rather than silently degrading to anonymous. This is
  implemented as of #297: reads without a token raise before touching the
  network, and auth is a mode (`AUTH_REQUIRED` / `AUTH_NONE`) rather than a
  boolean.
- `platform-version` deliberately sends **no** credential, so the preflight
  still answers when the token is the thing that is broken.

Phase 1 gates nothing in Roadmap 9. The import RPCs (#299–#303) are all
attended operations.

### Phase 2 (required before anything runs unattended): a minting service credential

When a command must run without a human — scheduled grade sync, CI, a nightly
roster import — do **not** reach for a standing faculty token. Follow the
ADR 0001 pattern:

- A dedicated service credential in the `app` role, distinct from `authapp` and
  from `mcpapp`. Working name `adminapp`.
- `api.issue_admin_jwt(requested_netid text)`, gated the way
  `api.issue_user_jwt` is gated — `request.user_role() = 'app' AND
  request.app_name() = 'adminapp'` — returning a short-lived faculty JWT.
- Every mint recorded in an append-only audit table mirroring
  `data.mcp_jwt_mint_event`, with the same faculty-only RLS and an equivalent
  mint-rate anomaly view.
- The client holds only the service credential and exchanges it for a
  short-lived token **in memory, per invocation**. The faculty JWT is never
  written to disk.

#### Revocation needs database state, not just a new token

An earlier draft of this ADR claimed the service credential would be
"independently revocable." **That claim was wrong as stated**, and the correction
is the most important part of phase 2.

Service credentials are stateless HS256 JWTs, accepted on signature, expiry,
role, and `app_name`. `bin/jwt.sh` issues service tokens with a five-year default
lifetime. Minting a *replacement* `adminapp` token does not invalidate a stolen
one: both are validly signed by the same `JWT_SECRET`, both carry
`app_name = 'adminapp'`, and nothing distinguishes them. Without additional
state, the only revocation is rotating `JWT_SECRET` — the very collateral damage
this design exists to avoid.

So phase 2 must carry server-side state, which is the natural database-first
answer anyway:

- A table of service credentials keyed by `app_name`, carrying a **credential
  version** (or `jti`) and a `revoked_at`.
- Service tokens carry the matching version claim.
- `api.issue_admin_jwt` checks that table and refuses to mint for a revoked or
  superseded version.

Revocation then means one `UPDATE`, taking effect on the next mint attempt,
with `JWT_SECRET` untouched and student sessions unaffected. The bound on a
stolen credential's usefulness becomes the *minted* token's lifetime (~1h),
not the service token's (5 years).

This mechanism is missing from the existing `mcpapp` path too. Worth a separate
issue; out of scope here.

#### The audit trail must cover mutations, not only mints

A second correction. A compromised credential can mint **one** faculty JWT and
then perform arbitrarily many grade mutations with it for an hour. A mint-rate
anomaly view sees a single, entirely normal-looking mint. So mint auditing alone
does **not** detect bulk grade misuse.

Phase 2 therefore needs auditing tied to actual operations, not to token
issuance. `data.grade_event` already exists as grade history; the work is to
make imports populate `source`, `reason`, and `import_id` honestly (which is
part of #299) and to make those columns carry the acting credential. Mint
auditing remains useful — it answers "who could have acted" — but it is not the
detection control.

### Not chosen: a narrower-than-faculty admin role

Issue #298 raised a dedicated admin role scoped below `faculty`. Deferred, not
rejected. The admin operations in Roadmap 9 — grade import, extensions, user
secrets — are close to the full set of things `faculty` can do, so a narrower
role would today be `faculty` minus very little, at the cost of a fourth role
in every RLS policy in `db/src/authorization/`. Revisit if admin commands are
ever delegated to someone who should not have full faculty authority (a grader,
a TA-run script). The phase 2 audit trail is the higher-value control and
should land first.

## Consequences

- Roadmap 9 proceeds unblocked; #299–#303 need no authentication work.
- Anything unattended is blocked on phase 2. That is deliberate: an unattended
  job is exactly where a standing faculty token would otherwise get created.
- Course repos must not add `YELUKEREST_CLIENT_JWT` to a synced `.env`. Tracked
  in `yale-mgt-656-fall-2026/admin#6`.
- Phase 2 needs its own issue, sequenced before the first scheduled job. It is
  not currently in the Roadmap 9 milestone.
- `docs/api-client-security.md` should point here for the token question.

## Threat Model Summary

| Threat | Phase 1 | Phase 2 |
|---|---|---|
| Token leaks via shell history / process list / logs | Expires in ~1h. Use the env var, not `--jwt` | Minted token expires in ~1h; service credential never on a command line |
| Secret at rest on a synced laptop | None persisted | Service credential only, not a faculty JWT |
| Compromised credential used for bulk grade mutation | Undetectable | **Only if mutation auditing lands.** Mint auditing alone does not catch this — one mint buys an hour of unlimited mutation |
| Need to revoke without disrupting students | Not possible — token expires anyway | **Only with the credential-version table.** A replacement token alone does not invalidate a stolen one |
| Operator bypasses the client and uses `psql` | Possible | Possible — out of scope, this ADR does not remove `psql` |

The two bolded cells are the phase 2 work that is easy to skip and would leave
the design claiming protection it does not have.

The last row is worth stating plainly: none of this constrains a faculty member
with database superuser access. The goal is to make the *good* path convenient
and auditable, not to constrain the account holder.
