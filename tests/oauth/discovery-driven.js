// A client that knows NOTHING but the MCP URL.
//
// Every other file here registers with `scope: READ_SCOPES` — the course scopes
// passed by name. A real MCP client cannot do that. Claude Code is given one
// URL and has to discover the rest: it calls /mcp, reads the RFC 9728 pointer
// out of the 401, fetches the resource metadata, finds the authorization
// server, registers, and asks for whatever scopes it was told exist.
//
// Because the suite always supplied the scope list itself, it sailed straight
// past a real break: Hydra's DCR default_scope was openid and offline_access
// only, and scopes_supported was missing from the resource metadata, so a
// genuine client could not learn that course:read existed. The whole dance then
// completed — 401, metadata, consent, token — and every tool call was denied
// with "the OAuth access token granted no yelukerest scopes". The student did
// everything right and nothing looked broken.
//
// So these tests are deliberately written the hard way: nothing may be taken
// from helpers.js that a client could not have discovered for itself.

const { describe, it, expect, beforeAll, afterAll } = require('bun:test');
const {
    mcpURL,
    NETIDS,
    LOOPBACK_REDIRECT,
    decodeJWT,
    authorize,
    exchangeCode,
    registerClient,
    trackClient,
    cleanupClients,
    McpClient,
} = require('./helpers.js');

describe('a client that starts from only the MCP URL', () => {
    // Everything below is filled in by walking the chain, never hardcoded.
    let unauthenticated;
    let resourceMetadata;
    let authServerMetadata;
    let discoveredScopes;
    let requestedScopes;
    let client;
    let authFlow;
    let tokenResponse;

    // The entire walk runs once here rather than test-by-test. Registration
    // goes through authapp's DCR rate limit (10/minute), which the rest of the
    // suite dodges by sharing one client; this file cannot, because
    // registering without a scope parameter IS what it tests. Doing it once and
    // asserting afterwards keeps that cost to a single request and makes a
    // rate-limited run fail in one obvious place.
    beforeAll(async () => {
        const res = await fetch(mcpURL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
        });
        unauthenticated = { status: res.status, challenge: res.headers.get('www-authenticate') };

        const metadataURL = /resource_metadata="([^"]+)"/.exec(unauthenticated.challenge)[1];
        const prm = await fetch(metadataURL);
        resourceMetadata = { status: prm.status, body: await prm.json() };
        discoveredScopes = resourceMetadata.body.scopes_supported || [];

        const as = await fetch(
            `${resourceMetadata.body.authorization_servers[0]}/.well-known/oauth-authorization-server`);
        authServerMetadata = { status: as.status, body: await as.json() };

        const registered = await registerClient({
            client_name: 'discovery-driven-e2e',
            grant_types: ['authorization_code', 'refresh_token'],
            response_types: ['code'],
            redirect_uris: [LOOPBACK_REDIRECT],
            token_endpoint_auth_method: 'none',
        });
        client = registered.body;
        trackClient(client.client_id);

        const requested = discoveredScopes.filter(s => s !== 'submissions:write').join(' ');
        requestedScopes = requested;
        const flow = await authorize({
            clientId: client.client_id, netid: NETIDS.student, scope: requested,
        });
        authFlow = flow;
        if (flow.code) {
            const exchanged = await exchangeCode({
                clientId: client.client_id, code: flow.code, verifier: flow.verifier,
            });
            tokenResponse = exchanged;
        }
    });

    afterAll(async () => {
        await cleanupClients();
    });

    describe('step 1: the unauthenticated call has to say where to go', () => {
        it('answers 401 with an RFC 9728 resource_metadata pointer', () => {
            expect(unauthenticated.status).toBe(401);
            expect(unauthenticated.challenge).toBeTruthy();
            // Without this the client has nowhere to go and the story ends.
            expect(unauthenticated.challenge).toContain('resource_metadata=');
        });
    });

    describe('step 2: the resource metadata', () => {
        it('is fetchable and describes this resource', () => {
            expect(resourceMetadata.status).toBe(200);
            expect(resourceMetadata.body.resource).toBe(mcpURL);
        });

        it('names an authorization server', () => {
            expect(Array.isArray(resourceMetadata.body.authorization_servers)).toBe(true);
            expect(resourceMetadata.body.authorization_servers.length).toBeGreaterThan(0);
        });

        // The assertion that would have caught the outage.
        it('advertises the course scopes, so a client can know to ask', () => {
            expect(Array.isArray(discoveredScopes)).toBe(true);
            for (const required of ['course:read', 'grades:read', 'submissions:read']) {
                expect(discoveredScopes).toContain(required);
            }
        });
    });

    describe('step 3: the authorization server metadata', () => {
        it('offers registration and PKCE with S256', () => {
            expect(authServerMetadata.status).toBe(200);
            expect(authServerMetadata.body.registration_endpoint).toBeTruthy();
            expect(authServerMetadata.body.authorization_endpoint).toBeTruthy();
            expect(authServerMetadata.body.token_endpoint).toBeTruthy();
            expect(authServerMetadata.body.code_challenge_methods_supported).toContain('S256');
        });
    });

    describe('step 4: registration', () => {
        it('grants the course scopes to a client that asked for nothing', () => {
            // No `scope` field was sent. A client that has just discovered this
            // server has no reason to send one, and that is exactly where the
            // break was: Hydra handed back "openid offline_access" and the
            // client was quietly stuck with it.
            expect(client.client_id).toBeTruthy();
            const granted = (client.scope || '').split(' ');
            for (const required of ['course:read', 'grades:read', 'submissions:read']) {
                expect(granted).toContain(required);
            }
        });
    });

    describe('step 5: the browser dance, then real tool calls', () => {
        it('completes CAS login and consent, and returns a code', () => {
            expect(authFlow.code).toBeTruthy();
        });

        it('exchanges that code for an access token', () => {
            expect(tokenResponse.status).toBe(200);
            expect(tokenResponse.body.access_token).toBeTruthy();
        });

        it('mints an access token carrying exactly the requested scopes', () => {
            const claims = decodeJWT(tokenResponse.body.access_token);
            const scopes = (claims.scopes || claims.scp || claims.scope || '').toString();
            for (const required of ['course:read', 'grades:read', 'submissions:read']) {
                expect(scopes).toContain(required);
            }
            // Advertised so a client could ask; this one did not, so it must
            // not be present. That boundary is what makes a read-only
            // connection mean something.
            expect(requestedScopes).not.toContain('submissions:write');
            expect(scopes).not.toContain('submissions:write');
        });

        // The end of the story, and the only part a student actually notices:
        // after connecting, do the tools work?
        it('answers a real tool call with real data', async () => {
            const mcp = new McpClient(tokenResponse.body.access_token);
            await mcp.initialize();
            const tools = await mcp.listTools();
            expect(tools.length).toBeGreaterThan(0);

            const result = await mcp.call('whoami', {});
            const text = JSON.stringify(result);
            expect(text).toContain(NETIDS.student);
            // A scope failure surfaces as this message; it must not appear.
            expect(text).not.toContain('granted no yelukerest scopes');
        });
    });
});
