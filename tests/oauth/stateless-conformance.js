/* global describe it before */

// Group 7: the wire, in both protocol eras (issue #278).
//
// The server runs the stateless handler, and that is what makes it dual-era:
// the transport accepts every legacy protocol version either way, but
// 2026-07-28 is only offered when it is stateless. So one deployment answers
// both the clients that exist today (legacy `initialize` handshake) and the
// clients that are coming (per-request metadata, no session at all).
//
// These tests speak raw HTTP rather than going through McpClient, because what
// is being checked IS the transport: which headers are required of whom, what
// a session id is (and is not) issued for, and which failures come back as
// which status code. A helper that smoothed those over would test itself.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    READ_SCOPES,
    LATEST_PROTOCOL,
    LEGACY_PROTOCOL,
    mcpURL,
    sharedClient,
    fullFlow,
    McpClient,
} = require('./helpers.js');

bunTest.setDefaultTimeout(120_000);

/** The per-request metadata every 2026-07-28 request carries in params._meta. */
function meta() {
    return {
        'io.modelcontextprotocol/protocolVersion': LATEST_PROTOCOL,
        'io.modelcontextprotocol/clientInfo': { name: 'yelukerest-conformance', version: '1.0.0' },
        'io.modelcontextprotocol/clientCapabilities': {},
    };
}

describe('transport conformance', () => {
    let token;

    before(async () => {
        const client = await sharedClient();
        const flow = await fullFlow({
            clientId: client.client_id, netid: NETIDS.student, scope: READ_SCOPES,
        });
        token = flow.tokens.access_token;
    });

    /**
     * One 2026-07-28 POST. Headers are derived from the body by default, which
     * is what a conforming client does; overrides let a test disagree with its
     * own body on purpose.
     */
    async function modern(body, headerOverrides = {}, { bearer = true } = {}) {
        const headers = {
            'Content-Type': 'application/json',
            Accept: 'application/json, text/event-stream',
            'MCP-Protocol-Version': LATEST_PROTOCOL,
            'Mcp-Method': body.method,
            ...(body.params && body.params.name ? { 'Mcp-Name': body.params.name } : {}),
            ...headerOverrides,
        };
        if (bearer) {
            headers.Authorization = `Bearer ${token}`;
        }
        const response = await fetch(mcpURL, {
            method: 'POST', headers, body: JSON.stringify(body),
        });
        const text = await response.text();
        // A 2026 response may be a single JSON object or a one-event stream.
        // Transport-level rejections (a 401 before any JSON-RPC handling) are
        // plain text, so parsing is best effort and the status carries the
        // meaning in those cases.
        const encoded = text.startsWith('event:')
            ? text.split('\n')
                .filter(line => line.startsWith('data:'))
                .map(line => line.slice(5)
                    .trim())
                .join('\n')
            : text;
        let payload = null;
        try {
            payload = encoded ? JSON.parse(encoded) : null;
        } catch (error) {
            payload = null;
        }
        return {
            status: response.status,
            sessionId: response.headers.get('mcp-session-id'),
            wwwAuthenticate: response.headers.get('www-authenticate'),
            payload,
        };
    }

    describe('the 2026-07-28 era', () => {
        it('should serve tools/list with no handshake and no session', async () => {
            const response = await modern({
                jsonrpc: '2.0', id: 1, method: 'tools/list', params: { _meta: meta() },
            });
            expect(response.status)
                .to.equal(200);
            // The whole point of the era: no session is negotiated, so none is
            // issued, and nothing has to be torn down.
            expect(response.sessionId, 'a stateless server must not assign a session')
                .to.equal(null);
            expect(response.payload.result.tools)
                .to.be.an('array')
                .with.length.greaterThan(0);
        });

        it('should tag list results with resultType and cache metadata', async () => {
            const response = await modern({
                jsonrpc: '2.0', id: 2, method: 'tools/list', params: { _meta: meta() },
            });
            const { result } = response.payload;
            expect(result.resultType)
                .to.equal('complete');
            expect(result, 'lists carry a cache hint in this era')
                .to.have.property('ttlMs');
            expect(result.cacheScope)
                .to.be.a('string');
        });

        it('should run a tool under the caller\'s own identity', async () => {
            // Not just transport plumbing: the credential still resolves to a
            // real student, so authorization survives losing the session.
            const response = await modern({
                jsonrpc: '2.0',
                id: 3,
                method: 'tools/call',
                params: { name: 'whoami', arguments: {}, _meta: meta() },
            });
            expect(response.status)
                .to.equal(200);
            expect(response.payload.result.structuredContent.netid)
                .to.equal(NETIDS.student);
        });

        it('should still require a bearer token', async () => {
            const response = await modern({
                jsonrpc: '2.0', id: 4, method: 'tools/list', params: { _meta: meta() },
            }, {}, { bearer: false });
            expect(response.status)
                .to.equal(401);
            // The RFC 9728 pointer has to survive the era change, or a client
            // has no way to discover where to authenticate.
            expect(response.wwwAuthenticate)
                .to.contain('resource_metadata');
        });

        for (const [label, overrides, body] of [
            [
                'Mcp-Name disagrees with the body',
                { 'Mcp-Name': 'list_meetings' },
                {
                    jsonrpc: '2.0',
                    id: 5,
                    method: 'tools/call',
                    params: { name: 'whoami', arguments: {}, _meta: meta() },
                },
            ],
            [
                'Mcp-Method disagrees with the body',
                { 'Mcp-Method': 'tools/list' },
                {
                    jsonrpc: '2.0',
                    id: 6,
                    method: 'tools/call',
                    params: { name: 'whoami', arguments: {}, _meta: meta() },
                },
            ],
        ]) {
            it(`should reject a request where the ${label}`, async () => {
                // Headers are mirrored so intermediaries can route without
                // parsing the body; if the two disagree, a load balancer and
                // the server could act on different values, so the spec makes
                // it a hard error rather than picking a winner.
                const response = await modern(body, overrides);
                expect(response.status)
                    .to.equal(400);
                expect(response.payload.error.code, 'HeaderMismatch')
                    .to.equal(-32020);
            });
        }

        it('should answer an unknown method with 404 and -32601', async () => {
            const response = await modern({
                jsonrpc: '2.0', id: 7, method: 'nonesuch/method', params: { _meta: meta() },
            });
            expect(response.status)
                .to.equal(404);
            expect(response.payload.error.code)
                .to.equal(-32601);
        });

        for (const method of ['GET', 'DELETE']) {
            it(`should answer ${method} with 405 and an Allow header`, async () => {
                // The GET stream and the DELETE teardown both belong to the
                // session model this era removed.
                const response = await fetch(mcpURL, {
                    method,
                    headers: {
                        Authorization: `Bearer ${token}`,
                        Accept: 'application/json, text/event-stream',
                    },
                });
                expect(response.status)
                    .to.equal(405);
                expect(response.headers.get('allow'))
                    .to.contain('POST');
            });
        }
    });

    describe('the legacy era, unchanged', () => {
        it('should still complete the initialize handshake', async () => {
            const mcp = new McpClient(token, { protocolVersion: LEGACY_PROTOCOL });
            const handshake = await mcp.initialize();
            expect(handshake.status)
                .to.equal(200);
            expect(handshake.message.result.protocolVersion)
                .to.equal(LEGACY_PROTOCOL);
            await mcp.close();
        });

        it('should not demand the 2026 headers of a legacy client', async () => {
            // A legacy client sends no Mcp-Method, no Mcp-Name, and no
            // per-request _meta. Requiring any of those would break every
            // client that exists today.
            const response = await fetch(mcpURL, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    Accept: 'application/json, text/event-stream',
                    Authorization: `Bearer ${token}`,
                },
                body: JSON.stringify({
                    jsonrpc: '2.0',
                    id: 1,
                    method: 'initialize',
                    params: {
                        protocolVersion: LEGACY_PROTOCOL,
                        capabilities: {},
                        clientInfo: { name: 'legacy-probe', version: '1.0.0' },
                    },
                }),
            });
            expect(response.status)
                .to.equal(200);
            await response.text();
        });

        it('should serve tools to a legacy client with no session id', async () => {
            // Stateless means the server assigns no session even to a client
            // that would happily use one. Nothing in our tools carries state
            // between calls, so there is nothing for a session to hold.
            const mcp = new McpClient(token, { protocolVersion: LEGACY_PROTOCOL });
            await mcp.initialize();
            expect(mcp.sessionId, 'a stateless server assigns no session')
                .to.equal(null);
            const tools = await mcp.listTools();
            expect(tools.map(tool => tool.name))
                .to.contain('whoami');
            await mcp.close();
        });
    });
});
