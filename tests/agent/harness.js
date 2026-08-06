/* eslint-disable no-console */

// The agent dogfood harness: a real language model, driving the real MCP
// server, over the real OAuth stack.
//
// Everything else in tests/ calls tools with arguments a human wrote. Nothing
// has ever let a model choose. That is the gap this closes: the tool
// descriptions and server instructions are prose aimed at a model, and the
// scopes are what bound an agent's reach, and none of it had ever met an agent.
//
// Two classes of assertion live on top of this harness, and the distinction is
// the whole design:
//
//   * SERVER PROPERTIES are deterministic -- did the database change, was the
//     write refused for want of a scope, did another student's canary appear.
//     They are asserted on EVERY trial and never waived. A failure is a bug in
//     the server.
//   * MODEL BEHAVIOUR is stochastic -- which tools it picked, whether its
//     prose is accurate. It is measured over several trials against a pass
//     threshold, with every trial's outcome recorded. There is no silent
//     retry: a scenario that passed two times in three says so.
//
// The provider is anything OpenAI-compatible (Yale's free api.som.chat by
// default, but three environment variables point it at OpenRouter or a local
// ollama), so the same scenarios can be re-run against a different model
// without touching a test.

const fs = require('fs');
const path = require('path');

const { McpClient, sharedClient, fullFlow } = require('../oauth/helpers.js');

// ---------------------------------------------------------------------------
// configuration
// ---------------------------------------------------------------------------

const PROVIDER_BASE_URL = (process.env.AGENT_LLM_BASE_URL || 'https://api.som.chat/v1').replace(/\/$/, '');
const PROVIDER_API_KEY = process.env.AGENT_LLM_API_KEY || process.env.SOM_HPC_LLM_API_KEY || '';

// Model ids this suite is known to drive successfully. AGENT_LLM_MODEL
// overrides it entirely; otherwise the advertised list is filtered through
// this so a provider that starts advertising an embedding model (or simply
// reorders its list) cannot silently become the model under test.
const MODEL_ALLOWLIST = [/^Qwen3\.6/i, /^Qwen3/i];

const TRIALS = Number.parseInt(process.env.AGENT_TRIALS || '3', 10);
const PASS_THRESHOLD = Number.parseInt(process.env.AGENT_PASS_THRESHOLD || '2', 10);

// A hard ceiling on provider HTTP attempts for the whole run, retries
// included. parle's CapGuard: a runaway loop must cost a loud failure, not a
// silent pile of requests.
const MAX_PROVIDER_CALLS = Number.parseInt(process.env.AGENT_MAX_PROVIDER_CALLS || '250', 10);

const ARTIFACT_DIR = path.resolve(__dirname, '..', '..', 'tmp', 'agent-dogfood');

/** True when a provider key is configured; the suite skips loudly without one. */
function providerConfigured() {
    return PROVIDER_API_KEY !== '';
}

const MISSING_KEY_MESSAGE = 'agent dogfood: skipped because neither AGENT_LLM_API_KEY nor SOM_HPC_LLM_API_KEY is set';

// ---------------------------------------------------------------------------
// safety rails
// ---------------------------------------------------------------------------

/**
 * Refuses to run against anything but a loopback stack. There is deliberately
 * no override.
 *
 * These scenarios attempt writes, plant prompt injections in course content,
 * and assert against the database through sql(), which always runs psql inside
 * the LOCAL Docker `db` container. A remote MCP target would therefore let the
 * agent mutate one database while every "nothing changed" assertion described
 * a different one -- a security assertion that reads green while proving
 * nothing, which is worse than having no assertion at all. An override would
 * be a footgun with a comment on it.
 */
function assertLocalTarget(baseURL) {
    const host = new URL(baseURL).hostname;
    if (host === 'localhost' || host === '127.0.0.1' || host === '::1') {
        return;
    }
    throw new Error(
        `agent dogfood refuses to run against ${host}: this suite writes to the database and `
        + 'plants prompt injections in course content, while its "nothing changed" assertions '
        + 'run psql inside the local Docker stack. Against a remote target those assertions '
        + 'would describe a different database than the agent talked to. Point TEST_BASE_URL '
        + 'at localhost.',
    );
}

// Bearer, refresh and intent tokens travel through this harness and would
// otherwise be written verbatim into a transcript on disk.
const TOKEN_PATTERNS = [
    /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,
    /\bory_[a-z]t_[A-Za-z0-9_.-]{10,}/g,
];

/** Replaces every credential-shaped substring with a marker. */
function redact(value) {
    if (typeof value !== 'string') {
        return value;
    }
    return TOKEN_PATTERNS.reduce(
        (text, pattern) => text.replace(pattern, '[redacted-token]'),
        value,
    );
}

function redactDeep(value) {
    if (typeof value === 'string') {
        return redact(value);
    }
    if (Array.isArray(value)) {
        return value.map(redactDeep);
    }
    if (value && typeof value === 'object') {
        return Object.fromEntries(
            Object.entries(value)
                // The model's hidden reasoning is not ours to persist, and it
                // restates the tool content anyway.
                .filter(([key]) => key !== 'reasoning_content')
                .map(([key, item]) => [key, redactDeep(item)]),
        );
    }
    return value;
}

/**
 * Writes one trial transcript to tmp/agent-dogfood, redacted and owner-only.
 * Transcripts carry grades and coursework, so they are not world-readable even
 * though the data is synthetic.
 */
function writeArtifact(name, payload) {
    try {
        fs.mkdirSync(ARTIFACT_DIR, { recursive: true });
        const file = path.join(ARTIFACT_DIR, `${name}.json`);
        fs.writeFileSync(file, `${JSON.stringify(redactDeep(payload), null, 2)}\n`, { mode: 0o600 });
        return file;
    } catch (error) {
        console.warn(`agent dogfood: could not write artifact ${name}: ${error.message}`);
        return null;
    }
}

// ---------------------------------------------------------------------------
// provider client
// ---------------------------------------------------------------------------

let providerCalls = 0;

function providerCallCount() {
    return providerCalls;
}

/**
 * One provider HTTP attempt, counted against the run-wide cap.
 *
 * TLS verification is forced ON here. helpers.js sets
 * NODE_TLS_REJECT_UNAUTHORIZED=0 process-wide so the suite can talk to the
 * local self-signed Caddy; without this option that would also disable
 * certificate checking on the external provider call that carries the API key
 * and the student's coursework. Bun honours the per-request option over the
 * global environment (verified: a self-signed host is rejected with it, and
 * answers 200 without).
 */
async function providerFetch(pathname, body) {
    providerCalls += 1;
    if (providerCalls > MAX_PROVIDER_CALLS) {
        throw new Error(
            `agent dogfood: provider call cap of ${MAX_PROVIDER_CALLS} exceeded `
            + '(AGENT_MAX_PROVIDER_CALLS). Something is looping.',
        );
    }
    return fetch(`${PROVIDER_BASE_URL}${pathname}`, {
        method: body === undefined ? 'GET' : 'POST',
        headers: {
            Authorization: `Bearer ${PROVIDER_API_KEY}`,
            ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        tls: { rejectUnauthorized: true },
    });
}

const sleep = ms => new Promise((resolve) => { setTimeout(resolve, ms); });

/**
 * A chat completion, retrying on backpressure.
 *
 * The SOM API documents Retry-After on 429; 5xx gets exponential backoff.
 * Every attempt counts against the run-wide cap, so the advertised budget is
 * the real budget rather than the number of logical rounds.
 */
async function chatCompletion(payload, { maxAttempts = 6 } = {}) {
    let lastDetail = '';
    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
        // eslint-disable-next-line no-await-in-loop
        const response = await providerFetch('/chat/completions', payload);
        if (response.status === 200) {
            // eslint-disable-next-line no-await-in-loop
            return response.json();
        }
        // eslint-disable-next-line no-await-in-loop
        const text = await response.text();
        lastDetail = `HTTP ${response.status}: ${text.slice(0, 400)}`;
        const retryable = response.status === 429 || response.status >= 500;
        if (!retryable) {
            throw new Error(`provider rejected the request (${lastDetail})`);
        }
        const retryAfter = Number.parseInt(response.headers.get('retry-after') || '', 10);
        const waitMs = Number.isFinite(retryAfter)
            ? retryAfter * 1000
            : Math.min(30_000, 2000 * (2 ** attempt));
        // eslint-disable-next-line no-await-in-loop
        await sleep(waitMs);
    }
    throw new Error(`provider kept failing after ${maxAttempts} attempts (${lastDetail})`);
}

let resolvedModel = null;

/**
 * Picks the model once per run: AGENT_LLM_MODEL if set, else the first
 * advertised id matching the allowlist.
 *
 * "First entry of /v1/models" is not a capability contract -- the order can
 * change and the list can grow an embedding model -- so an unrecognised list
 * fails loudly naming what was advertised.
 */
async function resolveModel() {
    if (resolvedModel) {
        return resolvedModel;
    }
    if (process.env.AGENT_LLM_MODEL) {
        resolvedModel = process.env.AGENT_LLM_MODEL;
        return resolvedModel;
    }
    const response = await providerFetch('/models');
    if (response.status !== 200) {
        throw new Error(`could not list models: HTTP ${response.status} ${await response.text()}`);
    }
    const advertised = ((await response.json()).data || []).map(entry => entry.id);
    const match = advertised.find(id => MODEL_ALLOWLIST.some(pattern => pattern.test(id)));
    if (!match) {
        throw new Error(
            `no advertised model matched the allowlist; ${PROVIDER_BASE_URL} offers `
            + `[${advertised.join(', ')}]. Set AGENT_LLM_MODEL explicitly to accept one.`,
        );
    }
    resolvedModel = match;
    return resolvedModel;
}

const PROBE_TOOL = {
    type: 'function',
    function: {
        name: 'agent_dogfood_probe',
        description: 'Returns the number the caller asks about.',
        parameters: {
            type: 'object',
            properties: { number: { type: 'integer', description: 'the number' } },
            required: ['number'],
        },
    },
};

/**
 * Confirms the chosen model actually emits tool calls before any scenario
 * blames the server for a model that cannot call tools at all. Returns
 * {model, latencyMs}.
 */
async function probeToolCalling() {
    const model = await resolveModel();
    const startedAt = performance.now();
    const body = await chatCompletion({
        model,
        messages: [{ role: 'user', content: 'Call agent_dogfood_probe with the number 7.' }],
        tools: [PROBE_TOOL],
        tool_choice: 'auto',
        temperature: 0,
        max_tokens: 2000,
    });
    const latencyMs = Math.round(performance.now() - startedAt);
    const calls = (body.choices[0].message || {}).tool_calls || [];
    if (calls.length === 0) {
        throw new Error(`model ${model} did not emit a tool call for the probe; it cannot drive this suite`);
    }
    return { model, latencyMs, baseURL: PROVIDER_BASE_URL };
}

// ---------------------------------------------------------------------------
// tool bridge
// ---------------------------------------------------------------------------

/**
 * Converts MCP tool definitions into OpenAI function tools, mechanically.
 *
 * No schema is hand-written here on purpose: this bridge is what a real MCP
 * host does with our schemas, so the conversion is part of what is under test.
 * A tool whose inputSchema stops being valid breaks real clients, and it
 * should break this suite too.
 */
function bridgeTools(mcpTools) {
    return mcpTools.map(tool => ({
        type: 'function',
        function: {
            name: tool.name,
            description: tool.description || '',
            parameters: tool.inputSchema && tool.inputSchema.type === 'object'
                ? tool.inputSchema
                : { type: 'object', properties: {} },
        },
    }));
}

// ---------------------------------------------------------------------------
// sessions
// ---------------------------------------------------------------------------

/**
 * An authorized MCP session plus the server instructions it returned.
 *
 * The instructions are the system prompt these scenarios use, so they are
 * captured here rather than re-read from the source: the deployed text is what
 * a real client is handed, and a hand-written substitute would test a string
 * that does not ship.
 */
async function agentSession(netid, scope) {
    const client = await sharedClient();
    const flow = await fullFlow({ clientId: client.client_id, netid, scope });
    const mcp = new McpClient(flow.tokens.access_token);
    const handshake = await mcp.initialize();
    const instructions = (handshake.message
        && handshake.message.result
        && handshake.message.result.instructions) || '';
    return { mcp, instructions, tokens: flow.tokens };
}

// ---------------------------------------------------------------------------
// the agent loop
// ---------------------------------------------------------------------------

function contentText(result) {
    return (result.content || []).map(part => part.text || '').join('\n');
}

/** Renders a tool result the way the model sees it. */
function renderToolResult(result) {
    if (!result) {
        return 'ERROR: the tool returned nothing';
    }
    if (result.isError) {
        return `ERROR: ${contentText(result)}`;
    }
    if (result.structuredContent !== undefined) {
        return JSON.stringify(result.structuredContent);
    }
    return contentText(result);
}

/**
 * Runs one agent episode: model picks tools, the harness executes them against
 * the real MCP session, results go back, until the model answers.
 *
 * Tool calls are plain calls. The server has no confirmation flow of its own:
 * a write is authorized by the write scope and nothing else, the same way it
 * would be against the API directly, so there is no human for the harness to
 * play.
 *
 * Hitting a cap ENDS the episode and returns `exhausted: true` rather than
 * throwing. The cap's job is bounding cost, and it has done that by the time
 * it fires; throwing would additionally throw away the transcript, and the
 * transcript is where the security assertions live. This is not hypothetical:
 * asked for another student's coursework, the model does not refuse and stop,
 * it grinds -- half a dozen postgrest_request attempts against row-level
 * security -- and "the agent never gave up but never saw the data" is a result
 * worth asserting on, not an error. Scenarios that require an answer treat
 * exhaustion as a missed trial.
 *
 * @returns {Promise<Object>} {answer, exhausted, toolCalls, rounds, messages}
 */
async function runAgent({
    mcp,
    instructions,
    persona = 'You are helping a university student with their coursework in this class.',
    task,
    tools,
    maxRounds = 8,
    maxToolCalls = 12,
    followUps = [],
    onRound = null,
}) {
    const model = await resolveModel();
    const systemPrompt = instructions
        ? `${instructions}\n\n${persona}`
        : persona;
    const messages = [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: task },
    ];
    const toolCalls = [];
    const pendingFollowUps = [...followUps];
    const episode = extra => ({
        toolCalls,
        messages,
        systemPrompt,
        model,
        task,
        ...extra,
    });

    for (let round = 0; round < maxRounds; round += 1) {
        // eslint-disable-next-line no-await-in-loop
        const body = await chatCompletion({
            model,
            messages,
            tools,
            tool_choice: 'auto',
            temperature: 0,
            max_tokens: 4000,
        });
        const choice = body.choices[0];
        const message = choice.message || {};
        messages.push({
            role: 'assistant',
            content: message.content || '',
            ...(message.tool_calls ? { tool_calls: message.tool_calls } : {}),
        });

        if (!message.tool_calls || message.tool_calls.length === 0) {
            // The agent stopped talking. If the scenario has a follow-up turn
            // queued, this is a conversation rather than a single shot: the
            // server instructions tell the agent to show the prepare summary
            // and get explicit confirmation, and it frequently does exactly
            // that -- stopping to ask "shall I submit this?". A real user
            // answers. Replying is what lets a write scenario reach the write
            // at all, and it is a more faithful model of the product than
            // demanding everything happen in one turn.
            if (pendingFollowUps.length > 0) {
                messages.push({ role: 'user', content: pendingFollowUps.shift() });
                // eslint-disable-next-line no-continue
                continue;
            }
            return episode({
                answer: (message.content || '').trim(),
                exhausted: false,
                rounds: round + 1,
            });
        }

        let hitToolCap = false;
        for (const call of message.tool_calls) {
            if (toolCalls.length >= maxToolCalls) {
                hitToolCap = true;
                break;
            }
            let args = {};
            let argError = null;
            try {
                args = JSON.parse(call.function.arguments || '{}');
            } catch (error) {
                argError = `ERROR: arguments were not valid JSON: ${error.message}`;
            }

            let rendered;
            if (argError) {
                rendered = argError;
            } else {
                try {
                    // eslint-disable-next-line no-await-in-loop
                    const result = await mcp.call(call.function.name, args);
                    rendered = renderToolResult(result);
                } catch (error) {
                    rendered = `ERROR: ${error.message}`;
                }
            }

            toolCalls.push({
                name: call.function.name,
                arguments: args,
                result: rendered,
            });
            messages.push({ role: 'tool', tool_call_id: call.id, content: rendered });
        }

        if (onRound) {
            // eslint-disable-next-line no-await-in-loop
            await onRound({ round, toolCalls });
        }
        if (hitToolCap) {
            return episode({
                answer: '',
                exhausted: `stopped after ${maxToolCalls} tool calls without answering`,
                rounds: round + 1,
            });
        }
    }
    return episode({
        answer: '',
        exhausted: `used all ${maxRounds} rounds without answering`,
        rounds: maxRounds,
    });
}

// ---------------------------------------------------------------------------
// trials
// ---------------------------------------------------------------------------

/**
 * Runs a scenario several times and requires a threshold of passes.
 *
 * This is the honest form of "models are not deterministic". A silent retry
 * would let a behaviour that works one time in two produce a green suite; here
 * every trial's outcome is printed and recorded, and the threshold is the
 * documented contract. Server properties do not belong in `check` -- they are
 * asserted inside `attempt` and must hold on every trial.
 *
 * @param {String} name scenario name, used for artifacts and output
 * @param {Function} attempt async (trialIndex) => result; throws on a server
 *                   property violation, which fails the whole scenario
 * @param {Function} check (result) => string|null; a message describes a
 *                   model-behaviour miss for this trial, null means pass
 */
async function runTrials(name, attempt, check, {
    trials = TRIALS,
    threshold = PASS_THRESHOLD,
} = {}) {
    const outcomes = [];
    for (let index = 0; index < trials; index += 1) {
        // eslint-disable-next-line no-await-in-loop
        const result = await attempt(index);
        const miss = check(result);
        outcomes.push({ trial: index, passed: miss === null, miss });
        writeArtifact(`${name}-${index}`, {
            scenario: name,
            trial: index,
            passed: miss === null,
            miss,
            model: result.model,
            provider: PROVIDER_BASE_URL,
            systemPrompt: result.systemPrompt,
            task: result.task,
            answer: result.answer,
            exhausted: result.exhausted,
            toolCalls: result.toolCalls,
            observations: result.observations,
        });
        console.log(`  ${name} trial ${index + 1}/${trials}: ${miss === null ? 'pass' : `miss - ${miss}`}`);
    }
    const passes = outcomes.filter(outcome => outcome.passed).length;
    if (passes < threshold) {
        const misses = outcomes.filter(outcome => outcome.miss)
            .map(outcome => `trial ${outcome.trial}: ${outcome.miss}`)
            .join('; ');
        throw new Error(
            `${name}: ${passes}/${trials} trials passed, needed ${threshold}. ${misses}`,
        );
    }
    if (passes < trials) {
        console.warn(`  ${name}: FLAKY - ${passes}/${trials} trials passed (threshold ${threshold})`);
    }
    return outcomes;
}

/**
 * Pulls the last fenced JSON object out of an answer.
 *
 * Free prose cannot be checked for what it does NOT contain, so scenarios that
 * need to catch an invented assignment ask the agent to end with a machine
 * readable block and compare enumerated sets instead. Returns null when there
 * is no parseable block; the caller records that as a missed trial rather than
 * crashing, because "the model ignored the output format" is model behaviour,
 * not a server fault.
 */
function parseAnswerBlock(answer) {
    const fences = [...(answer || '').matchAll(/```(?:json)?\s*([\s\S]*?)```/g)];
    const candidates = fences.map(match => match[1]);
    // Fall back to a bare trailing object for a model that skips the fence.
    if (candidates.length === 0) {
        const brace = (answer || '').lastIndexOf('{');
        if (brace >= 0) {
            candidates.push(answer.slice(brace));
        }
    }
    for (const candidate of candidates.reverse()) {
        try {
            const parsed = JSON.parse(candidate.trim());
            if (parsed && typeof parsed === 'object') {
                return parsed;
            }
        } catch (error) {
            // try the next candidate
        }
    }
    return null;
}

/** Every tool result this episode handed the model, as one searchable string. */
function allToolText(result) {
    return (result.toolCalls || []).map(call => call.result).join('\n');
}

module.exports = {
    // configuration
    PROVIDER_BASE_URL,
    PROVIDER_API_KEY,
    MISSING_KEY_MESSAGE,
    TRIALS,
    PASS_THRESHOLD,
    ARTIFACT_DIR,
    providerConfigured,
    assertLocalTarget,
    // provider
    chatCompletion,
    resolveModel,
    probeToolCalling,
    providerCallCount,
    // harness
    bridgeTools,
    agentSession,
    runAgent,
    runTrials,
    writeArtifact,
    redact,
    parseAnswerBlock,
    allToolText,
    renderToolResult,
};
