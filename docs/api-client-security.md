# API Client Security

Yelukerest accepts direct student and staff API calls through PostgREST. Treat
the JWT returned by `/auth/jwt` as a bearer credential: whoever has it can make
API calls as that user until it expires.

## Token Flow

1. Sign in through `/auth/login`.
2. Call `/auth/me` to get non-secret profile data for the current session.
3. Call `/auth/jwt` only when a client needs to call `/rest/*` directly.
4. Send the token as an HTTP `Authorization` header:

   ```sh
   curl -H "Authorization: Bearer $YELUKEREST_CLIENT_JWT" \
     "$YELUKEREST_BASE_URL/rest/users"
   ```

Do not put JWTs in URLs, query parameters, local shell history, issue comments,
logs, screenshots, or long-lived dotfiles. For local scripts, prefer an
environment variable set in the current shell.

Responses under `/auth/*`, including `/auth/jwt`, are sent with
`Cache-Control: no-store`, `Pragma: no-cache`, and `Expires: 0`. The JWT
endpoint also applies a small per-client issuance throttle so accidental loops
or scripted retries do not mint unbounded credentials.

## Required Claims

PostgREST verifies the JWT signature and standard validity claims. The
`api.check_request_jwt` pre-request hook also rejects authenticated tokens unless
these claims match the deployed course:

- `iss`: `yelukerest` unless `JWT_ISSUER` is intentionally overridden.
- `aud`: `yelukerest-postgrest` unless `JWT_AUDIENCE` is intentionally
  overridden.
- `sub`: `user:<user_id>` for user tokens or `app:authapp` for the authapp
  service token.
- `role`: one of the database roles used by the API, such as `student`,
  `ta`, `faculty`, or `app`.
- `exp`, `iat`, `nbf`, and `jti`: standard lifecycle and token-id claims.

User JWTs expire within one hour. Clients should be prepared to re-authenticate
or request a fresh token after `401 Unauthorized`.

Use `./bin/jwt.sh` for hand-minted service/admin tokens so those claims are
present. Use `bun run doctor` before starting a local stack or deploying a
course instance to catch stale service tokens.

## Browser Clients

The Elm app should keep using the server-side session for ordinary page loads
and should request `/auth/jwt` only when it needs to call `/rest/*`. If browser
code holds a JWT, keep it in memory or session-scoped storage and rely on the
existing Content Security Policy to reduce XSS exfiltration risk. Avoid
long-lived localStorage tokens. OWASP's
[JWT cheat sheet](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html)
makes the same tradeoff explicit: bearer tokens sent in an `Authorization`
header are normal, but browser storage choices must account for XSS and
persistence risk.

Yelukerest does not emit permissive CORS headers by default. Browser API clients
should be served from the same origin as the course site. CLI and notebook
clients are not affected by browser CORS and can send the `Authorization` header
directly.

## CLI And Notebook Clients

Use a **personal access token**. Full instructions, with runnable examples, are
in [personal access tokens](personal-access-tokens.md).

In short: create one on the site, put it in an environment variable, exchange it
for a short-lived JWT at `POST /auth/token`, and re-exchange when a request
returns `401`. The token itself lasts four months and can be revoked at any time
from the same page that created it.

The older advice here was to fetch a token from `/auth/jwt` after signing in and
repeat that every hour. That still works for a browser session, but it is a poor
fit for a script: there is no refresh, so a program that runs longer than an hour
-- or an assistant writing code alongside a student -- cannot recover from an
expiry without a human returning to a browser.

For faculty admin commands (`pythonclient/api_client.py`), see
[ADR 0002](adr/0002-admin-api-authentication.md). In short: for attended runs,
export a fresh ~1h faculty token as `YELUKEREST_CLIENT_JWT` for the current
shell, and never persist it in a synced `.env`. A standing faculty bearer token
is rejected -- it cannot be revoked without rotating `JWT_SECRET` and
invalidating every student session. Unattended runs need the minting path
described there, which does not exist yet.

Prefer the environment variable over the `--jwt` flag. A token passed as a
command-line argument lands in shell history and is visible in the process list
to every other process on the machine, which is exactly what this document warns
against above. `--jwt` remains for tests and for callers that construct the
argument list programmatically.

## MCP Clients

The MCP endpoint is `<site>/mcp`. OAuth is the only way to reach it. A verified
OAuth access token is exchanged, inside mcpapp, for a short-lived internal JWT
carrying the caller's identity and a `scopes` claim, and that is what goes to
PostgREST — so row-level security remains the only authorization authority.

| | OAuth |
| --- | --- |
| How the client gets it | DCR + authorization code + PKCE via Hydra |
| Discovery | `/.well-known/oauth-protected-resource/mcp` |
| User interaction | CAS login, then the consent page |
| Lifetime | 1 hour access, 30 day refresh, the refresh window sliding on each use |
| Audience | the canonical resource URL, `https://$FQDN/mcp` |
| Scopes | consent-page checkboxes, writes unchecked |

Students should be pointed at `docs/mcp-for-students.md`, which covers this in
non-developer language, and at `docs/personal-access-tokens.md` for scripts. The
architecture and threat model are in `docs/adr/0001-mcp-and-oauth.md`; operating
the OAuth server is `docs/hydra.md`.

Until 2026-08-22 a second, session-gated path minted 10-minute bearer tokens for
clients that could not do OAuth. It was retired having never issued a token in
production; ADR 0001 records the retirement. Clients that cannot run the OAuth
flow themselves now use
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote), and code a student
writes uses a personal access token against `/rest` instead.

### OAuth Access Tokens

An OAuth-capable client needs no token from us. Pointed at `<site>/mcp`, it
reads `/.well-known/oauth-protected-resource/mcp`, finds Hydra, registers itself
through Dynamic Client Registration, and runs authorization code + PKCE. The
student authenticates with CAS through authapp's delegated login handler and
approves scopes on `/auth/oauth/consent`; read scopes are pre-checked and write
scopes are not.

Hydra's access tokens are validated by mcpapp only (JWKS, issuer, expiry, and an
`aud` that must contain the canonical resource URL exactly) and **never reach
PostgREST**. mcpapp exchanges the verified identity for an internal user JWT via
`api.issue_user_jwt_for_mcp`, an audited, 10-minute, scope-bearing token. Access
tokens live one hour and refresh tokens 30 days, and the refresh window slides on
each use, so a client used at least monthly never re-authenticates during a term.
A `401` on this path means re-authorize.

Every exchange writes an append-only audit row (`data.mcp_jwt_mint_event`) naming
the caller, the subject, the granted scopes, and the external OAuth client.
Faculty can read the history at `/rest/mcp_jwt_mint_events` and the burst alarm at
`/rest/mcp_jwt_mint_anomalies`.

An OAuth token whose granted scopes map to nothing this server exposes gets no
MCP access at all, reads included; consent that yields only `openid` or
`offline_access` authorizes nothing here. Reads require one of `course:read`,
`grades:read`, or `submissions:read` (or the coarse `read`); writes require
`submissions:write` (or the coarse `write`), and that scope is the whole gate —
see `docs/mcp-writes.md` for why the server carries no confirmation flow of its
own. Row-level security applies underneath it, so a write can only touch rows
the student could already reach. See `docs/hydra.md` for the operator side.

## Service Tokens

`AUTHAPP_JWT` must be an app token:

```sh
./bin/jwt.sh '{"role":"app","app_name":"authapp"}'
```

Authapp now validates that token shape at startup. If it is missing issuer,
audience, subject, expiration, issued-at, not-before, role, or app name claims,
authapp exits rather than accepting CAS callbacks that cannot mint user tokens.

`MCPAPP_JWT` is a second, independent app token, held only by mcpapp and
presented when it exchanges a verified OAuth token for an internal course
credential. `api.issue_user_jwt_for_mcp` admits only `app_name=mcpapp`, so the
credential must say so:

```sh
./bin/jwt.sh '{"role":"app","app_name":"mcpapp"}'
```

Unlike `AUTHAPP_JWT`, this credential is not checked at startup; mcpapp only
notices whether it is set at all. A malformed, expired, or wrongly-named token is
first discovered when PostgREST rejects the exchange, which happens on a caller's
first tool call — so after minting or rotating it, make one tool call and confirm
it succeeds. When it is unset, mcpapp logs a warning at startup, OAuth tokens
still verify, and every OAuth caller's first tool call fails, so a deployment
that does not serve MCP need not mint one.

Keeping the two credentials separate is the point — either can be revoked without
disturbing the other, and a compromise of the public `/mcp` surface never yields
authapp's unrestricted minting credential.

## Deliberate Limitations

Yelukerest does not maintain a JWT denylist. A leaked **JWT** remains usable
until `exp`, which is acceptable because those live an hour. If we ever need to
revoke an individual JWT, key it by signed `jti` plus `iss`, not by raw token
bytes.

This does not apply to **personal access tokens**. Those are server-side rows,
not self-proving credentials, so revoking one takes effect on the next exchange
attempt. The exposure after revoking a leaked token is bounded by whatever JWT
it had already been exchanged for -- at most an hour -- rather than by the
token's own four-month expiry. That is the whole reason the exchange step exists
instead of teaching PostgREST to accept the token directly.
