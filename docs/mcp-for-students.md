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
read your own submissions, engagements, grades, and quiz grades; and — only if
you tick the **submissions:write** box on the approval page — change one of your
assignment submissions. That box is unticked by default, and leaving it unticked
is what makes the connection read-only.

Ticking it is the whole decision. Nothing asks you again at the moment a write
happens: some assistants show their own confirmation, but that is a feature of
the app, not a protection the course site enforces. If you would rather approve
each change yourself, connect without the write box and paste work in by hand.

It cannot see anyone else's grades, change grades, or hold access indefinitely.
Tokens are short-lived and every issuance is logged.

## There are two steps

1. **Sign in.** Open the course site in a browser and log in with CAS, the way
   you always do. That is the only place you type a password.
2. **Connect your assistant.** Point it at `https://<course-site>/mcp`, and when
   a permissions page appears, read it and approve it.

There is no token to copy, and nothing to paste into a configuration file. If
some other set of instructions tells you to fetch a token for `/mcp`, it is out
of date.

After you approve, your assistant holds access for an hour at a time and quietly
renews it. The renewal is good for 30 days, and **each use pushes that 30 days
out again** — so if you use the assistant at least once a month, you will not
have to sign in again for the rest of the term.

## Connecting Claude Code

Add the server:

```sh
claude mcp add --transport http yelukerest https://<course-site>/mcp
```

Then, inside Claude Code, run `/mcp`, choose `yelukerest`, and authenticate. A
browser window opens, you log in with CAS, and you approve the permissions page
described below. That is it — Claude Code renews access on its own.

## Connecting Claude Desktop, claude.ai, or ChatGPT

Add a custom connector (the wording varies: "Add custom connector", "Add
integration", "Developer mode connector") and give it the URL
`https://<course-site>/mcp`.

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

## If your app cannot do the sign-in flow

Some MCP clients only speak stdio — they launch a local program and talk to it
over a pipe — and cannot open a browser or hold a session. Put
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) in front of the course
site. It is a small bridge: the client launches `mcp-remote`, `mcp-remote` does
the browser sign-in and talks to `/mcp` on the client's behalf.

```json
{
  "mcpServers": {
    "yelukerest": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://<course-site>/mcp"]
    }
  }
}
```

The first run opens a browser for CAS login and the consent page, exactly as
above; after that it renews on its own.

`/mcp` accepts the sign-in flow and nothing else. A client that can neither do it
nor run `mcp-remote` cannot use MCP here — write against the REST API instead,
as below.

## Connecting from a script or notebook

MCP is built for assistants, not for your own code. When *you* are the one
writing Python, JavaScript, or `curl`, use a **personal access token** against
the REST API instead. Full instructions, with runnable examples, are in
[personal access tokens](personal-access-tokens.md).

The short version: create a token under **Settings → API tokens** on the course
site, copy it once, and keep it in an environment variable. It lasts four months
— longer than the semester — and you can revoke it from the same page the moment
you suspect it has leaked. Your program trades the token for a one-hour access
token at `POST /auth/token` and calls `/rest/…` with that:

```sh
ACCESS_TOKEN=$(curl -s -X POST https://<course-site>/auth/token \
  -H "Authorization: Bearer $YELUKEREST_TOKEN" | jq -r .jwt)

curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://<course-site>/rest/meetings?order=begins_at" | jq .
```

The same scopes apply: a token is read-only unless you tick `submissions:write`
when you create it. Leave it unticked unless you are deliberately writing code
that submits work.

Do not paste a token into your code, commit it to git, or post it in Slack,
Canvas, or a notebook you share. If you commit one by accident, revoke it —
deleting the commit is not enough, because the token stays in the repository
history.

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
| `preview_submission_change` | Shows exactly what an edit would change, and writes nothing |
| `submit_submission_change` | Writes one field of your submission |
| `get_api_schema` | The REST API views and filter syntax, for the escape hatch |
| `postgrest_request` | Escape hatch: one raw REST API request under your own permissions |

**Grades appear only in `get_my_grades` and `get_my_quiz_grades`.** No other tool
returns your scores, so an assistant that only reads assignments never sees them.

**`submit_submission_change` is the tool that changes your work**, one field of
one submission at a time. The escape hatch is a read tool unless this
deployment has enabled its writes. Either way the database limits how much any
one request of yours can change — a sweeping write is rejected and undone, and
nothing is written — and an assistant is steered back to
`submit_submission_change` for editing a submission. That limit applies to
anything acting with your credential, including a script you wrote yourself.

## How editing a submission works

An assistant can change your submitted work only if you gave it permission to.
When you connect it, the consent screen lists what it is asking for; granting
the write permission is what lets it call `submit_submission_change`. An
assistant you connected read-only can look at everything you can see and change
nothing, no matter what it is asked to do.

Beyond that, an edit is an ordinary write. A good assistant will call
`preview_submission_change` first and show you the current value, the proposed
value, and whether the assignment is still open — and most MCP clients also ask
you to approve each tool call, showing you the text being written. Neither is
something the server can force, which is why the permission you grant at connect
time is the decision that actually matters.

This is the same access you already have. You can change your own submissions
through the course website, and you could do it by calling the API directly with
your own credentials. The assistant gets no more than that: every read and every
write runs as you, so it can never touch another student's work, and deadlines
still apply — the database rejects a write to a closed assignment regardless of
what the assistant intends.

Two honest cautions. Tool results contain text other people wrote — an
assignment description, a teammate's submission — and an assistant that reads
such text can be talked into doing something you never asked for. And an
assistant can simply be wrong. If either worries you for a particular piece of
work, connect it read-only and submit through the website yourself.

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

**`401 Unauthorized`** — your access ran out. Re-authorize: `/mcp` in Claude
Code, or disconnect and reconnect the connector. It is not a sign that anything
is broken.

**Your client says it needs authorization and then gives up** — it cannot do the
sign-in flow. Use `mcp-remote`, described above.

**`403 Forbidden`** — you asked for something your account is not allowed to see
or change. That is row-level security doing its job, not an expired credential;
signing in again will not help. Common causes: a draft assignment, someone else's
row, or a closed submission window.

**`429 Too Many Requests`** — you are going too fast. Wait a bit and retry.

**A write happened and nothing asked you to approve it** — the course site does
not require confirmation, and does not refuse writes from clients that cannot ask.
Any approval prompt you see comes from the client, and some clients show none.
Granting `submissions:write` is the whole authorization: an assistant holding it
can submit. If you want to be asked every time, use a client that prompts, or
connect read-only and submit through the course website.

**A permission is denied** — you did not grant the scope that tool needs.
Re-authorize and check the box on the consent page. Write access is never granted
implicitly.

**Nothing happens after you approve the consent page** — some connectors are
flaky with self-hosted servers. Remove the connector and add it again; if it
still fails, report it with the time it happened.

## See also

- `docs/personal-access-tokens.md` — tokens for your own scripts and notebooks.
- `docs/api-client-security.md` — token handling rules for direct API clients.
- `docs/adr/0001-mcp-and-oauth.md` — why the system is built this way.
- `docs/hydra.md` — operator runbook for the OAuth server.
