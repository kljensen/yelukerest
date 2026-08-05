# Connecting An AI Assistant To The Course Site (MCP)

The course site speaks [MCP](https://modelcontextprotocol.io), so you can let an
AI assistant — Claude Code, Claude Desktop, claude.ai, ChatGPT, or something you
write yourself — read your course data and, if you allow it, edit a submission
for you. You do not have to use this. Everything it does, you can also do on the
website.

The MCP endpoint is:

```
https://<course-site>/mcp
```

Replace `<course-site>` with the address you use for the class (on a local
development stack that is `https://localhost`).

## What it can and cannot do

Everything runs under **your own database permissions**. The MCP server holds no
special access: it makes the same API calls you would make from the website,
signed as you, and PostgreSQL row-level security decides what comes back. If you
cannot see a classmate's submission on the site, the assistant cannot see it
either.

It can list meetings, assignments, and quizzes; read assignment instructions;
read your own submissions, engagements, grades, and quiz grades; and — only with
your explicit approval, twice — change one of your assignment submissions. It
cannot see anyone else's grades, change grades, or hold access indefinitely.
Tokens are short-lived and every issuance is logged.

## Two ways to connect

1. **Sign-in (OAuth).** You point the app at `https://<course-site>/mcp`, it
   sends you to a browser, you log in with CAS, and you approve a permissions
   page. This is the nicer path and the one to prefer. Access lasts an hour and
   renews quietly for up to 30 days.
2. **Bearer token.** You sign in to the course site, fetch a token, and paste it
   into your client's configuration as an `Authorization` header. Tokens last
   about **ten minutes**, so this path needs a small refresh script. Use it when
   your client cannot do the sign-in flow.

## Connecting Claude Code

Add the server:

```sh
claude mcp add --transport http yelukerest https://<course-site>/mcp
```

Then, inside Claude Code, run `/mcp`, choose `yelukerest`, and authenticate. A
browser window opens, you log in with CAS, and you approve the permissions page
described below. That is it — Claude Code renews access on its own.

If sign-in does not work for you, use a bearer token instead. Claude Code expands
`${VAR}` references in `.mcp.json`, so keep the token in an environment variable
rather than in the file:

```json
{
  "mcpServers": {
    "yelukerest": {
      "type": "http",
      "url": "https://<course-site>/mcp",
      "headers": {
        "Authorization": "Bearer ${YELUKEREST_MCP_TOKEN}"
      }
    }
  }
}
```

Tokens expire after ten minutes, so re-mint before you start a session. Save this
as `~/bin/yelukerest-token` and run `eval "$(yelukerest-token)"`:

```sh
#!/bin/sh
# Prints an export line for a fresh token. cookies.txt holds your
# signed-in course-site session cookie.
set -eu
TOKEN=$(curl -sS -b ~/.config/yelukerest/cookies.txt \
  "https://<course-site>/auth/mcp-token?scopes=course:read+grades:read+submissions:read" \
  | jq -r .token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "no token; sign in again" >&2; exit 1; }
echo "export YELUKEREST_MCP_TOKEN=$TOKEN"
```

Add `+submissions:write` to the `scopes` list only when you actually intend to
edit a submission in that session.

## Connecting Claude Desktop, claude.ai, or ChatGPT

These apps do the sign-in flow for you. Add a custom connector (the wording
varies: "Add custom connector", "Add integration", "Developer mode connector")
and give it the URL `https://<course-site>/mcp`. Do not paste a token.

What you will see:

1. The app registers itself with the course site automatically.
2. A browser window opens on the Yale CAS login page. Log in as usual.
3. A plain **consent page** from the course site appears. It shows the
   application's registered redirect address and its client id first — the name
   an application reports for itself is self-reported and not verified, so trust
   the address, not the name. Below that is a list of permissions with
   checkboxes, and a list of the data categories that can leave the course app.
4. Read scopes (`course:read`, `grades:read`, `submissions:read`) are checked for
   you. Anything that changes your data (`submissions:write`) starts
   **unchecked** on purpose. Uncheck anything you would rather not share.
5. Press **Allow access**. If you did not start this connection yourself, press
   **Deny**.

Access tokens last an hour; the app refreshes them behind the scenes for up to 30
days, after which you sign in again.

**If your app cannot do OAuth**, either use the bearer-token path above or put
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) in front of the server —
it is a small bridge that handles the sign-in flow for clients that only speak
stdio.

## Connecting from a script or notebook

Sign in to the course site in your browser, then visit
`https://<course-site>/auth/mcp-token`. You get back JSON:

```json
{
  "token": "eyJhbGci...",
  "token_type": "Bearer",
  "expires_in": 600,
  "scopes": ["course:read", "grades:read", "submissions:read"]
}
```

Ask for particular permissions with the optional `scopes` parameter, separated by
spaces, plus signs, or commas:

```sh
curl -sS -b cookies.txt \
  "https://<course-site>/auth/mcp-token?scopes=course:read+submissions:read+submissions:write"
```

Then talk to the MCP endpoint directly. List the tools:

```sh
curl -sS https://<course-site>/mcp \
  -H "Authorization: Bearer $YELUKEREST_MCP_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Call one:

```sh
curl -sS https://<course-site>/mcp \
  -H "Authorization: Bearer $YELUKEREST_MCP_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"list_assignments","arguments":{}}}'
```

Keep tokens in an environment variable for the current shell. Do not commit them
to a repo or paste them into Canvas, Slack, or a notebook you share.

## What the tools do

| Tool | What it gives you |
| --- | --- |
| `whoami` | Who the server thinks you are: netid, role, nickname, team |
| `list_meetings` | Class meetings in order: title, summary, start time, type |
| `list_assignments` | Assignments you can see: slug, points, team or individual, open, deadline |
| `get_assignment` | One assignment in full: instructions, the fields a submission must fill, deadline |
| `get_my_submissions` | Your own (and your team's) submitted work, field by field |
| `list_quizzes` | Quizzes you can see: meeting, points, open and close times |
| `get_my_quiz_grades` | Your quiz grades, with the anonymized class distribution |
| `get_my_grades` | Your course grades, with the anonymized class distribution |
| `get_my_engagements` | Your participation record per meeting |
| `prepare_submission_change` | Step 1 of editing a submission — shows what would change, writes nothing |
| `commit_submission_change` | Step 2 — performs the change you confirmed |
| `get_api_schema` | The REST API views and filter syntax, for the escape hatch |
| `prepare_api_request` | Step 1 for a non-GET raw API call |
| `postgrest_request` | Escape hatch: one raw REST API call under your own permissions |

**Grades appear only in `get_my_grades` and `get_my_quiz_grades`.** No other tool
returns your scores, so an assistant that only reads assignments never sees them.

## How editing a submission works

Writing is deliberately awkward. It takes two calls plus a confirmation you see
with your own eyes:

1. The assistant calls `prepare_submission_change`. Nothing is written. It gets
   back a summary — the current value, the proposed value, whether this creates
   or overwrites, whether the assignment is still open — plus a single-use token
   that expires in five minutes.
2. The assistant shows you that summary and calls `commit_submission_change`.
   Your client pops up a confirmation box naming the assignment and field. Only
   after you say yes does anything get written.

**Clients that cannot show that confirmation box can read but cannot write.**
That is on purpose. Tool results contain text other people wrote — a teammate's
submission, an assignment description — and an assistant that reads such text can
be talked into doing something you never asked for, so the last word before your
official coursework changes has to be yours, in a prompt you actually see.

If the submission changed between the two steps, the commit is refused and you
start over with a fresh summary. Deadlines still apply: the database rejects a
write to a closed assignment regardless of what the assistant intends.

## Privacy and honesty

**Whatever the assistant reads goes to whoever runs the assistant.** If you
connect Claude, your assignments, submissions, and grades are sent to Anthropic;
if you connect ChatGPT, they go to OpenAI. That is a real disclosure of your own
academic record to a third party, and it is your choice to make. The consent page
lists exactly which categories can leave the course app. If you are not
comfortable with that, use the website — nothing here is required.

Approve only connections you started yourself, and only the permissions you need.
Leave `submissions:write` unchecked unless you are about to use it.

On academic integrity: this connection is plumbing, not permission. Whether you
may use an AI assistant to help produce work you submit is governed by the course
policy in the syllabus, not by what these tools happen to allow. If the policy and
a tool disagree, the policy wins. Ask if you are unsure.

## Troubleshooting

**`401 Unauthorized`** — your token expired. Bearer tokens live ten minutes;
re-mint one. OAuth clients should re-authorize (`/mcp` in Claude Code, or
disconnect and reconnect the connector). It is not a sign that anything is broken.

**`403 Forbidden`** — you asked for something your account is not allowed to see
or change. That is row-level security doing its job, not an expired token; a new
token will not help. Common causes: a draft assignment, someone else's row, or a
closed submission window.

**`429 Too Many Requests`** — you are going too fast. Wait a bit and retry. Loops
that re-mint tokens on every call trip this quickly; mint once and reuse the token
for its full lifetime.

**"This client cannot show you a write confirmation"** — your client does not
support the confirmation prompt, so writes are refused. Use a client that does, or
submit through the course website.

**"The token carries no scopes" / a permission is denied** — you were issued a
token without the scope that tool needs. Re-mint with the scope named
(`?scopes=...`), or re-authorize and check the box on the consent page. Write
access is never granted implicitly.

**`503 Service Unavailable` from `/auth/mcp-token`** — this deployment has not
turned on MCP token issuance. Tell the instructor.

**Nothing happens after you approve the consent page** — some connectors are
flaky with self-hosted servers. Remove the connector and add it again; if it
still fails, report it with the time it happened.

## See also

- `docs/api-client-security.md` — token handling rules for direct API clients.
- `docs/adr/0001-mcp-and-oauth.md` — why the system is built this way.
- `docs/hydra.md` — operator runbook for the OAuth server.
