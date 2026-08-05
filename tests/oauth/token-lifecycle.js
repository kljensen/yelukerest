/* global describe it before after */

// Group 2: token lifecycle. Refresh rotation, what the rotated token carries,
// reuse detection (and the deliberate grace window in hydra/hydra.yml), and
// consent revocation through Hydra's admin API.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    READ_SCOPES,
    baseURL,
    decodeJWT,
    sharedClient,
    fullFlow,
    refreshToken,
    hydraAdmin,
    McpClient,
    sleep,
} = require('./helpers.js');

// hydra.yml sets oauth2.grant.refresh_token.rotation_grace_period: 30s, so
// proving that reuse is actually detected means waiting the window out.
const ROTATION_GRACE_MS = 30_000;
const PAST_GRACE_MS = ROTATION_GRACE_MS + 6_000;

// The reuse-detection setup has to sleep out the grace window, which is longer
// than the suite-wide default timeout. Raise it for this file only.
bunTest.setDefaultTimeout(240_000);

describe('oauth token lifecycle', () => {
    let clientId;

    before(async () => {
        clientId = (await sharedClient()).client_id;
    });


    describe('refresh rotation', () => {
        let initial;
        let rotated;

        before(async () => {
            const flow = await fullFlow({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            initial = flow.tokens;
            const response = await refreshToken({
                refresh_token: initial.refresh_token, clientId,
            });
            expect(response.status)
                .to.equal(200);
            rotated = response.body;
        });

        it('should replace the refresh token on every use', () => {
            expect(rotated.refresh_token)
                .to.be.a('string');
            expect(rotated.refresh_token)
                .to.not.equal(initial.refresh_token);
        });

        it('should mint a genuinely new access token', () => {
            expect(rotated.access_token)
                .to.not.equal(initial.access_token);
            expect(decodeJWT(rotated.access_token).jti)
                .to.not.equal(decodeJWT(initial.access_token).jti);
        });

        it('should preserve the MCP audience across the refresh', () => {
            // Without the audience allowlist authapp injects at registration,
            // Hydra drops the audience at refresh and every later /mcp call
            // 401s. This is the regression test for that.
            expect(decodeJWT(rotated.access_token).aud)
                .to.deep.equal([`${baseURL}/mcp`]);
        });

        it('should preserve the course identity claims across the refresh', () => {
            const before_ = decodeJWT(initial.access_token);
            const after_ = decodeJWT(rotated.access_token);
            expect(after_.netid)
                .to.equal(before_.netid);
            expect(after_.user_id)
                .to.equal(before_.user_id);
            expect(after_.role)
                .to.equal(before_.role);
            expect(after_.scopes)
                .to.equal(before_.scopes);
            expect(after_.sub)
                .to.equal(before_.sub);
            expect(after_.iss)
                .to.equal(before_.iss);
        });

        it('should hand out an access token that still works against /mcp', async () => {
            const mcp = new McpClient(rotated.access_token);
            const init = await mcp.initialize();
            expect(init.status)
                .to.equal(200);
            const me = await mcp.callOk('whoami');
            expect(me.netid)
                .to.equal(NETIDS.student);
            await mcp.close();
        });
    });

    describe('refresh token reuse', () => {
        let stale;
        let successor;
        let graceReuse;
        let lateReuse;
        let familyAfterReuse;

        before(async () => {
            const flow = await fullFlow({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            stale = flow.tokens.refresh_token;

            const first = await refreshToken({ refresh_token: stale, clientId });
            expect(first.status)
                .to.equal(200);
            successor = first.body.refresh_token;

            // Replay inside the grace window.
            graceReuse = await refreshToken({ refresh_token: stale, clientId });

            // ...and again once the window has closed.
            await sleep(PAST_GRACE_MS);
            lateReuse = await refreshToken({ refresh_token: stale, clientId });
            familyAfterReuse = await refreshToken({ refresh_token: successor, clientId });
        });

        it('should tolerate one replay inside the configured grace period', () => {
            // hydra.yml deliberately allows this: agent clients retry a
            // refresh after a network hiccup, and treating that as theft
            // would log the user out. Documented behaviour, not an accident.
            expect(graceReuse.status)
                .to.equal(200);
            expect(graceReuse.body.access_token)
                .to.be.a('string');
        });

        it('should reject a replayed refresh token once the grace period lapses', () => {
            expect(lateReuse.status)
                .to.equal(400);
            expect(lateReuse.body.error)
                .to.equal('invalid_grant');
        });

        it('should invalidate the whole token family when reuse is detected', () => {
            // OAuth 2.1 rotation: the successor issued from the replayed
            // token is revoked too, so a thief and the victim both lose the
            // session rather than the thief silently keeping it.
            expect(familyAfterReuse.status)
                .to.equal(400);
            expect(familyAfterReuse.body.error)
                .to.equal('invalid_grant');
        });
    });

    describe('consent revocation', () => {
        let tokens;
        let revokeStatus;
        let refreshAfterRevoke;

        before(async () => {
            const flow = await fullFlow({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            tokens = flow.tokens;
            const query = new URLSearchParams({
                subject: NETIDS.student, client: clientId, all: 'false',
            });
            revokeStatus = hydraAdmin('DELETE', `/admin/oauth2/auth/sessions/consent?${query.toString()}`).status;
            refreshAfterRevoke = await refreshToken({
                refresh_token: tokens.refresh_token, clientId,
            });
        });

        it('should accept the admin revocation', () => {
            expect(revokeStatus)
                .to.equal(204);
        });

        it('should kill the refresh token', () => {
            expect(refreshAfterRevoke.status)
                .to.equal(400);
            expect(refreshAfterRevoke.body.error)
                .to.equal('invalid_grant');
        });

        it('should leave the already-issued access token valid until it expires', async () => {
            // Documented consequence of `strategies.access_token: jwt`:
            // mcpapp validates signature/expiry/audience locally and never
            // introspects, so revocation bounds the session at the next
            // refresh (<= 1h) rather than instantly. Asserted so a future
            // switch to opaque tokens or introspection is a conscious change.
            const mcp = new McpClient(tokens.access_token);
            const init = await mcp.initialize();
            expect(init.status)
                .to.equal(200);
            await mcp.close();
        });

        it('should let the user grant consent again from scratch', async () => {
            const flow = await fullFlow({
                clientId, netid: NETIDS.student, scope: READ_SCOPES,
            });
            expect(flow.tokens.access_token)
                .to.be.a('string');
            expect(decodeJWT(flow.tokens.access_token).netid)
                .to.equal(NETIDS.student);
        });
    });
});
