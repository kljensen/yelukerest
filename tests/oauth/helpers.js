/* eslint-disable no-console */

// Shared machinery for the end-to-end OAuth + MCP suite (issue #275).
//
// Everything here drives the REAL stack through Caddy exactly the way a
// third-party MCP client would: dynamic client registration through the
// cleaning proxy, an authorization-code + PKCE dance that logs in through the
// mock CAS server and posts the JS-free consent form, a token exchange, and
// then JSON-RPC calls against /mcp.
//
// Two escape hatches exist for things a public client cannot do:
//   * hydraAdmin() calls Hydra's admin API (port 4445, never
//     proxied by Caddy and never published to the host) over `nc` inside the
//     db container. It is used for setup and teardown only.
//   * sql() runs psql for "did anything actually get written?" assertions.

const { spawnSync } = require('child_process');
const crypto = require('crypto');
const path = require('path');

// Docker Compose is invoked from the repository root with the same file set
// tests/rest/common.js uses, so `docker compose exec` resolves to the running
// dev stack no matter what the test runner's working directory is.
const repoRoot = path.resolve(__dirname, '..', '..');
const composeFiles = (process.env.YELUKEREST_COMPOSE_FILES
    || 'docker-compose.base.yaml,docker-compose.dev.yaml')
    .split(',')
    .filter(Boolean)
    .flatMap(file => ['-f', file]);

const baseURL = (process.env.TEST_BASE_URL || 'https://localhost').replace(/\/$/, '');
const mcpURL = `${baseURL}/mcp`;
const issuer = baseURL;

// The mock CAS server accepts any netid via `&id=`; these come from
// db/src/sample_data/yeluke/users.sql.
const NETIDS = {
    student: 'abc123',
    otherStudent: 'bde456',
    faculty: 'klj39',
    ta: 'jlb325',
};

// Loopback callback used for every client we register. Nothing listens on it:
// the flow stops as soon as Hydra hands us a redirect to this host.
const LOOPBACK_PORT = 9876;
const LOOPBACK_REDIRECT = `http://127.0.0.1:${LOOPBACK_PORT}/callback`;

// Hydra's admin API, published on loopback by docker-compose.dev.yaml for the
// tests only. It is unauthenticated, which is exactly why production never
// exposes it.
const hydraAdminURL = process.env.HYDRA_ADMIN_URL || 'http://127.0.0.1:4445';

const READ_SCOPES = 'openid offline_access course:read grades:read submissions:read';
const WRITE_SCOPES = `${READ_SCOPES} submissions:write`;

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

// ---------------------------------------------------------------------------
// tiny utilities
// ---------------------------------------------------------------------------

const sleep = ms => new Promise((resolve) => { setTimeout(resolve, ms); });

/** Decodes the payload of a JWT without verifying it (assertions only). */
function decodeJWT(token) {
    const part = token.split('.')[1];
    return JSON.parse(Buffer.from(part, 'base64url')
        .toString('utf8'));
}

/** Returns a fresh PKCE verifier/challenge pair using S256. */
function pkcePair() {
    const verifier = crypto.randomBytes(32)
        .toString('hex');
    const challenge = crypto.createHash('sha256')
        .update(verifier)
        .digest('base64url');
    return { verifier, challenge };
}

/** Hydra rejects `state` values shorter than 8 characters (invalid_state). */
function randomState(prefix = 'e2e') {
    return `${prefix}-${crypto.randomBytes(12).toString('hex')}`;
}

// ---------------------------------------------------------------------------
// cookie-aware fetch
// ---------------------------------------------------------------------------

/**
 * A single-origin cookie jar. Every party in this flow (Hydra, authapp, the
 * mock CAS server) is served from the same Caddy origin, so a flat
 * name->value map is a faithful browser.
 */
class CookieJar {
    constructor() {
        this.cookies = new Map();
    }

    store(response) {
        const setCookies = typeof response.headers.getSetCookie === 'function'
            ? response.headers.getSetCookie()
            : [];
        setCookies.forEach((raw) => {
            const pair = raw.split(';')[0];
            const index = pair.indexOf('=');
            if (index < 0) {
                return;
            }
            const name = pair.slice(0, index)
                .trim();
            const value = pair.slice(index + 1)
                .trim();
            if (value === '') {
                this.cookies.delete(name);
            } else {
                this.cookies.set(name, value);
            }
        });
    }

    header() {
        return [...this.cookies.entries()].map(([name, value]) => `${name}=${value}`)
            .join('; ');
    }
}

/**
 * fetch() that never follows redirects and keeps `jar` up to date.
 *
 * authapp rate limits its OAuth login/consent handlers to 60 requests per
 * minute per client address (authapp/main.go), and a full suite run walks that
 * flow far more often than a human would. A 429 is therefore treated as
 * back-pressure, not a result: the request is retried after the sliding window
 * has had time to drain. Pass {noRetry: true} in a test that is deliberately
 * measuring the limiter.
 */
// authapp's OAuth login/consent limiter is a 60-request sliding window per
// client address. A suite run walks the flow ~30 times, so rather than
// discovering the limit through 429s and backing off (which turns a two-minute
// run into a ten-minute one), requests to those handlers are paced to stay
// just under it. The 429 retry below remains as a safety net.
const OAUTH_PACE_WINDOW_MS = 60_000;
const OAUTH_PACE_LIMIT = 55;
const oauthRequestTimes = [];

async function paceOAuthHandlers(url) {
    if (!url.includes('/auth/oauth/')) {
        return;
    }
    for (;;) {
        const now = Date.now();
        while (oauthRequestTimes.length > 0 && oauthRequestTimes[0] <= now - OAUTH_PACE_WINDOW_MS) {
            oauthRequestTimes.shift();
        }
        if (oauthRequestTimes.length < OAUTH_PACE_LIMIT) {
            oauthRequestTimes.push(now);
            return;
        }
        // eslint-disable-next-line no-await-in-loop
        await sleep((oauthRequestTimes[0] + OAUTH_PACE_WINDOW_MS) - now + 250);
    }
}

async function jarFetch(url, options = {}, jar = null) {
    await paceOAuthHandlers(url);
    const headers = { ...(options.headers || {}) };
    if (jar) {
        const cookie = jar.header();
        if (cookie) {
            headers.Cookie = cookie;
        }
    }
    let response;
    for (let attempt = 0; attempt < 40; attempt += 1) {
        // eslint-disable-next-line no-await-in-loop
        response = await fetch(url, {
            ...options,
            headers,
            redirect: 'manual',
        });
        if (response.status !== 429 || options.noRetry) {
            break;
        }
        // A 429 means the server's window is fuller than our own pacer knows
        // -- typically because a previous run drained it seconds ago. Record
        // the attempt so pacing tightens, and retry on a short interval.
        oauthRequestTimes.push(Date.now());
        // eslint-disable-next-line no-await-in-loop
        await sleep(2500);
    }
    if (jar) {
        jar.store(response);
    }
    return response;
}

// ---------------------------------------------------------------------------
// docker-side escape hatches
// ---------------------------------------------------------------------------

function compose(args, options = {}) {
    const argv = ['compose', ...composeFiles, ...args];
    const result = spawnSync('docker', argv, {
        encoding: 'utf8',
        cwd: repoRoot,
        // `compose logs` for a debug-logging proxy runs to many megabytes.
        maxBuffer: 256 * 1024 * 1024,
        ...options,
    });
    if (result.error) {
        throw new Error(`docker ${argv.join(' ')} failed: ${result.error.message}`);
    }
    return result;
}

/**
 * Speaks raw HTTP/1.1 to Hydra's admin API from inside the compose network.
 * The admin port is deliberately unpublished, so this must go through a
 * container on the compose network.
 *
 * This used to hand-roll an HTTP request and pipe it through `nc` in the db
 * image. postgres:18.4 moved to Debian trixie, which no longer ships netcat, so
 * every call started failing with "nc: not found" -- and because the three
 * tests that depend on it were the only callers, three security assertions went
 * quietly dead while the suite still reported green overall. Use wget from the
 * elmclient image instead: a real HTTP client, no hand-parsed status lines, and
 * nothing that depends on a base image keeping a tool it never promised.
 *
 * @param {String} method HTTP method
 * @param {String} path request target, e.g. /admin/clients
 * @param {Object} body optional JSON body
 * @param {String} contentType optional Content-Type override
 * @returns {Object} {status, headers, body, json}
 */
async function hydraAdmin(method, path, body = undefined, contentType = 'application/json') {
    const options = { method, headers: { Accept: 'application/json' } };
    if (body !== undefined) {
        options.headers['Content-Type'] = contentType;
        options.body = JSON.stringify(body);
    }

    const response = await fetch(`${hydraAdminURL}${path}`, options);
    const responseBody = await response.text();
    let json = null;
    try {
        json = JSON.parse(responseBody);
    } catch (error) {
        json = null;
    }
    return {
        status: response.status,
        headers: response.headers,
        body: responseBody,
        json,
    };
}

// Wall-clock start of this run, used to bound the log scan.
const runStartedAt = new Date();

/** Returns the combined logs of the given services since this run began. */
function serviceLogs(services = ['authapp', 'mcpapp', 'hydra', 'caddy', 'postgrest']) {
    const result = compose([
        'logs', '--no-color', '--since', runStartedAt.toISOString(), ...services,
    ]);
    return `${result.stdout || ''}${result.stderr || ''}`;
}

// Every credential and every piece of user content this run put on the wire.
// The log-scan test asserts none of it reached a service log.
const observedSecrets = new Set();

/** Records a value that must never appear in a service log. */
function recordSecret(value) {
    if (typeof value === 'string' && value.length >= 16) {
        observedSecrets.add(value);
    }
    return value;
}

/** Runs a single SQL statement inside the db container and returns raw rows. */
function sql(statement) {
    const result = compose([
        'exec', '-T', '-e', `YELUKE_SQL=${statement}`,
        'db', 'sh', '-c', 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB" -tAc "$YELUKE_SQL"',
    ]);
    if (result.status !== 0) {
        throw new Error(`sql failed: ${result.stderr || result.stdout}`);
    }
    return result.stdout.trim();
}

// ---------------------------------------------------------------------------
// dynamic client registration
// ---------------------------------------------------------------------------

// Client names this suite owns. Anything matching is fair game for the sweep.
const TEST_CLIENT_NAME = /^(yelukerest-)?e2e/;

// Every client this run creates, so cleanup can delete exactly those.
const createdClients = new Set();

function trackClient(clientId) {
    if (clientId) {
        createdClients.add(clientId);
    }
    return clientId;
}

/**
 * Lists OAuth clients through Hydra's own CLI inside the hydra container.
 * The admin API answers this one with chunked transfer encoding, which the
 * hydraAdmin() path does not decode, and the CLI is both simpler
 * and considerably faster than a socket round trip per client.
 */
function listClients() {
    const result = compose([
        'exec', '-T', 'hydra',
        'hydra', 'list', 'clients',
        '--endpoint', 'http://127.0.0.1:4445',
        '--format', 'json', '--page-size', '500',
    ]);
    if (result.status !== 0) {
        throw new Error(`could not list oauth clients: ${result.stderr || result.stdout}`);
    }
    return JSON.parse(result.stdout).items || [];
}

/** Deletes the given client ids in one call. Missing ids are not an error. */
function deleteClients(clientIds) {
    if (clientIds.length === 0) {
        return true;
    }
    const result = compose([
        'exec', '-T', 'hydra',
        'hydra', 'delete', 'oauth2-client',
        '--endpoint', 'http://127.0.0.1:4445', '--quiet',
        ...clientIds,
    ]);
    // compose() reports a failed command through its status rather than by
    // `hydra delete oauth2-client` exits 1 when an id is already gone, which
    // is the common case here (a test may have cleaned up after itself), so a
    // nonzero status is reported but NOT treated as a retryable failure.
    // Retrying on it makes the tracked set grow every cleanup until each pass
    // is deleting hundreds of missing ids — verified: that turns a two-minute
    // suite into a thirty-minute one. The sweep at the start of the next run
    // is what actually catches genuinely leaked clients.
    if (result && result.status !== 0) {
        console.warn(
            `hydra delete returned ${result.status} for ${clientIds.length} client id(s); `
            + 'already-deleted ids report this too. The next run\'s sweep will catch any leak.',
        );
    }
}

/** Deletes every client this run registered. Safe to call repeatedly. */
function cleanupClients() {
    if (createdClients.size === 0) {
        return;
    }
    try {
        deleteClients([...createdClients]);
    } catch (error) {
        console.warn(`could not delete canary clients: ${error.message}`);
    }
    createdClients.clear();
    // A later sharedClient() must register a fresh one rather than hand back
    // an id that no longer exists.
    // eslint-disable-next-line no-use-before-define
    sharedClientPromise = null;
}

/**
 * Deletes canary clients left behind by an earlier, interrupted run. It runs
 * once, before this run registers anything, so it can never remove a client
 * the current run depends on. This is what makes the suite re-runnable after
 * a crash or a Ctrl-C.
 */
let swept = false;

function sweepStaleClients() {
    if (swept) {
        return;
    }
    swept = true;
    try {
        const stale = listClients()
            .filter(entry => TEST_CLIENT_NAME.test(entry.client_name || '')
                && !createdClients.has(entry.client_id))
            .map(entry => entry.client_id);
        deleteClients(stale);
    } catch (error) {
        console.warn(`could not sweep stale canary clients: ${error.message}`);
    }
}

/**
 * Registers a client through the public DCR endpoint (/oauth2/register), i.e.
 * through authapp's response-cleaning proxy. authapp rate limits this to 10
 * registrations per minute per IP, so 429s are retried rather than failed.
 *
 * @param {Object} overrides client metadata to merge over the defaults
 * @param {Object} options {expectStatus} to assert a rejection instead
 * @returns {Object} {status, body} where body is the parsed DCR response
 */
async function registerClient(overrides = {}, options = {}) {
    sweepStaleClients();
    const payload = {
        client_name: 'yelukerest-e2e',
        redirect_uris: [LOOPBACK_REDIRECT],
        token_endpoint_auth_method: 'none',
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        scope: READ_SCOPES,
        ...overrides,
    };

    let response;
    let body;
    for (let attempt = 0; attempt < 8; attempt += 1) {
        // eslint-disable-next-line no-await-in-loop
        response = await fetch(`${baseURL}/oauth2/register`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
        });
        // eslint-disable-next-line no-await-in-loop
        const text = await response.text();
        try {
            body = JSON.parse(text);
        } catch (error) {
            body = { raw: text };
        }
        if (response.status !== 429) {
            break;
        }
        // eslint-disable-next-line no-await-in-loop
        await sleep(8000);
    }

    if (options.expectStatus === undefined && response.status >= 400) {
        throw new Error(`DCR failed with ${response.status}: ${JSON.stringify(body)}`);
    }
    if (response.status < 400) {
        trackClient(body.client_id);
    }
    return { status: response.status, body };
}

/**
 * Creates a client straight through Hydra's admin API, bypassing authapp's
 * DCR proxy and its rate limit. Used for fixtures whose registration is not
 * itself under test (short-lifespan clients, wrong-audience clients).
 */
async function adminCreateClient(spec) {
    sweepStaleClients();
    const response = await hydraAdmin('POST', '/admin/clients', spec);
    if (response.status !== 201 && response.status !== 200) {
        throw new Error(`admin client create failed (${response.status}): ${response.body}`);
    }
    trackClient(response.json.client_id);
    recordSecret(response.json.client_secret);
    return response.json;
}

// A single shared authorization-code client, so a full suite run stays well
// under authapp's 10-registrations-per-minute DCR limit.
// eslint-disable-next-line import/no-mutable-exports
let sharedClientPromise = null;

function sharedClient() {
    if (!sharedClientPromise) {
        sharedClientPromise = registerClient({
            client_name: 'yelukerest-e2e-shared',
            scope: WRITE_SCOPES,
        })
            .then(result => result.body);
    }
    return sharedClientPromise;
}

// ---------------------------------------------------------------------------
// the authorization-code dance
// ---------------------------------------------------------------------------

const baseHostname = new URL(baseURL).hostname;

/**
 * Rewrites a Location header onto the origin under test. Redirects inside the
 * deployment are emitted with the deployment's own scheme/host (the mock CAS
 * server, for instance, hands out http://localhost/cas/login), which is not
 * necessarily where the tests reach the stack when it runs on alternate ports.
 * Returns null when the target is outside the deployment.
 */
function localTarget(location) {
    if (location.startsWith('/')) {
        return `${baseURL}${location}`;
    }
    let parsed;
    try {
        parsed = new URL(location);
    } catch (error) {
        return null;
    }
    if (parsed.hostname !== baseHostname && parsed.hostname !== 'localhost') {
        return null;
    }
    return `${baseURL}${parsed.pathname}${parsed.search}`;
}

/**
 * Walks the redirect chain from /oauth2/auth to the consent page, logging in
 * through the mock CAS server as `netid` on the way.
 *
 * @param {String} authorizeURL the full /oauth2/auth URL
 * @param {String} netid the netid the mock CAS server should assert
 * @param {CookieJar} jar the browser's cookie jar
 * @returns {Promise<String>} the consent page URL
 */
async function walkToConsent(authorizeURL, netid, jar) {
    let response = await jarFetch(authorizeURL, {}, jar);
    let location = response.headers.get('location');

    for (let hop = 0; hop < 16; hop += 1) {
        if (!location) {
            throw new Error(`authorization walk stopped without a consent page (status ${response.status})`);
        }
        let next = localTarget(location);
        if (!next) {
            throw new Error(`authorization walk left the deployment origin: ${location}`);
        }
        if (next.includes('/auth/oauth/consent')) {
            return next;
        }
        if (next.includes('/cas/login') && !/[?&]id=/.test(next)) {
            // The mock CAS server takes the asserted netid as a query param.
            next += `${next.includes('?') ? '&' : '?'}id=${encodeURIComponent(netid)}`;
        }
        // eslint-disable-next-line no-await-in-loop
        response = await jarFetch(next, {}, jar);
        location = response.headers.get('location');
    }
    throw new Error('authorization walk exceeded 16 redirects');
}

function parseConsentForm(html) {
    const field = (name) => {
        const match = html.match(new RegExp(`name="${name}" value="([^"]*)"`));
        return match ? match[1] : null;
    };
    const scopes = [...html.matchAll(/name="grant_scope" value="([^"]*)"/g)].map(m => m[1]);
    return {
        csrfToken: field('csrf_token'),
        consentChallenge: field('consent_challenge'),
        scopes,
        html,
    };
}

/**
 * Follows Hydra's post-consent redirect chain until it points at the client's
 * loopback callback, and returns the parsed callback URL. Nothing listens on
 * the loopback port, so the chain is never actually fetched past that point.
 */
async function followToCallback(startLocation, jar, callbackHost) {
    let location = startLocation;
    for (let hop = 0; hop < 16; hop += 1) {
        if (!location) {
            throw new Error('consent redirect chain ended without reaching the callback');
        }
        if (location.includes(callbackHost)) {
            return new URL(location);
        }
        const next = localTarget(location);
        if (!next) {
            throw new Error(`consent redirect left the deployment origin: ${location}`);
        }
        // eslint-disable-next-line no-await-in-loop
        const response = await jarFetch(next, {}, jar);
        location = response.headers.get('location');
        if (!location && response.status >= 400) {
            const body = await response.text();
            throw new Error(`consent redirect failed with ${response.status}: ${body.slice(0, 400)}`);
        }
    }
    throw new Error('consent redirect chain exceeded 16 hops');
}

/**
 * Issues a single GET /oauth2/auth and returns the raw response, without
 * walking any redirects. Used by negative tests where the authorization
 * request is expected to be refused outright.
 */
async function authorizeRaw(params) {
    const query = new URLSearchParams(params);
    const response = await jarFetch(`${baseURL}/oauth2/auth?${query.toString()}`, {}, new CookieJar());
    return {
        status: response.status,
        location: response.headers.get('location'),
        body: await response.text(),
    };
}

/**
 * Runs a complete authorization-code + PKCE flow up to (but not including)
 * the token exchange.
 *
 * @param {Object} options flow options
 * @param {String} options.clientId registered client
 * @param {String} options.netid the netid the mock CAS server asserts
 * @param {String} options.scope requested scope string
 * @param {String} options.redirectUri the client's redirect URI
 * @param {String} options.verifier PKCE verifier (generated when absent)
 * @param {String} options.challengeMethod S256 by default
 * @param {Function} options.mutateConsentBody hook to tamper with the POST body
 * @param {Object} options.extraAuthParams extra query params on /oauth2/auth
 * @returns {Promise<Object>} {code, verifier, state, consent, callbackURL, jar}
 */
async function authorize(options) {
    const {
        clientId,
        netid,
        scope = READ_SCOPES,
        redirectUri = LOOPBACK_REDIRECT,
        challengeMethod = 'S256',
        mutateConsentBody = null,
        extraAuthParams = {},
    } = options;

    const jar = new CookieJar();
    const pkce = options.verifier
        ? {
            verifier: options.verifier,
            challenge: crypto.createHash('sha256')
                .update(options.verifier)
                .digest('base64url'),
        }
        : pkcePair();
    const state = options.state || randomState();

    const query = new URLSearchParams({
        client_id: clientId,
        response_type: 'code',
        redirect_uri: redirectUri,
        scope,
        state,
        // options.pkce === false omits the challenge entirely, which is how a
        // PKCE-downgrade attempt looks on the wire.
        ...(options.pkce === false ? {} : {
            code_challenge: challengeMethod === 'plain' ? pkce.verifier : pkce.challenge,
            code_challenge_method: challengeMethod,
        }),
        ...extraAuthParams,
    });

    const consentURL = await walkToConsent(`${baseURL}/oauth2/auth?${query.toString()}`, netid, jar);
    const consentResponse = await jarFetch(consentURL, {}, jar);
    const consentHTML = await consentResponse.text();
    const consent = parseConsentForm(consentHTML);
    consent.status = consentResponse.status;
    consent.url = consentURL;
    if (consentResponse.status !== 200) {
        return {
            consent, jar, verifier: pkce.verifier, state, code: null,
        };
    }

    const form = new URLSearchParams();
    form.set('csrf_token', consent.csrfToken);
    form.set('consent_challenge', consent.consentChallenge);
    form.set('action', 'allow');
    consent.scopes.forEach(value => form.append('grant_scope', value));
    if (mutateConsentBody) {
        mutateConsentBody(form, consent);
    }

    const decision = await jarFetch(`${baseURL}/auth/oauth/consent`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form.toString(),
    }, jar);

    if (decision.status >= 400) {
        return {
            consent,
            jar,
            verifier: pkce.verifier,
            state,
            code: null,
            decisionStatus: decision.status,
            decisionBody: await decision.text(),
        };
    }

    const callbackHost = new URL(redirectUri).host;
    const callbackURL = await followToCallback(decision.headers.get('location'), jar, callbackHost);
    recordSecret(callbackURL.searchParams.get('code'));
    return {
        code: callbackURL.searchParams.get('code'),
        callbackURL,
        consent,
        jar,
        verifier: pkce.verifier,
        state,
        decisionStatus: decision.status,
    };
}

/** POSTs to /oauth2/token and returns {status, body}. */
async function tokenRequest(params) {
    const response = await fetch(`${baseURL}/oauth2/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params)
            .toString(),
    });
    const text = await response.text();
    let body;
    try {
        body = JSON.parse(text);
    } catch (error) {
        body = { raw: text };
    }
    ['access_token', 'refresh_token', 'id_token'].forEach(field => recordSecret(body[field]));
    return { status: response.status, body };
}

function exchangeCode({
    code, clientId, redirectUri = LOOPBACK_REDIRECT, verifier, clientSecret,
}) {
    const params = {
        grant_type: 'authorization_code',
        code,
        client_id: clientId,
        redirect_uri: redirectUri,
    };
    if (verifier !== undefined) {
        params.code_verifier = verifier;
    }
    if (clientSecret) {
        params.client_secret = clientSecret;
    }
    return tokenRequest(params);
}

function refreshToken({ refresh_token: token, clientId, clientSecret }) {
    const params = { grant_type: 'refresh_token', refresh_token: token, client_id: clientId };
    if (clientSecret) {
        params.client_secret = clientSecret;
    }
    return tokenRequest(params);
}

/**
 * The whole flow in one call: authorize, consent, exchange. Returns the token
 * endpoint response plus the intermediate artifacts.
 */
async function fullFlow(options) {
    const flow = await authorize(options);
    if (!flow.code) {
        throw new Error(`authorization flow produced no code (consent status ${flow.consent.status}, decision status ${flow.decisionStatus})`);
    }
    const tokens = await exchangeCode({
        code: flow.code,
        clientId: options.clientId,
        redirectUri: options.redirectUri || LOOPBACK_REDIRECT,
        verifier: flow.verifier,
        clientSecret: options.clientSecret,
    });
    if (tokens.status !== 200) {
        throw new Error(`token exchange failed (${tokens.status}): ${JSON.stringify(tokens.body)}`);
    }
    return { ...flow, tokens: tokens.body };
}

// ---------------------------------------------------------------------------
// MCP client
// ---------------------------------------------------------------------------

const LATEST_PROTOCOL = '2026-07-28';
const LEGACY_PROTOCOL = '2025-11-25';

/** Parses a streamable-HTTP response body: either JSON or an SSE stream. */
function parseMCPBody(contentType, text) {
    if ((contentType || '').includes('text/event-stream')) {
        const messages = text.split('\n')
            .filter(line => line.startsWith('data:'))
            .map(line => JSON.parse(line.slice(5)
                .trim()));
        return messages.length === 1 ? messages[0] : messages;
    }
    if (!text) {
        return null;
    }
    return JSON.parse(text);
}

class McpClient {
    /**
     * @param {String} accessToken bearer token, or null for anonymous calls
     * @param {Object} options {protocolVersion, capabilities, url}
     */
    constructor(accessToken, options = {}) {
        this.accessToken = accessToken;
        // The deployed handler is stateless, which speaks BOTH eras: legacy
        // clients still get the `initialize` handshake they expect (this
        // client's default, since that is what real clients send today), and
        // 2026-07-28 is available to anything that asks for it. What a
        // stateless server does not do is issue an Mcp-Session-Id, so this
        // client works with or without one.
        this.protocolVersion = options.protocolVersion || LEGACY_PROTOCOL;
        this.capabilities = options.capabilities || {};
        this.url = options.url || mcpURL;
        this.sessionId = null;
        this.negotiatedVersion = null;
        this.nextId = 1;
    }

    headers() {
        const headers = {
            'Content-Type': 'application/json',
            Accept: 'application/json, text/event-stream',
        };
        if (this.accessToken) {
            headers.Authorization = `Bearer ${this.accessToken}`;
        }
        if (this.sessionId) {
            headers['Mcp-Session-Id'] = this.sessionId;
        }
        if (this.negotiatedVersion) {
            headers['Mcp-Protocol-Version'] = this.negotiatedVersion;
        }
        return headers;
    }

    /**
     * POSTs to /mcp, retrying while the server rate limits us.
     *
     * mcpapp limits authenticated traffic to 120 requests per minute per token
     * subject (mcpapp/security.go). Every student session in this suite shares
     * one subject, so a full run brushes that limit; a 429 is back-pressure,
     * not a result. Retrying matters most for the elicitation answer: if that
     * POST is dropped, the tool call it answers waits forever.
     */
    async fetchWithBackoff(payload, init = {}) {
        let response;
        for (let attempt = 0; attempt < 25; attempt += 1) {
            // eslint-disable-next-line no-await-in-loop
            response = await fetch(this.url, {
                method: 'POST',
                headers: this.headers(),
                body: JSON.stringify(payload),
                ...init,
            });
            if (response.status !== 429) {
                return response;
            }
            // eslint-disable-next-line no-await-in-loop
            await response.text();
            // eslint-disable-next-line no-await-in-loop
            await sleep(3000);
        }
        return response;
    }

    /** Sends one JSON-RPC message and returns {status, headers, message}. */
    async post(payload) {
        const response = await this.fetchWithBackoff(payload);
        const text = await response.text();
        let message = null;
        if (response.status < 400 || (response.headers.get('content-type') || '').includes('json')) {
            try {
                message = parseMCPBody(response.headers.get('content-type'), text);
            } catch (error) {
                message = { parseError: error.message, raw: text };
            }
        }
        return {
            status: response.status,
            headers: response.headers,
            message,
            text,
        };
    }

    async initialize() {
        const response = await this.post({
            jsonrpc: '2.0',
            id: this.nextId++,
            method: 'initialize',
            params: {
                protocolVersion: this.protocolVersion,
                capabilities: this.capabilities,
                clientInfo: { name: 'yelukerest-e2e', version: '1.0.0' },
            },
        });
        if (response.status !== 200) {
            return response;
        }
        this.sessionId = response.headers.get('mcp-session-id');
        this.negotiatedVersion = response.message
            && response.message.result
            && response.message.result.protocolVersion;
        await this.post({ jsonrpc: '2.0', method: 'notifications/initialized' });
        return response;
    }

    async request(method, params = {}) {
        const response = await this.post({
            jsonrpc: '2.0', id: this.nextId++, method, params,
        });
        return response;
    }

    async listTools() {
        const response = await this.request('tools/list');
        return response.message.result.tools;
    }

    /** Calls a tool and returns the raw JSON-RPC message. */
    async callRaw(name, args = {}, extraParams = {}) {
        const response = await this.request('tools/call', {
            name, arguments: args, ...extraParams,
        });
        return response;
    }

    /** Calls a tool, asserting no protocol-level error, and returns result. */
    async call(name, args = {}, extraParams = {}) {
        const response = await this.callRaw(name, args, extraParams);
        if (!response.message || !response.message.result) {
            throw new Error(`tools/call ${name} failed: ${JSON.stringify(response.message || response.text)}`);
        }
        return response.message.result;
    }

    /** Calls a tool and returns its structuredContent, failing on tool errors. */
    async callOk(name, args = {}, extraParams = {}) {
        const result = await this.call(name, args, extraParams);
        if (result.isError) {
            throw new Error(`tool ${name} returned an error: ${JSON.stringify(result.content)}`);
        }
        return result.structuredContent;
    }

    /**
     * Calls a tool while answering any server-initiated elicitation request
     * that arrives on the call's SSE stream.
     *
     * The server-side multi-round-trip middleware fulfills a handler's
     * InputRequests by issuing an `elicitation/create` JSON-RPC REQUEST to the
     * client over the streaming response of this very POST; the client answers
     * with a separate POST carrying the JSON-RPC response, and the final tool
     * result then arrives on the original stream. That is the only elicitation
     * path available on a stateful (non-MCP_STATELESS_ENABLED) deployment,
     * because the newer client-retry mechanism (params.inputResponses) is only
     * reachable on 2026-07-28 sessions, which require stateless mode.
     *
     * @param {String} name tool name
     * @param {Object} args tool arguments
     * @param {Object} answer the ElicitResult to return, e.g.
     *                        {action:'accept', content:{confirm:true}}
     * @returns {Promise<Object>} {result, elicitations}
     */
    async callAnsweringElicitation(name, args = {}, answer = { action: 'accept', content: { confirm: true } }) {
        const id = this.nextId++;
        // Bound the whole exchange: if the server never sends the final
        // result, fail with a clear error rather than hanging the test.
        const controller = new AbortController();
        const abortTimer = setTimeout(() => controller.abort(), 90_000);
        const response = await this.fetchWithBackoff({
            jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args },
        }, { signal: controller.signal });
        if (response.status !== 200 || !response.body) {
            clearTimeout(abortTimer);
            return { status: response.status, result: null, elicitations: [] };
        }

        const elicitations = [];
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        // The stream is always drained to completion rather than cancelled
        // once the result arrives: cancelling a response body mid-stream
        // leaves the pooled HTTP connection in a state that makes the NEXT
        // elicitation exchange on this session hang.
        let outcome = null;
        try {
            for (;;) {
                // eslint-disable-next-line no-await-in-loop
                const { done, value } = await reader.read();
                if (done) {
                    break;
                }
                buffer += decoder.decode(value, { stream: true });
                let boundary = buffer.indexOf('\n\n');
                while (boundary >= 0) {
                    const event = buffer.slice(0, boundary);
                    buffer = buffer.slice(boundary + 2);
                    const data = event.split('\n')
                        .filter(line => line.startsWith('data:'))
                        .map(line => line.slice(5)
                            .trim())
                        .join('\n');
                    if (data) {
                        const message = JSON.parse(data);
                        if (message.method && message.id !== undefined) {
                            elicitations.push(message);
                            // eslint-disable-next-line no-await-in-loop
                            const answered = await this.post({
                                jsonrpc: '2.0', id: message.id, result: answer,
                            });
                            if (answered.status >= 400) {
                                throw new Error(`the elicitation answer was refused with HTTP ${answered.status}`);
                            }
                        } else if (message.id === id) {
                            outcome = {
                                status: 200,
                                result: message.result,
                                error: message.error,
                                elicitations,
                            };
                        }
                    }
                    boundary = buffer.indexOf('\n\n');
                }
            }
        } finally {
            clearTimeout(abortTimer);
        }
        return outcome || { status: 200, result: null, elicitations };
    }

    /** Calls a tool expecting a tool-level error; returns the error text. */
    async callExpectError(name, args = {}, extraParams = {}) {
        const result = await this.call(name, args, extraParams);
        if (!result.isError) {
            throw new Error(`tool ${name} unexpectedly succeeded: ${JSON.stringify(result.structuredContent)}`);
        }
        return (result.content || []).map(part => part.text || '')
            .join(' ');
    }

    async close() {
        // A stateless server issues no session and answers DELETE with 405,
        // so there is nothing to tear down. Only bother when a session was
        // actually assigned (the stateful fallback).
        if (!this.sessionId) {
            return;
        }
        try {
            await fetch(this.url, { method: 'DELETE', headers: this.headers() });
        } catch (error) {
            // best effort
        }
    }
}

/** Convenience: authorized MCP client for a netid, with the shared client. */
async function mcpClientFor(netid, { scope = READ_SCOPES, capabilities = {}, protocolVersion } = {}) {
    const client = await sharedClient();
    const flow = await fullFlow({ clientId: client.client_id, netid, scope });
    const mcp = new McpClient(flow.tokens.access_token, { capabilities, protocolVersion });
    await mcp.initialize();
    return { mcp, tokens: flow.tokens, client };
}

module.exports = {
    baseURL,
    mcpURL,
    issuer,
    NETIDS,
    LOOPBACK_PORT,
    LOOPBACK_REDIRECT,
    READ_SCOPES,
    WRITE_SCOPES,
    LATEST_PROTOCOL,
    LEGACY_PROTOCOL,
    compose,
    sleep,
    decodeJWT,
    pkcePair,
    randomState,
    CookieJar,
    jarFetch,
    hydraAdmin,
    sql,
    serviceLogs,
    observedSecrets,
    recordSecret,
    registerClient,
    adminCreateClient,
    sharedClient,
    trackClient,
    listClients,
    deleteClients,
    cleanupClients,
    sweepStaleClients,
    authorize,
    authorizeRaw,
    walkToConsent,
    parseConsentForm,
    tokenRequest,
    exchangeCode,
    refreshToken,
    fullFlow,
    McpClient,
    mcpClientFor,
};
