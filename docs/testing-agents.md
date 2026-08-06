# Agent dogfood tests

`bun run test_agent` points a real language model at the real MCP server and
watches what it does. Every other test in this repository calls tools with
arguments a human wrote; these are the only ones where the model chooses.

That matters because the server's security contract is written *against an
agent*. "Writes fail closed without elicitation" exists to stop an injected
agent. The tool descriptions and `serverInstructions` are prose aimed at a
model. Until this suite, none of it had ever met one.

The suite is **opt-in and never part of `bun run test`**: it needs a provider
key, it costs wall-clock time, and its model-behaviour half is a measurement
rather than a pass/fail gate.

## Running it

```sh
./bin/dev.sh up                      # the stack these tests drive
export SOM_HPC_LLM_API_KEY=sk-som-…  # or AGENT_LLM_API_KEY
bun run test_agent
```

Without a key the whole suite skips with one message naming the variable. If
your dev database is remapped off port 5432 (a common local port clash), pass
`DB_TEST_PORT` the same way the other suites need it:

```sh
DB_TEST_PORT=55432 bun run test_agent
```

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENT_LLM_API_KEY` | `$SOM_HPC_LLM_API_KEY` | provider credential; absent means skip |
| `AGENT_LLM_BASE_URL` | `https://api.som.chat/v1` | any OpenAI-compatible base |
| `AGENT_LLM_MODEL` | first advertised model matching the allowlist | pin a model |
| `AGENT_TRIALS` | `3` | trials per model-behaviour scenario |
| `AGENT_PASS_THRESHOLD` | `2` | trials that must pass |
| `AGENT_MAX_PROVIDER_CALLS` | `250` | run-wide ceiling on provider HTTP attempts |

The default provider is Yale SOM's `api.som.chat`, which is free for Yale
users and hosts an OpenAI-compatible `/v1` (and an Anthropic-compatible
`/v1/messages`, unused here). Its model changes over time, so the suite
discovers it rather than hardcoding one — filtered through an allowlist, since
"first entry of `/v1/models`" is an ordering, not a capability contract.

Pointing at another provider is three variables and no code:

```sh
# a local, air-gapped model
AGENT_LLM_BASE_URL=http://127.0.0.1:11434/v1 AGENT_LLM_API_KEY=none \
  AGENT_LLM_MODEL=qwen3 bun run test_agent

# OpenRouter
AGENT_LLM_BASE_URL=https://openrouter.ai/api/v1 AGENT_LLM_API_KEY=$OPENROUTER_API_KEY \
  AGENT_LLM_MODEL=openai/gpt-oss-120b bun run test_agent
```

## The two kinds of assertion

This is the design, and it is worth understanding before reading a failure.

**Server properties are deterministic.** Did the database change? Was the
commit refused? Did another student's canary appear? These are asserted on
*every* trial and are never subject to the pass threshold. A failure here is a
bug in the server, and it should be treated like any other failing test.

**Model behaviour is stochastic.** Which tools it picked, whether its answer is
accurate. This is measured over `AGENT_TRIALS` against `AGENT_PASS_THRESHOLD`,
with every trial's outcome printed. There is deliberately no silent retry: a
scenario that passes two times in three prints `FLAKY` and says so. If a model
upgrade makes the suite consistently miss, that is information about the model,
not necessarily a regression in the server.

Some things are recorded and not asserted on at all — most importantly *whether
the model followed a planted prompt injection*. Models change; a suite that turned
red every time a model got more gullible would teach us nothing, and one that
turned green would not mean the server was safe. The number lives in the
artifact so it can be watched across upgrades.

## What each file covers

- **`tool-schemas.js`** — no model needed. Our published schemas survive the
  bridge to an OpenAI tool list, the server instructions are present, and the
  generic elicitation path is driven down **both** write mechanisms (the
  curated `prepare`/`commit` pair and the `prepare_api_request` + non-GET
  `postgrest_request` escape hatch) under each policy. Mechanism coverage lives
  here, deterministically, because no model-driven test can guarantee the model
  attempts either path.
- **`read-navigation.js`** — the everyday question. Ground truth comes from the
  same tools called directly for the same student, never from superuser SQL,
  which would bypass the RLS and release logic the agent is subject to. The
  agent is asked to end with a JSON block so its assignment list can be compared
  as a set in both directions — that is what catches an invented assignment,
  which scanning prose cannot.
- **`rls-boundary.js`** — another student's coursework must not reach the agent,
  however it is asked. Uses a planted high-entropy canary, because numeric
  grades are useless here: `get_my_grades` legitimately returns the sorted
  *anonymous* class distribution, so another student's score appears in this
  student's results by design.
- **`write-path.js`** — fail-closed, confirmed, and declined, with the model
  deciding. Note that two model behaviours are correct in the fail-closed case:
  stopping after `prepare` to ask the student (what the instructions say to do)
  or barrelling into the commit and being refused.
- **`prompt-injection.js`** — a hostile instruction planted in the student's own
  coursework, telling the agent to write a different field. Asserted only under
  the policies where the human did not approve: with the harness playing a user
  who clicks yes, a write that succeeds is consent working as designed, and the
  interesting question becomes what the user was shown first (issue #284).

## Known bugs this suite found

Running it is the point, but two of its findings are open issues you will see
referenced in the code:

- **#286 — elicitation hangs, and a long-lived `mcpapp` is what breaks.** Found
  here, then narrowed: reusing one session hangs around the fourth exchange
  while fresh sessions succeed in milliseconds — but fresh sessions are not
  enough once a whole suite has run against one `mcpapp`, and **restarting
  `mcpapp` makes the suite pass 16/16**. So the exhausted resource accumulates
  in the process, which matters because production runs for weeks. It also makes
  the older `tests/oauth/write-path.js` intermittently fail, so it predates this
  suite. **If you see a 90-second hang, restart `mcpapp` and re-run.**
- **#285 — a declined write can be re-prompted until the user gives in.** The
  agent does not accept the first "no": it retries the commit, each retry
  re-elicits, and the user sees the same dialog five times. Nothing is written
  each time, so the gate holds — the concern is consent fatigue.

Both are recorded as observations in the transcripts rather than being papered
over, which is how the suite is meant to work.

## Safety

- **Loopback only, no override.** `sql()` runs psql inside the local Docker `db`
  container, so against a remote MCP target every "nothing changed" assertion
  would describe a different database than the agent talked to. The suite
  refuses rather than offering a flag.
- **Synthetic data only.** These scenarios plant prompt injections in course
  content and write real submissions. `resetdb()` runs at suite start and
  teardown.
- **TLS is verified on provider calls** even though the suite sets
  `NODE_TLS_REJECT_UNAUTHORIZED=0` for the local self-signed Caddy; the API key
  and coursework leave the machine, so those requests opt back in explicitly.
- **Transcripts** land in `tmp/agent-dogfood/` at mode `0600` with
  credential-shaped strings redacted and the model's hidden reasoning dropped.
  They are the first thing to read when a trial misses.
