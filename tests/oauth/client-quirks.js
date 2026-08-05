/* global describe it before after */

// Group 4: the shapes real MCP clients key on. Claude, ChatGPT, Cursor and
// mcp-remote all parse these documents with strict parsers, and a null or an
// empty string in the wrong place breaks the connection before a single tool
// call happens. These are regression tests for issues #271, #272 and #274.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    READ_SCOPES,
    LOOPBACK_PORT,
    baseURL,
    mcpURL,
    registerClient,
    sharedClient,
    fullFlow,
    McpClient,
} = require('./helpers.js');

// bun resets the default per-test timeout for each file; these tests drive a
// real Docker stack (and back off when a rate limiter pushes back), so give
// them room.
bunTest.setDefaultTimeout(120_000);

/** Recursively collects paths of null, empty-string, empty-array and empty-object values. */
function emptyPaths(value, prefix = '') {
    if (value === null) {
        return [`${prefix} (null)`];
    }
    if (typeof value === 'string') {
        return value === '' ? [`${prefix} (empty string)`] : [];
    }
    if (Array.isArray(value)) {
        if (value.length === 0) {
            return [`${prefix} (empty array)`];
        }
        return value.flatMap((item, index) => emptyPaths(item, `${prefix}[${index}]`));
    }
    if (typeof value === 'object') {
        const keys = Object.keys(value);
        if (keys.length === 0) {
            return [`${prefix} (empty object)`];
        }
        return keys.flatMap(key => emptyPaths(value[key], prefix ? `${prefix}.${key}` : key));
    }
    return [];
}

async function getJSON(path) {
    const response = await fetch(`${baseURL}${path}`);
    return { status: response.status, headers: response.headers, body: await response.json() };
}

describe('oauth client quirks and discovery', () => {
    describe('dynamic client registration', () => {
        let registration;

        before(async () => {
            registration = await sharedClient();
        });

        it('should return no null or empty optional fields anywhere', () => {
            // ory/hydra#4044: raw Hydra returns "contacts": null, "owner": "",
            // "jwks": {}, thirteen null *_lifespan fields and more, which
            // strict-parser clients reject. authapp's cleaning proxy strips
            // them; this test is the reason that proxy exists.
            expect(emptyPaths(registration))
                .to.deep.equal([]);
        });

        it('should return the fields a client needs to continue', () => {
            expect(registration.client_id)
                .to.be.a('string')
                .with.length.greaterThan(8);
            expect(registration.redirect_uris)
                .to.deep.equal([`http://127.0.0.1:${LOOPBACK_PORT}/callback`]);
            expect(registration.grant_types)
                .to.include('authorization_code')
                .and.to.include('refresh_token');
            expect(registration.response_types)
                .to.deep.equal(['code']);
            expect(registration.token_endpoint_auth_method)
                .to.equal('none');
            expect(registration.scope)
                .to.be.a('string')
                .with.length.greaterThan(0);
        });

        it('should pin the MCP audience on the client so refresh keeps working', () => {
            // Issue #271: a client registered with an empty audience allowlist
            // gets a working first token and then fails every refresh with
            // "Requested audience has not been whitelisted".
            expect(registration.audience)
                .to.deep.equal([mcpURL]);
        });

        it('should refuse a plain-http redirect URI on a non-loopback host', async () => {
            const result = await registerClient({
                client_name: 'e2e-bad-redirect',
                redirect_uris: ['http://evil.example.com/callback'],
            }, { expectStatus: 400 });
            expect(result.status)
                .to.be.at.least(400);
            expect(result.body.error)
                .to.equal('invalid_redirect_uri');
        });

        it('should refuse a redirect URI that is not a URI at all', async () => {
            const result = await registerClient({
                client_name: 'e2e-bad-redirect-2',
                redirect_uris: ['not a uri'],
            }, { expectStatus: 400 });
            expect(result.status)
                .to.be.at.least(400);
            expect(result.body.error)
                .to.equal('invalid_redirect_uri');
        });

        it('should refuse an unreasonable number of redirect URIs', async () => {
            const many = Array.from({ length: 25 }, (unused, index) => `http://127.0.0.1:${9000 + index}/callback`);
            const result = await registerClient({
                client_name: 'e2e-too-many-redirects',
                redirect_uris: many,
            }, { expectStatus: 400 });
            expect(result.status)
                .to.be.at.least(400);
            expect(result.body.error)
                .to.equal('invalid_redirect_uri');
        });
    });

    describe('loopback callbacks', () => {
        let localhostClient;

        before(async () => {
            localhostClient = (await registerClient({
                client_name: 'e2e-localhost-loopback',
                redirect_uris: [`http://localhost:${LOOPBACK_PORT}/callback`],
            })).body;
        });

        it('should accept a http://localhost registration', () => {
            expect(localhostClient.redirect_uris)
                .to.deep.equal([`http://localhost:${LOOPBACK_PORT}/callback`]);
        });

        it('should complete the whole flow against a localhost callback', async () => {
            // Documented behaviour: a client registered with `localhost` must
            // USE `localhost`; the two spellings are not interchangeable
            // (see the redirect-matching tests in security-negatives.js).
            // Clients that register one and call back on the other -- a
            // recurring MCP client bug -- fail here, by design.
            const flow = await fullFlow({
                clientId: localhostClient.client_id,
                netid: NETIDS.student,
                scope: READ_SCOPES,
                redirectUri: `http://localhost:${LOOPBACK_PORT}/callback`,
            });
            expect(flow.callbackURL.origin)
                .to.equal(`http://localhost:${LOOPBACK_PORT}`);
            const mcp = new McpClient(flow.tokens.access_token);
            const init = await mcp.initialize();
            expect(init.status)
                .to.equal(200);
            await mcp.close();
        });
    });

    describe('authorization server metadata', () => {
        let oidc;
        let oauth;

        before(async () => {
            oidc = await getJSON('/.well-known/openid-configuration');
            oauth = await getJSON('/.well-known/oauth-authorization-server');
        });

        it('should serve both discovery documents', () => {
            expect(oidc.status)
                .to.equal(200);
            expect(oauth.status)
                .to.equal(200);
        });

        it('should agree on the issuer, and use the bare origin', () => {
            // The deployment deliberately runs Hydra at the root of the domain
            // rather than under a path prefix, so both well-known locations
            // are correct as served (hydra/hydra.yml explains why).
            expect(oidc.body.issuer)
                .to.equal(baseURL);
            expect(oauth.body.issuer)
                .to.equal(oidc.body.issuer);
        });

        it('should advertise identical endpoints in both documents', () => {
            ['authorization_endpoint', 'token_endpoint', 'registration_endpoint', 'jwks_uri'].forEach((field) => {
                expect(oauth.body[field], field)
                    .to.equal(oidc.body[field]);
                expect(oauth.body[field], field)
                    .to.be.a('string')
                    .and.to.satisfy(value => value.startsWith(`${baseURL}/`));
            });
        });

        it('should advertise the registration endpoint MCP clients need', () => {
            // Hydra only emits registration_endpoint when
            // webfinger.oidc_discovery.client_registration_url is set;
            // enabling DCR alone is not enough, and without it Claude and
            // ChatGPT cannot connect at all.
            expect(oidc.body.registration_endpoint)
                .to.equal(`${baseURL}/oauth2/register`);
        });

        it('should advertise S256 PKCE support', () => {
            expect(oidc.body.code_challenge_methods_supported)
                .to.include('S256');
            expect(oauth.body.code_challenge_methods_supported)
                .to.include('S256');
        });

        it('should advertise the grant types and public-client auth method', () => {
            expect(oidc.body.grant_types_supported)
                .to.include('authorization_code')
                .and.to.include('refresh_token');
            expect(oidc.body.response_types_supported)
                .to.include('code');
            expect(oidc.body.token_endpoint_auth_methods_supported)
                .to.include('none');
        });
    });

    describe('protected resource metadata (RFC 9728)', () => {
        let scoped;
        let root;

        before(async () => {
            scoped = await getJSON('/.well-known/oauth-protected-resource/mcp');
            root = await getJSON('/.well-known/oauth-protected-resource');
        });

        it('should describe /mcp at the path-specific well-known URL', () => {
            expect(scoped.status)
                .to.equal(200);
            expect(scoped.body.resource)
                .to.equal(mcpURL);
        });

        it('should point at this deployment\'s authorization server', () => {
            expect(scoped.body.authorization_servers)
                .to.deep.equal([baseURL]);
        });

        it('should declare header bearer methods', () => {
            expect(scoped.body.bearer_methods_supported)
                .to.deep.equal(['header']);
        });

        it('should also serve the root document with the same content', () => {
            expect(root.status)
                .to.equal(200);
            expect(root.body)
                .to.deep.equal(scoped.body);
        });

        it('should be readable cross-origin by browser-based clients', () => {
            expect(scoped.headers.get('access-control-allow-origin'))
                .to.equal('*');
        });

        it('should name an authorization server whose metadata actually resolves', async () => {
            const server = scoped.body.authorization_servers[0];
            const metadata = await fetch(`${server}/.well-known/oauth-authorization-server`);
            expect(metadata.status)
                .to.equal(200);
            expect((await metadata.json()).issuer)
                .to.equal(server);
        });
    });
});
