# Auth And JWT Flow

## Why

Yelukerest uses two different authentication mechanisms on purpose:

- a server-side `authapp` session cookie for browser login state
- short-lived database-signed JWTs for PostgREST authorization

This keeps web sessions stateful and server-controlled, while letting PostgREST
authenticate each API request and let PostgreSQL grants/RLS authorize the work.

## Research Checked

Checked on 2026-07-06:

- PostgREST 14 authentication docs: PostgREST authenticates requests, switches
  into the JWT `role`, and leaves authorization to PostgreSQL grants and RLS.
  https://docs.postgrest.org/en/v14/references/auth.html
- PostgREST 14 configuration docs: JWT role extraction is configurable with
  `jwt-role-claim-key`; this app uses the default top-level `role` claim.
  https://docs.postgrest.org/en/v14/references/configuration.html#jwt-role-claim-key
- PostgREST upstream issue search: active JWT topics include generic
  authenticated roles, JWT verification without role switching, JWT error
  messages, and `jwt-role-claim-key` JSONPath details. Nothing found changes
  this app's current default `role` claim model.
- Go `net/http` cookie docs and SCS docs: cookie attributes include `Secure`,
  `HttpOnly`, and `SameSite`; SCS defaults to `HttpOnly` and `SameSite=Lax`,
  while `Secure` must be enabled explicitly for production.
  https://pkg.go.dev/net/http#Cookie
  https://pkg.go.dev/github.com/alexedwards/scs/v2#SessionCookie
- Local issue history: #87 asks whether JWTs are used correctly; #215 is stale
  because the standalone Go `authapp` already exists.

## Request Flow

1. Browser loads the Elm app.
2. Elm calls `/auth/me`.
3. Without an `authapp` session, `/auth/me` returns `401 Unauthorized`; Elm
   shows the login state.
4. Login goes to `/auth/login`, proxied by Caddy to `authapp`.
5. `authapp` redirects to CAS with the service URL set to `/auth/validate`.
   A `next` query parameter is preserved when present.
6. CAS redirects back to `/auth/validate?ticket=...`.
7. `authapp` validates the ticket with `CAS_VALIDATION_URI` and extracts the
   CAS user netid.
8. `authapp` calls PostgREST:
   `GET /user_jwts?netid=eq.<netid>` with `Authorization: Bearer $AUTHAPP_JWT`.
9. PostgreSQL grants/RLS allow this only when the JWT has `role = app` and
   `app_name = authapp`.
10. `api.user_jwts` returns user data and a freshly signed user JWT when the
    netid belongs to a known Yelukerest user.
11. `authapp` renews the server-side session token, stores the netid in the
    session, and redirects to `next` or `/`.
12. Elm calls `/auth/me` again and receives the current user plus a fresh
    PostgREST JWT.
13. Elm keeps that JWT in memory and sends it as
    `Authorization: Bearer <jwt>` to `/rest/*`.
14. PostgREST verifies the JWT signature and expiry, switches to the JWT
    `role`, sets request JWT claims, and PostgreSQL authorizes the request.

Development uses the mock CAS routes in `authapp` when `DEVELOPMENT` is set:
`/cas/login` creates a mock ticket for the requested `id`, and
`/cas/serviceValidate` returns CAS-like XML. Production uses the configured
Yale CAS URLs.

## Token And Session Boundaries

`authapp` session cookie:

- Holds only the SCS session token in the browser.
- Server-side session data stores the user's netid.
- Lifetime is 24 hours in `authapp`.
- `authapp` explicitly sets `HttpOnly` and `SameSite=Lax`.
- Production sets `Secure=true`; development leaves `Secure=false` so direct
  local HTTP authapp testing remains possible.

`AUTHAPP_JWT`:

- Long-lived service token configured in `.env`.
- Expected payload is `{"role":"app","app_name":"authapp"}`.
- Used only by `authapp` to ask PostgREST for rows from `api.user_jwts`.
- Must not be exposed to browsers or committed.

User PostgREST JWT:

- Signed in PostgreSQL by `auth.sign_jwt`.
- Contains `user_id`, `role`, and `exp`.
- Default lifetime is one hour from `settings.jwt_lifetime`.
- Returned by `/auth/me` and `/auth/jwt` only for valid sessions.
- Used by Elm and API clients to call `/rest/*`.

`YELUKEREST_CLIENT_JWT`:

- Used by `pythonclient`.
- Should be a user JWT with the role needed for the client operation, usually
  faculty for admin scripts.

Swagger:

- The Swagger UI now fetches `/auth/jwt` from the current browser session.
- It should not need a static `SWAGGER_JWT`.

## Role Matrix

| Role | How it is obtained | JWT claims | `api.user_jwts` behavior | Notes |
| --- | --- | --- | --- | --- |
| `anonymous` | No JWT or no role claim | none | no access | PostgREST anonymous role. Public read access is controlled only by grants/RLS. |
| `student` | CAS login for a student user | `user_id`, `role=student`, `exp` | sees own row and own JWT | Normal student browser role. |
| `ta` | CAS login for a TA user | `user_id`, `role=ta`, `exp` | sees user rows but JWT is non-null only for self | Broader read access than students, not equivalent to faculty. |
| `faculty` | CAS login for a faculty user | `user_id`, `role=faculty`, `exp` | sees all user JWTs | Broadest human role and the normal admin token role. |
| `observer` | CAS login for an observer user | none minted | JWT is intentionally null | Current sample data includes this role, but observers have no supported API surface yet. |
| `app` | Service token | `role=app`, optional `app_name` | no user JWTs unless `app_name=authapp` | Not a `data.user_role`; used for app-to-app access. |
| `app/authapp` | `AUTHAPP_JWT` | `role=app`, `app_name=authapp` | can fetch all user rows/JWTs | Service boundary between CAS sessions and user JWT minting. |
| `authenticator` | PostgREST DB connection role | none | not a request identity | Can switch into application roles granted to it. |

## Failure Modes

| Failure | Current behavior | Coverage |
| --- | --- | --- |
| No session for `/auth/me` or `/auth/jwt` | `401 Unauthorized` | REST auth tests |
| `/auth/login` requested | `302`/`307` redirect to CAS | REST auth tests |
| Valid CAS netid in `data.user` | session created; `/auth/me` and `/auth/jwt` return user JWT | REST auth tests |
| CAS-valid netid not in `data.user` | no session; JWT request returns no token | REST auth tests |
| Missing `ticket` on `/auth/validate` | `400 Bad Request` | not yet covered |
| CAS validation failure | `401 Unauthorized` | not yet covered directly |
| CAS back-channel or PostgREST error | authapp returns an error status, often collapsed to `403`/`500` | follow-up issue needed |
| Expired or invalid PostgREST user JWT | PostgREST rejects `/rest/*` request | covered indirectly by PostgREST; app UX follow-up needed |
| Observer login | no session/JWT is created because `api.user_jwts` does not mint observer JWTs | REST auth and pgTAP tests |

## Known Follow-Ups

Future cleanup:

- Remove or quarantine stale `db/src/libs/auth/api/*` starter-kit files if they
  are no longer imported.
