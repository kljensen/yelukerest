# How MCP writes are authorized

Short version: **the write scope is the boundary, and row-level security is the
floor.** An agent holding a token with `submissions:write` can change the
student's own coursework, and nothing else. That is the same thing the student
can do through the course website, or by calling PostgREST directly with their
own JWT.

There is no confirmation dialog, no intent token, and no two-step commit. This
document records why, because an earlier design had all three and removing them
was deliberate.

## What is actually enforced

1. **Scope.** `submit_submission_change` requires `submissions:write`. The
   student grants it on the OAuth consent screen, per client. A read-only token
   cannot write, however the agent is prompted or fooled. A non-GET
   `postgrest_request` requires the same scope *and* is refused outright unless
   the deployment has enabled it — see *The escape hatch: off by default, and
   capped at one row* below.
2. **Row-level security.** Every tool call runs under the caller's own
   credential, so an agent can only reach rows the student can reach. This is
   the guarantee that holds even when a model does something stupid.
3. **Deletion is narrow by construction.** Students hold `DELETE` on
   `api.assignment_submissions`, which sounds broader than it is: the foreign
   keys from `assignment_field_submission` and `assignment_grade` are `NO
   ACTION`, so a submission holding any content, or carrying a grade, cannot be
   deleted by anyone through this path. What the grant actually permits is
   clearing away an *empty* submission — which is what a failed first write
   leaves behind (issue #287).
4. **Optimistic concurrency.** `preview_submission_change` returns
   `current_updated_at`; pass it back as `expected_updated_at` and a write that
   would clobber a value that moved is rejected instead. This is a correctness
   feature for concurrent writers, not a security control.

### The escape hatch: off by default, and capped at one row

`postgrest_request` refuses `POST`, `PATCH` and `DELETE` unless the deployment
sets `MCP_ESCAPE_HATCH_WRITES_ENABLED=true` on the mcpapp service (issue #331).
The refusal names `submit_submission_change`, which covers the case a student
actually has. The flag defaults to false in this repository, so a fresh
deployment is never write-open by accident; production turns it on explicitly.
The flag is parsed strictly: only an explicit on spelling (`true`, `1`, `yes`,
`on`) enables writes, and anything unrecognised — a typo such as `flase`, or a
word like `disabled` that reads as off to a human — logs the value and leaves
them disabled. The general environment helpers next to it treat every unknown
value as true, which would turn a misspelling into open raw writes.

The disabled posture is advertised as well as enforced. The tool description
and annotations, the server instructions the client reads at `initialize`, and
the `method` enum in `postgrest_request`'s input schema all describe `GET`
alone when writes are off, so a model is never led to spend a call on a request
this deployment will refuse.

Where the mutating verbs are on, what is bounded is breadth rather than the
verb (issue #337). A `PATCH` or `DELETE` goes upstream carrying

```
Prefer: return=representation, handling=strict, max-affected=1
```

so PostgREST evaluates the result set, and a request that would have affected
more than one row returns HTTP 400 `PGRST124` with the transaction rolled back.
`handling=strict` is not optional: PostgREST ignores `max-affected` without it.
The server turns that response into a message saying the change would have
affected more than one row, that nothing changed, and that
`submit_submission_change` is the tool for a single-field edit; the raw upstream
body is not echoed. `return=representation` still rides along, so a call that
stays inside the cap gets its affected row back.

N is one and is not configurable. The editing unit in this course is one
assignment field, which is exactly what `submit_submission_change` writes, and a
multi-row `PATCH` cannot supply different values per field anyway. `POST` is not
capped: an insert names its target in the body, and capping it would refuse
ordinary bulk inserts of the student's own rows.

The reason to bound breadth rather than refuse the verb is that equal scope is
not equal blast radius. An unfiltered `PATCH` targets every row RLS permits —
for a student that includes the team's shared submissions — so one prompt
injection would otherwise buy a broad multi-row write while staying wholly
inside RLS. Requiring a filter would not have fixed that: `id=gt.0` is a filter,
and PostgREST says the same of `pg-safeupdate`, that it "does not protect
against malicious actions, since someone can add a url parameter that does not
affect the result set." `max-affected` measures the result instead.

GET stays on, and stays scope-gated, whatever the flag says. The read hatch is
what keeps the MCP front door no worse than the caller's own token against the
REST API, which is the principle the hatch was kept on in the first place
(ADR 0001).

#### Two residual risks the cap does not cover

1. **`max-affected` does not constrain `POST`.** The cap is applied to `PATCH`
   and `DELETE` only. A single `POST` with a JSON array body can insert many
   rows. RLS still bounds them to rows the student may insert, and an insert
   cannot overwrite existing work, which is why this is accepted rather than
   solved. If bulk inserts ever become a nuisance, the fix is a cap on the
   parsed body length, not `max-affected`.
2. **A raw `PATCH` still bypasses optimistic concurrency.**
   `submit_submission_change` sends the `updated_at` the caller last read and a
   stale write is rejected. `db/src/data/yeluke/assignment_field_submission.sql`
   deliberately lets a client that omits `updated_at` past that check, so a raw
   `PATCH` through the escape hatch can silently clobber a value that moved
   since it was read. The cap bounds how many rows that can happen to — one —
   not whether it can happen. Prefer `submit_submission_change`, which is why
   the tool description, the server instructions, `get_api_schema`, and the
   `PGRST124` message all point at it.

`preview_submission_change` shows what a write would do and needs no write
scope. Showing it to the student first is good manners and good agent design.
It is not a gate, and nothing depends on the agent choosing to do it.

## Why the confirmation flow was removed

The original design refused any write unless the client could display a
server-generated confirmation, using MCP elicitation, on top of a single-use
HMAC intent token binding a `prepare` call to a `commit`. The reasoning was
prompt injection: an injected agent can call prepare and commit back to back
without the student ever seeing anything.

Four things were wrong with it.

**It granted less than the API it fronts.** A student can already `PATCH`
their submission with their own token, from curl, with no ceremony at all. The
MCP server exists to be a convenient front door to that same API under the same
credential. A gate that exists only on the MCP path does not remove the
capability, it just makes the front door worse than the side door. The escape
hatch was kept on exactly this principle; the write gate violated it.

**Confirmation is the host's job, and the spec says so.** From the MCP
specification's tools page:

> "For trust & safety and security, there **SHOULD** always be a human in the
> loop with the ability to deny tool invocations."

and, under Security Considerations, clients **SHOULD** "show tool inputs to the
user before calling the server." That prompt shows the arguments — the actual
text being written — which our own confirmation message never did. We publish
`destructiveHint: true` on the write tools, which is the standardized way to
say "prompt on this one."

**It depended on a mechanism the protocol withdrew.** Server-initiated requests
over a held-open SSE stream were how elicitation reached the client. The current
revision removed them:

> "The server **MUST NOT** send independent JSON-RPC *requests* on this stream…
> This is a change from Streamable HTTP in protocol versions `2025-03-26`
> through `2025-11-25`, where servers could send such requests on SSE streams."

In practice it also broke: holding a tool call open while waiting for a human
wedged sessions permanently and leaked them until the process restarted, which
is how the bug was found.

**Most clients cannot participate.** Elicitation is implemented by a small
minority of MCP clients. Failing closed without it meant writes simply did not
work in the clients students would actually use, while the students who reached
for curl were unaffected — security theatre with a real usability cost.

## What that leaves as the risk

An agent with the write scope that falls for a prompt injection in course
content can write something the student did not ask for, to the student's own
submission. That is real, and it is the same exposure a student accepts by
running any script with their own API credential. The mitigations are the ones
that actually work: the student decides whether to grant the write scope at all,
the host prompts on a destructive tool, `serverInstructions` tells the model to
treat tool results as untrusted data, and row-level security bounds the damage
to the student's own rows.

`tests/agent/prompt-injection.js` asserts exactly that division: with a
read-only token an injection can never produce a write, and with a write token
the blast radius stays inside the student's own data no matter how thoroughly
the model is fooled. Whether the model falls for the injection at all is
recorded, not asserted — see `docs/testing-agents.md`.
