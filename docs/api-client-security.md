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

For student scripts and notebooks:

- Obtain a fresh token from `/auth/jwt` after signing in.
- Store it in an environment variable for the current shell or process.
- Re-run the sign-in/token step when a request returns `401 Unauthorized`.
- Slow down token refresh loops when `/auth/jwt` returns `429 Too Many
  Requests`.
- Treat `403 Forbidden` as an authorization or row-level-security result, not
  an expired-token result.
- Do not check generated tokens into notebooks, repos, Canvas, Slack, or Piazza.

## MCP Bearer Tokens

Bearer-token MCP clients (Claude Code, Cursor, VS Code, scripts) need a
credential before OAuth lands. Sign in through `/auth/login`, then trade the
browser session for a token at `/auth/mcp-token`:

```sh
curl -sS -b cookies.txt "$YELUKEREST_BASE_URL/auth/mcp-token"
```

```json
{
  "token": "…",
  "token_type": "Bearer",
  "expires_in": 600,
  "scopes": ["course:read", "grades:read", "submissions:read"]
}
```

The endpoint is a `GET`: it has no request body, it mirrors `/auth/me` and
`/auth/jwt`, and while a cross-site page can trigger the request, no CORS
headers are emitted so it cannot read the response.

Scopes are requested with the optional `scopes` query parameter, separated by
spaces or commas:

```sh
curl -sS -b cookies.txt \
  "$YELUKEREST_BASE_URL/auth/mcp-token?scopes=course:read,submissions:write"
```

- Omitting `scopes` grants the read-only default set: `course:read`,
  `grades:read`, `submissions:read`.
- Write scopes are never implicit. `submissions:write` is granted only when it
  is named.
- Unknown or malformed scopes get `400 Bad Request` before the database is
  touched. The full allowlist is `course:read`, `grades:read`,
  `submissions:read`, and `submissions:write`.

These tokens live **ten minutes**, the same as every other internal JWT. Treat
re-minting as routine rather than exceptional: on `401 Unauthorized`, request a
fresh token and retry once. A wrapper that re-mints from a stored session
cookie is the intended ergonomic fix; do not try to cache the token past its
`expires_in`. The endpoint applies its own per-client throttle, tighter than
`/auth/jwt`, so back off when it returns `429 Too Many Requests`. `503 Service
Unavailable` means the deployment has no `MCPAPP_JWT` configured.

Every mint writes an append-only audit row (`data.mcp_jwt_mint_event`) naming
the caller, the subject, and the granted scopes. Faculty can read the history at
`/rest/mcp_jwt_mint_events` and the burst alarm at `/rest/mcp_jwt_mint_anomalies`.

### Known Gap: Token Audience

The database function behind this endpoint (`api.issue_user_jwt_for_mcp` via
`auth.sign_mcp_user_jwt`) signs tokens with `aud` set to the PostgREST audience,
`yelukerest-postgrest`. Mcpapp currently accepts only `yelukerest-mcp`. Authapp
holds no signing secret and cannot widen the audience itself, so tokens from
`/auth/mcp-token` currently authenticate against `/rest/*` and are **refused at
`/mcp`**. Closing this needs one of two changes outside authapp: teach mcpapp to
accept the PostgREST audience, or have `auth.sign_mcp_user_jwt` emit an audience
array containing both names. Both `api.check_request_jwt` and mcpapp's verifier
already accept array audiences, so the array is the cleaner fix.

## Service Tokens

`AUTHAPP_JWT` must be an app token:

```sh
./bin/jwt.sh '{"role":"app","app_name":"authapp"}'
```

Authapp now validates that token shape at startup. If it is missing issuer,
audience, subject, expiration, issued-at, not-before, role, or app name claims,
authapp exits rather than accepting CAS callbacks that cannot mint user tokens.

`MCPAPP_JWT` is a second, independent app token that authapp presents when
minting MCP bearer tokens. `api.issue_user_jwt_for_mcp` admits only
`app_name=mcpapp`, so the credential must say so:

```sh
./bin/jwt.sh '{"role":"app","app_name":"mcpapp"}'
```

It is validated at startup with the same checks as `AUTHAPP_JWT`. It is
optional: when unset, authapp logs a warning at startup and `/auth/mcp-token`
returns `503`, so deployments that predate the MCP work keep running. When it is
set but malformed, authapp exits. Keeping the two credentials separate is the
point — either can be revoked without disturbing the other.

## Deliberate Limitations

Yelukerest does not currently maintain a token denylist. That is acceptable for
short-lived course deployments and one-hour user JWTs, but it means a leaked
token remains usable until `exp`. If we later need immediate token revocation,
key it by signed `jti` plus `iss`, not by raw token bytes.
