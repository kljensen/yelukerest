/* global describe it before after */

// Group 3: the things that must NOT work. Everything here drives the real
// stack; nothing is stubbed, so a regression in Hydra's configuration, in
// authapp's consent handler, or in mcpapp's token verification shows up here.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    READ_SCOPES,
    LOOPBACK_REDIRECT,
    baseURL,
    mcpURL,
    decodeJWT,
    randomState,
    pkcePair,
    sharedClient,
    adminCreateClient,
    authorize,
    authorizeRaw,
    exchangeCode,
    refreshToken,
    tokenRequest,
    fullFlow,
    McpClient,
    sleep,
} = require('./helpers.js');

// The expiry test has to outlive a short-lived token.
bunTest.setDefaultTimeout(240_000);

/** POSTs one JSON-RPC message to /mcp with an arbitrary bearer token. */
async function callMCPWithToken(token) {
    const response = await fetch(mcpURL, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            Accept: 'application/json, text/event-stream',
            ...(token === null ? {} : { Authorization: `Bearer ${token}` }),
        },
        body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'initialize',
            params: {
                protocolVersion: '2025-11-25',
                capabilities: {},
                clientInfo: { name: 'e2e-negative', version: '1.0.0' },
            },
        }),
    });
    return {
        status: response.status,
        wwwAuthenticate: response.headers.get('www-authenticate'),
        body: await response.text(),
    };
}

describe('oauth security negatives', () => {
    let clientId;
    // One student token, shared by every test that only needs "a valid token";
    // each flow costs three requests against a rate-limited handler.
    let studentTokens;

    before(async () => {
        clientId = (await sharedClient()).client_id;
        studentTokens = (await fullFlow({
            clientId, netid: NETIDS.student, scope: READ_SCOPES,
        })).tokens;
    });


    describe('audience binding', () => {
        let foreignAudienceToken;
        let noAudienceToken;
        let correctAudienceToken;

        before(async () => {
            // A client whose audience allowlist points somewhere that is not
            // this MCP resource. Created straight through Hydra's admin API:
            // the DCR proxy would inject the MCP audience, and registering it
            // is not what is under test here.
            // The allowlist carries both audiences so the SAME client can
            // mint an otherwise-identical accepted token as a control: that
            // is what proves the rejections below are caused by audience
            // validation and not by some later step.
            const client = adminCreateClient({
                client_name: 'e2e-foreign-audience',
                grant_types: ['client_credentials'],
                response_types: [],
                scope: 'course:read',
                audience: [`${baseURL}/not-mcp`, mcpURL],
                token_endpoint_auth_method: 'client_secret_post',
            });
            const withCorrectAudience = await tokenRequest({
                grant_type: 'client_credentials',
                client_id: client.client_id,
                client_secret: client.client_secret,
                scope: 'course:read',
                audience: mcpURL,
            });
            expect(withCorrectAudience.status)
                .to.equal(200);
            correctAudienceToken = withCorrectAudience.body.access_token;
            const withAudience = await tokenRequest({
                grant_type: 'client_credentials',
                client_id: client.client_id,
                client_secret: client.client_secret,
                scope: 'course:read',
                audience: `${baseURL}/not-mcp`,
            });
            expect(withAudience.status)
                .to.equal(200);
            foreignAudienceToken = withAudience.body.access_token;

            const withoutAudience = await tokenRequest({
                grant_type: 'client_credentials',
                client_id: client.client_id,
                client_secret: client.client_secret,
                scope: 'course:read',
            });
            expect(withoutAudience.status)
                .to.equal(200);
            noAudienceToken = withoutAudience.body.access_token;
        });

        it('should be a genuine, correctly signed Hydra token (control)', () => {
            const claims = decodeJWT(foreignAudienceToken);
            expect(claims.iss)
                .to.equal(baseURL);
            expect(claims.aud)
                .to.deep.equal([`${baseURL}/not-mcp`]);
        });

        // Positive control: the same client, the same grant, the same
        // scope — only the audience differs. Without this, a 401 below
        // could come from any later step and the negatives would prove
        // nothing about audience validation.
        it('should accept an otherwise identical token carrying the MCP audience (control)', async () => {
            const response = await callMCPWithToken(correctAudienceToken);
            expect(response.status)
                .to.equal(200);
        });

        it('should reject a token whose audience is another resource', async () => {
            const response = await callMCPWithToken(foreignAudienceToken);
            expect(response.status)
                .to.equal(401);
            expect(response.wwwAuthenticate)
                .to.contain('resource_metadata=');
        });

        it('should reject a token carrying no audience at all', async () => {
            expect(decodeJWT(noAudienceToken).aud || [])
                .to.not.include(mcpURL);
            const response = await callMCPWithToken(noAudienceToken);
            expect(response.status)
                .to.equal(401);
        });
    });

    describe('token integrity and expiry', () => {
        let validToken;

        before(() => {
            validToken = studentTokens.access_token;
        });

        it('should reject a token with a tampered signature', async () => {
            const parts = validToken.split('.');
            const signature = parts[2];
            const flipped = (signature[0] === 'A' ? 'B' : 'A') + signature.slice(1);
            const response = await callMCPWithToken(`${parts[0]}.${parts[1]}.${flipped}`);
            expect(response.status)
                .to.equal(401);
            expect(response.wwwAuthenticate)
                .to.contain('Bearer');
            expect(response.wwwAuthenticate)
                .to.contain(`resource_metadata="${baseURL}/.well-known/oauth-protected-resource/mcp"`);
        });

        it('should reject a token whose payload was rewritten', async () => {
            // Escalate role to faculty in the payload, keep the signature.
            const parts = validToken.split('.');
            const claims = decodeJWT(validToken);
            claims.role = 'faculty';
            claims.netid = NETIDS.faculty;
            const forged = Buffer.from(JSON.stringify(claims))
                .toString('base64url');
            const response = await callMCPWithToken(`${parts[0]}.${forged}.${parts[2]}`);
            expect(response.status)
                .to.equal(401);
        });

        it('should reject an unsigned (alg=none) token', async () => {
            const claims = decodeJWT(validToken);
            const header = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' }))
                .toString('base64url');
            const payload = Buffer.from(JSON.stringify(claims))
                .toString('base64url');
            const response = await callMCPWithToken(`${header}.${payload}.`);
            expect(response.status)
                .to.equal(401);
        });

        it('should reject a garbage bearer token', async () => {
            const response = await callMCPWithToken('not-a-jwt-at-all');
            expect(response.status)
                .to.equal(401);
        });

        it('should reject an expired token', async () => {
            // Hydra's global access-token TTL is 1h, so this uses a client
            // with a per-client lifespan short enough to wait out.
            const shortLived = adminCreateClient({
                client_name: 'e2e-short-lifespan',
                grant_types: ['authorization_code', 'refresh_token'],
                response_types: ['code'],
                redirect_uris: [LOOPBACK_REDIRECT],
                scope: READ_SCOPES,
                audience: [mcpURL],
                token_endpoint_auth_method: 'none',
                authorization_code_grant_access_token_lifespan: '3s',
            });
            const flow = await fullFlow({
                clientId: shortLived.client_id, netid: NETIDS.student, scope: READ_SCOPES,
            });
            expect(flow.tokens.expires_in)
                .to.be.at.most(3);

            // It works while it is alive...
            const before_ = await callMCPWithToken(flow.tokens.access_token);
            expect(before_.status)
                .to.equal(200);

            // ...and stops the moment it expires.
            await sleep(5000);
            const after_ = await callMCPWithToken(flow.tokens.access_token);
            expect(after_.status)
                .to.equal(401);
            expect(after_.wwwAuthenticate)
                .to.contain('resource_metadata=');
        });
    });

    describe('cross-surface token confusion', () => {
        let hydraToken;

        before(() => {
            hydraToken = studentTokens.access_token;
        });

        it('should refuse a Hydra access token at the PostgREST API', async () => {
            const response = await fetch(`${baseURL}/rest/users`, {
                headers: { Authorization: `Bearer ${hydraToken}` },
            });
            expect(response.status)
                .to.equal(401);
        });

        it('should refuse a Hydra access token at the authapp JWT endpoint', async () => {
            const response = await fetch(`${baseURL}/auth/jwt`, {
                headers: { Authorization: `Bearer ${hydraToken}` },
                redirect: 'manual',
            });
            expect(response.status)
                .to.be.at.least(400);
        });

        it('should still accept the same token at /mcp (control)', async () => {
            const response = await callMCPWithToken(hydraToken);
            expect(response.status)
                .to.equal(200);
        });
    });

    describe('default-deny on scopes', () => {
        it('should refuse tool calls for a token granted no yelukerest scopes', async () => {
            const flow = await fullFlow({
                clientId, netid: NETIDS.student, scope: 'openid offline_access',
            });
            const claims = decodeJWT(flow.tokens.access_token);
            expect(claims.scopes)
                .to.equal('openid offline_access');

            const mcp = new McpClient(flow.tokens.access_token);
            const init = await mcp.initialize();
            expect(init.status)
                .to.equal(200);
            const message = await mcp.callExpectError('whoami');
            expect(message.toLowerCase())
                .to.contain('scope');
            await mcp.close();
        });

        it('should refuse a write for a read-only token', async () => {
            const mcp = new McpClient(studentTokens.access_token);
            await mcp.initialize();
            const message = await mcp.callExpectError('submit_submission_change', {
                assignment_slug: 'exam-1', field_slug: 'profound', body: 'nope',
            });
            expect(message.toLowerCase())
                .to.contain('scope');
            await mcp.close();
        });
    });

    describe('PKCE', () => {
        it('should reject a token exchange with the wrong code verifier', async () => {
            const flow = await authorize({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            expect(flow.code)
                .to.be.a('string');
            const response = await exchangeCode({
                code: flow.code,
                clientId,
                verifier: pkcePair().verifier,
            });
            expect(response.status)
                .to.equal(400);
            expect(response.body.error)
                .to.equal('invalid_grant');
        });

        it('should reject a token exchange with no code verifier at all', async () => {
            const flow = await authorize({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            const response = await exchangeCode({ code: flow.code, clientId });
            expect(response.status)
                .to.equal(400);
            expect(response.body.error)
                .to.be.a('string');
        });

        it('should refuse an authorization request that omits PKCE entirely', async () => {
            // Note where the refusal lands: Hydra accepts the request at
            // /oauth2/auth and only fails it after login and consent, at the
            // point it would issue the code. The user therefore authenticates
            // before the downgrade is caught, but no code is ever minted.
            const flow = await authorize({
                clientId, netid: NETIDS.student, scope: READ_SCOPES, pkce: false,
            });
            expect(flow.code)
                .to.equal(null);
            expect(flow.callbackURL.searchParams.get('error'))
                .to.equal('invalid_request');
        });

        it('should refuse the plain code challenge method', async () => {
            const flow = await authorize({
                clientId, netid: NETIDS.student, scope: READ_SCOPES, challengeMethod: 'plain',
            });
            expect(flow.code)
                .to.equal(null);
            expect(flow.callbackURL.searchParams.get('error'))
                .to.equal('invalid_request');
        });
    });

    describe('authorization code single use', () => {
        let firstExchange;
        let replayExchange;
        let refreshAfterReplay;

        before(async () => {
            const flow = await authorize({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            firstExchange = await exchangeCode({
                code: flow.code, clientId, verifier: flow.verifier,
            });
            replayExchange = await exchangeCode({
                code: flow.code, clientId, verifier: flow.verifier,
            });
            refreshAfterReplay = await refreshToken({
                refresh_token: firstExchange.body.refresh_token, clientId,
            });
        });

        it('should exchange the code exactly once', () => {
            expect(firstExchange.status)
                .to.equal(200);
        });

        it('should reject a replayed authorization code', () => {
            expect(replayExchange.status)
                .to.equal(400);
            expect(replayExchange.body.error)
                .to.equal('invalid_grant');
        });

        it('should revoke the tokens minted from the replayed code', () => {
            // RFC 6749 4.1.2: on code reuse the authorization server SHOULD
            // revoke everything previously issued from that code.
            expect(refreshAfterReplay.status)
                .to.equal(400);
            expect(refreshAfterReplay.body.error)
                .to.equal('invalid_grant');
        });


    });

    describe('redirect URI matching', () => {
        it('should refuse a redirect URI on a different host', async () => {
            // The shared client registered http://127.0.0.1:PORT/callback.
            // RFC 8252 loopback relaxation covers the PORT only; `localhost`
            // is a different host and must be refused before any login
            // happens, so the failure is reported on Hydra's own error page
            // rather than sent to the unregistered URI.
            const response = await authorizeRaw({
                client_id: clientId,
                response_type: 'code',
                redirect_uri: LOOPBACK_REDIRECT.replace('127.0.0.1', 'localhost'),
                scope: READ_SCOPES,
                state: randomState(),
                code_challenge: pkcePair().challenge,
                code_challenge_method: 'S256',
            });
            expect(response.location || '')
                .to.not.contain('code=');
            expect(response.location || '')
                .to.contain('/oauth2/fallbacks/error');
            expect(response.location || '')
                .to.contain('error=invalid_request');
        });

        it('should refuse a redirect URI on an entirely different origin', async () => {
            const response = await authorizeRaw({
                client_id: clientId,
                response_type: 'code',
                redirect_uri: 'https://evil.example.com/callback',
                scope: READ_SCOPES,
                state: randomState(),
                code_challenge: pkcePair().challenge,
                code_challenge_method: 'S256',
            });
            expect(response.location || '')
                .to.not.contain('code=');
            expect(response.location || '')
                .to.contain('error=');
            expect(response.location || '')
                .to.not.contain('evil.example.com');
        });

        it('should allow a different port on the same loopback host (RFC 8252)', async () => {
            // Native/desktop MCP clients bind an ephemeral callback port and
            // cannot know it at registration time, so the loopback port is
            // matched loosely on purpose. Asserted so the relaxation stays
            // scoped to the port and never widens to the host.
            const variantRedirect = 'http://127.0.0.1:9999/callback';
            const flow = await authorize({
                clientId, netid: NETIDS.student, scope: READ_SCOPES, redirectUri: variantRedirect,
            });
            expect(flow.code)
                .to.be.a('string');
            expect(flow.callbackURL.origin)
                .to.equal('http://127.0.0.1:9999');
            const tokens = await exchangeCode({
                code: flow.code,
                clientId,
                verifier: flow.verifier,
                redirectUri: variantRedirect,
            });
            expect(tokens.status)
                .to.equal(200);
        });

        it('should reject a token exchange whose redirect URI does not match', async () => {
            const flow = await authorize({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            const response = await exchangeCode({
                code: flow.code,
                clientId,
                verifier: flow.verifier,
                // Same loopback host and port, different path: paths are
                // matched exactly even where the port is not.
                redirectUri: 'http://127.0.0.1:9876/somewhere-else',
            });
            expect(response.status)
                .to.equal(400);
            expect(response.body.error)
                .to.equal('invalid_grant');
        });
    });

    describe('the consent form', () => {
        it('should reject a submission with a forged CSRF token', async () => {
            const flow = await authorize({
                clientId,
                netid: NETIDS.student,
                scope: READ_SCOPES,
                mutateConsentBody: (form) => {
                    form.set('csrf_token', 'f'.repeat(64));
                },
            });
            expect(flow.code)
                .to.equal(null);
            expect(flow.decisionStatus)
                .to.equal(403);
        });

        it('should reject a submission with no CSRF token', async () => {
            const flow = await authorize({
                clientId,
                netid: NETIDS.student,
                scope: READ_SCOPES,
                mutateConsentBody: (form) => {
                    form.delete('csrf_token');
                },
            });
            expect(flow.decisionStatus)
                .to.equal(403);
        });

        it('should ignore a tampered subject field and keep the CAS identity', async () => {
            const flow = await fullFlow({
                clientId,
                netid: NETIDS.student,
                scope: READ_SCOPES,
                mutateConsentBody: (form) => {
                    // A hostile page cannot consent as somebody else: the
                    // subject comes from Hydra plus the session, never the
                    // form.
                    form.set('subject', NETIDS.faculty);
                    form.set('netid', NETIDS.faculty);
                    form.set('user_id', '3');
                    form.set('role', 'faculty');
                },
            });
            const claims = decodeJWT(flow.tokens.access_token);
            expect(claims.sub)
                .to.equal(NETIDS.student);
            expect(claims.netid)
                .to.equal(NETIDS.student);
            expect(claims.role)
                .to.equal('student');
        });

        it('should ignore approved scopes that were never requested', async () => {
            const flow = await fullFlow({
                clientId,
                netid: NETIDS.student,
                scope: READ_SCOPES,
                mutateConsentBody: (form) => {
                    form.append('grant_scope', 'submissions:write');
                    form.append('grant_scope', 'admin');
                    form.append('grant_scope', 'grades:write');
                },
            });
            const claims = decodeJWT(flow.tokens.access_token);
            const granted = claims.scopes.split(' ');
            expect(granted.sort())
                .to.deep.equal(READ_SCOPES.split(' ')
                    .sort());
            expect(granted)
                .to.not.include('submissions:write');
            expect(granted)
                .to.not.include('admin');
        });

        it('should narrow the granted scopes when the user approves fewer', async () => {
            const flow = await fullFlow({
                clientId,
                netid: NETIDS.student,
                scope: READ_SCOPES,
                mutateConsentBody: (form) => {
                    const kept = form.getAll('grant_scope')
                        .filter(scope => scope !== 'grades:read');
                    form.delete('grant_scope');
                    kept.forEach(scope => form.append('grant_scope', scope));
                },
            });
            const granted = decodeJWT(flow.tokens.access_token).scopes.split(' ');
            expect(granted)
                .to.not.include('grades:read');
            expect(granted)
                .to.include('course:read');

            // KNOWN GAP (reported, not fixed here): mcpapp's gate is coarse.
            // authorizeScope only distinguishes read from write, and any of
            // course:read / grades:read / submissions:read satisfies "read"
            // (mcpapp/tools.go scopeAliases). So a token the user narrowed to
            // exclude grades:read still reaches get_my_grades. The consent
            // screen offers granularity the resource server does not enforce.
            // This assertion pins the CURRENT behaviour: when per-tool scope
            // enforcement lands, this test fails and should be inverted.
            const mcp = new McpClient(flow.tokens.access_token);
            await mcp.initialize();
            const grades = await mcp.callOk('get_my_grades');
            expect(grades.grades)
                .to.be.an('array');
            await mcp.close();
        });

        it('should treat anything but an explicit allow as a denial', async () => {
            const flow = await authorize({
                clientId,
                netid: NETIDS.student,
                scope: READ_SCOPES,
                mutateConsentBody: (form) => {
                    form.set('action', 'deny');
                },
            });
            expect(flow.callbackURL.searchParams.get('code'))
                .to.equal(null);
            expect(flow.callbackURL.searchParams.get('error'))
                .to.equal('access_denied');
        });
    });
});
