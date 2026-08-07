/* global describe it before after */

// Group 8: connected applications — seeing what has access, and taking it back
// (issue #277).
//
// The thing worth testing here is that "disconnect" is not cosmetic. Revoking
// consent at Hydra kills the refresh token at once, but the access token the
// application is already holding keeps verifying offline against the JWKS, so
// on its own that leaves up to an hour of working access behind. What closes
// the gap is that mcpapp must exchange that token for a short internal
// credential every ten minutes, and the database refuses once a disconnect is
// on record.
//
// So the tests below assert both halves and the seam between them: refresh
// dies immediately, the already-issued token stops working once the cached
// internal credential is gone, and — the part that makes this usable rather
// than a trap — reconnecting works.
//
// mcpapp is restarted where a test needs the cached credential gone. That is
// standing in for the clock: the cache entry expires with the internal token
// it holds, inside ten minutes, and waiting that out in a test would be silly.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    READ_SCOPES,
    WRITE_SCOPES,
    baseURL,
    sharedClient,
    registerClient,
    authorize,
    exchangeCode,
    refreshToken,
    jarFetch,
    McpClient,
    mcpURL,
    compose,
    sleep,
    sql,
} = require('./helpers.js');

bunTest.setDefaultTimeout(240_000);

const connectedAppsURL = `${baseURL}/auth/connected-apps`;

/**
 * Authorizes a client and returns {tokens, jar, clientId}.
 *
 * Every test that disconnects gets its OWN client. A revocation is recorded
 * per (user, client) and carries a few seconds of clock-skew allowance, so
 * tests sharing one client would refuse each other's reconnections purely
 * because a test suite reconnects faster than a person ever would. Passing an
 * existing client is how a test reconnects the same application deliberately.
 */
async function connect(options = {}) {
    const {
        netid = NETIDS.student,
        scope = READ_SCOPES,
        client = null,
    } = options;
    // registerClient returns the HTTP result; the client is its body.
    const useClient = client || (await registerClient({ scope: WRITE_SCOPES })).body;
    const auth = await authorize({ clientId: useClient.client_id, netid, scope });
    const exchanged = await exchangeCode({
        code: auth.code, verifier: auth.verifier, clientId: useClient.client_id,
    });
    return {
        tokens: exchanged.body,
        jar: auth.jar,
        clientId: useClient.client_id,
        client: useClient,
    };
}

/** Reads the page and returns its CSRF token. */
async function csrfToken(jar) {
    const response = await jarFetch(connectedAppsURL, {}, jar);
    const html = await response.text();
    const match = html.match(/name="csrf_token" value="([^"]+)"/);
    expect(match, 'the page carried no CSRF token').to.not.equal(null);
    return match[1];
}

async function disconnect(jar, clientId, token) {
    return jarFetch(connectedAppsURL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            csrf_token: token, client_id: clientId,
        }).toString(),
        redirect: 'manual',
    }, jar);
}

/**
 * Drops mcpapp's exchange cache, standing in for the ten minutes the cached
 * internal credential would otherwise take to expire on its own.
 */
function expireCachedCredentials() {
    compose(['restart', 'mcpapp']);
}

/** Waits until mcpapp answers again after a restart. */
async function waitForMcp() {
    for (let attempt = 0; attempt < 60; attempt += 1) {
        try {
            // eslint-disable-next-line no-await-in-loop
            const response = await fetch(mcpURL, { method: 'POST' });
            await response.text();
            // 401 is mcpapp itself answering an unauthenticated POST. A 502
            // is Caddy saying it cannot reach mcpapp yet, which is exactly
            // the race this waits out.
            if (response.status === 401) {
                return;
            }
        } catch (error) {
            // not listening yet
        }
        // eslint-disable-next-line no-await-in-loop
        await sleep(500);
    }
    throw new Error('mcpapp did not come back after a restart');
}

async function callWhoami(accessToken) {
    await waitForMcp();
    const mcp = new McpClient(accessToken);
    await mcp.initialize();
    const response = await mcp.callRaw('whoami');
    const result = response.message && response.message.result;
    // A transport failure must not read as "the tool call succeeded"; that
    // would turn a restart race into a silent pass on the assertions below.
    if (!result) {
        throw new Error(
            `whoami returned no result (HTTP ${response.status}): ${JSON.stringify(response.message)}`,
        );
    }
    return {
        isError: Boolean(result && result.isError),
        text: result ? (result.content || []).map(part => part.text || '').join(' ') : '',
        netid: result && result.structuredContent ? result.structuredContent.netid : null,
    };
}

function revocationRows(clientId) {
    const rows = sql(
        'select client_id from data.mcp_grant_revocation '
        + `where client_id = '${clientId}' order by id`,
    );
    return rows === '' ? [] : rows.split('\n');
}

describe('connected applications', () => {
    after(() => {
        // Nothing to undo, and that is worth stating: the rows this file
        // leaves behind are append-only by design and cannot be deleted, but
        // they also cannot poison the rest of the suite. A revocation only
        // refuses tokens issued before it, so every later file's fresh
        // authorization mints normally. The cache is dropped so no credential
        // issued here outlives the file.
        expireCachedCredentials();
    });

    describe('listing', () => {
        it('should refuse an unauthenticated caller', async () => {
            const response = await fetch(connectedAppsURL);
            expect(response.status)
                .to.equal(401);
        });

        it('should show the application a student authorized', async () => {
            const session = await connect();
            const response = await jarFetch(connectedAppsURL, {
                headers: { Accept: 'application/json' },
            }, session.jar);
            expect(response.status)
                .to.equal(200);
            const body = await response.json();
            const app = (body.connected_apps || [])
                .find(entry => entry.client_id === session.clientId);
            expect(app, 'the authorized client was not listed')
                .to.not.equal(undefined);
            // The person needs to recognise it and know what it can reach.
            expect(app.client_name)
                .to.be.a('string')
                .with.length.greaterThan(0);
            expect(app.scopes)
                .to.contain('course:read');
            expect(app.last_activity)
                .to.be.a('string');
        });
    });

    describe('the shape the single-page client depends on', () => {
        // ConnectedApps.Model decodes exactly these fields, and its own tests
        // pin the client half. This is the server half: a rename here would
        // otherwise break the Elm page silently, since a decoder failure looks
        // like an empty list.
        it('should carry a csrf token and the fields the decoder requires', async () => {
            const session = await connect();
            const response = await jarFetch(connectedAppsURL, {
                headers: { Accept: 'application/json' },
            }, session.jar);
            const body = await response.json();

            expect(body.csrf_token, 'the page cannot post a disconnect without this')
                .to.be.a('string')
                .with.length.greaterThan(16);
            const app = body.connected_apps.find(entry => entry.client_id === session.clientId);
            expect(Object.keys(app).sort())
                .to.include.members(['client_id', 'client_name', 'last_activity', 'scopes']);
            expect(app.scopes)
                .to.be.an('array');
        });

        it('should accept the disconnect the client actually sends', async () => {
            // Form-encoded body with Accept: application/json, which is what
            // ConnectedApps.Commands builds. The HTML form path is covered
            // below; this is the other caller.
            const session = await connect();
            const listed = await jarFetch(connectedAppsURL, {
                headers: { Accept: 'application/json' },
            }, session.jar);
            const { csrf_token: token } = await listed.json();

            const response = await jarFetch(connectedAppsURL, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                    Accept: 'application/json',
                },
                body: new URLSearchParams({
                    csrf_token: token, client_id: session.clientId,
                }).toString(),
            }, session.jar);
            expect(response.status)
                .to.equal(200);
            expect(await response.json())
                .to.have.property('disconnected', session.clientId);
        });
    });

    describe('disconnecting', () => {
        it('should refuse a POST with a bad CSRF token, and revoke nothing', async () => {
            const session = await connect();
            const before = revocationRows(session.clientId);
            const response = await disconnect(session.jar, session.clientId, 'not-the-token');
            expect(response.status)
                .to.equal(403);
            expect(revocationRows(session.clientId))
                .to.deep.equal(before);
        });

        it('should refuse to disconnect an application the caller has not authorized', async () => {
            // Otherwise a forged form could record a revocation naming any
            // client at all, and the details written to the audit trail would
            // be whatever the attacker typed.
            const session = await connect();
            const token = await csrfToken(session.jar);
            const response = await disconnect(session.jar, 'some-client-that-is-not-connected', token);
            expect(response.status)
                .to.equal(404);
        });

        it('should sever access and leave an audit row', async () => {
            const session = await connect();

            // It works before, or the rest of this proves nothing.
            const before = await callWhoami(session.tokens.access_token);
            expect(before.netid)
                .to.equal(NETIDS.student);

            const token = await csrfToken(session.jar);
            const response = await disconnect(session.jar, session.clientId, token);
            expect(response.status)
                .to.equal(303);

            // The audit row, carrying what the grant could reach when it was cut.
            const recorded = sql(
                'select netid, client_id, scopes from data.mcp_grant_revocation '
                + `where client_id = '${session.clientId}' order by id desc limit 1`,
            );
            expect(recorded)
                .to.contain(NETIDS.student);
            expect(recorded)
                .to.contain('course:read');

            // Refresh dies immediately: the application cannot mint itself a
            // new access token.
            const refreshed = await refreshToken({
                refresh_token: session.tokens.refresh_token,
                clientId: session.clientId,
            });
            expect(refreshed.status)
                .to.equal(400);
            expect(refreshed.body.error)
                .to.equal('invalid_grant');

            // The access token it already holds is still a valid signature, so
            // this is the half that needs the database: once the cached
            // internal credential is gone, no new one is issued.
            expireCachedCredentials();
            const after = await callWhoami(session.tokens.access_token);
            expect(after.isError, 'a disconnected application still reached course data')
                .to.equal(true);
            expect(after.text)
                .to.contain('disconnected');
        });

        it('should let the student reconnect afterwards', async () => {
            // Without this, disconnecting would be a one-way door: the record
            // is permanent, so the mint check compares it against the token's
            // issued-at rather than merely asking whether a record exists.
            const session = await connect();
            const token = await csrfToken(session.jar);
            expect((await disconnect(session.jar, session.clientId, token)).status)
                .to.equal(303);
            expireCachedCredentials();
            expect((await callWhoami(session.tokens.access_token)).isError)
                .to.equal(true);

            // A fresh authorization: a new grant, and a token issued after the
            // revocation. The pause is not incidental — OAuth's iat has
            // one-second granularity, and the check deliberately treats a
            // token issued in the same second as the revocation as revoked,
            // so a reconnection has to land in a later second. A person
            // clicking through CAS and a consent screen always does; this
            // test is faster than a person.
            // Long enough to clear the five-second clock-skew allowance the
            // mint check applies (see api.issue_user_jwt_for_mcp). A person
            // clicking through CAS and consent always takes longer.
            await new Promise((resolve) => { setTimeout(resolve, 6000); });
            const again = await connect({ client: session.client });
            expireCachedCredentials();
            const after = await callWhoami(again.tokens.access_token);
            expect(after.isError, 'a reconnected application was still refused')
                .to.equal(false);
            expect(after.netid)
                .to.equal(NETIDS.student);
        });
    });
});
