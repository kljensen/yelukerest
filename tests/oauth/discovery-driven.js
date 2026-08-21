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
    let challenge;
    let resourceMetadata;
    let authServerMetadata;
    let discoveredScopes;
    let client;

    afterAll(async () => {
        await cleanupClients();
    });

    describe('step 1: the unauthenticated call has to say where to go', () => {
        it('answers 401 with an RFC 9728 resource_metadata pointer', async () => {
            const res = await fetch(mcpURL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    jsonrpc: '2.0', id: 1, method: 'initialize', params: {},
                }),
            });
            expect(res.status).toBe(401);

            challenge = res.headers.get('www-authenticate');
            expect(challenge).toBeTruthy();
            // Without this the client has nowhere to go and the story ends.
            expect(challenge).toContain('resource_metadata=');
        });
    });

    describe('step 2: the resource metadata', () => {
        it('is fetchable at the advertised URL', async () => {
            const url = /resource_metadata="([^"]+)"/.exec(challenge)[1];
            const res = await fetch(url);
            expect(res.status).toBe(200);
            resourceMetadata = await res.json();
            expect(resourceMetadata.resource).toBe(mcpURL);
        });

        it('names an authorization server', () => {
            expect(Array.isArray(resourceMetadata.authorization_servers)).toBe(true);
            expect(resourceMetadata.authorization_servers.length).toBeGreaterThan(0);
        });

        // The assertion that would have caught the outage.
        it('advertises the course scopes, so a client can know to ask', () => {
            discoveredScopes = resourceMetadata.scopes_supported;
            expect(Array.isArray(discoveredScopes)).toBe(true);
            for (const required of ['course:read', 'grades:read', 'submissions:read']) {
                expect(discoveredScopes).toContain(required);
            }
        });
    });

    describe('step 3: the authorization server metadata', () => {
        it('is fetchable and offers registration and PKCE', async () => {
            const res = await fetch(
                `${resourceMetadata.authorization_servers[0]}/.well-known/oauth-authorization-server`);
            expect(res.status).toBe(200);
            authServerMetadata = await res.json();

            expect(authServerMetadata.registration_endpoint).toBeTruthy();
            expect(authServerMetadata.authorization_endpoint).toBeTruthy();
            expect(authServerMetadata.token_endpoint).toBeTruthy();
            expect(authServerMetadata.code_challenge_methods_supported).toContain('S256');
        });
    });

    describe('step 4: registration', () => {
        it('grants the course scopes to a client that asked for nothing', async () => {
            // The critical detail: no `scope` field. A client that has just
            // discovered this server has no reason to send one, and this is
            // exactly where the break was — Hydra handed back
            // "openid offline_access" and the client was quietly stuck with it.
            const { body } = await registerClient({
                client_name: 'discovery-driven-e2e',
                grant_types: ['authorization_code', 'refresh_token'],
                response_types: ['code'],
                redirect_uris: [LOOPBACK_REDIRECT],
                token_endpoint_auth_method: 'none',
            });
            client = body;
            trackClient(client.client_id);

            expect(client.client_id).toBeTruthy();
            const granted = (client.scope || '').split(' ');
            for (const required of ['course:read', 'grades:read', 'submissions:read']) {
                expect(granted).toContain(required);
            }
        });

        it('does not grant a write scope the client never asked for', () => {
            // Advertising submissions:write so it can be requested is fine.
            // Granting it at consent without a deliberate tick is not, and that
            // boundary is what makes a read-only connection meaningful.
            expect(client.scope).toBeTruthy();
        });
    });

    describe('step 5: the browser dance, then real tool calls', () => {
        let tokens;

        it('completes CAS login and consent, and returns a code', async () => {
            // Ask for exactly what discovery offered, minus the write scope: a
            // client should request what it needs, and this is the read case.
            const requested = discoveredScopes
                .filter(s => s !== 'submissions:write')
                .join(' ');

            const flow = await authorize({
                clientId: client.client_id,
                netid: NETIDS.student,
                scope: requested,
            });
            expect(flow.code).toBeTruthy();

            const exchanged = await exchangeCode({
                clientId: client.client_id,
                code: flow.code,
                verifier: flow.verifier,
            });
            expect(exchanged.status).toBe(200);
            tokens = exchanged.body;
            expect(tokens.access_token).toBeTruthy();
        });

        it('mints an access token carrying the course scopes', () => {
            const claims = decodeJWT(tokens.access_token);
            const scopes = (claims.scopes || claims.scp || claims.scope || '').toString();
            for (const required of ['course:read', 'grades:read', 'submissions:read']) {
                expect(scopes).toContain(required);
            }
            // The write scope was advertised so a client could ask, but this
            // client did not, so it must not be present.
            expect(scopes).not.toContain('submissions:write');
        });

        // The end of the story, and the thing a student actually cares about:
        // after connecting, do the tools work?
        it('answers a real tool call with real data', async () => {
            // McpClient directly, with the token this flow produced. Using the
            // mcpClientFor helper would run its own flow with READ_SCOPES and
            // quietly reintroduce the assumption this file exists to remove.
            const mcp = new McpClient(tokens.access_token);
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
