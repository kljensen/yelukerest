// Personal access tokens end to end (issues #314-#317): creation through
// PostgREST, the /auth/token exchange, scope enforcement on writes, and
// revocation.
//
// The scope check in particular can only be tested here. It depends on
// `request.method`, which PostgREST sets per request and a direct database
// session never has, so the database tests cannot reach it.

const { describe, it, expect, beforeAll, afterEach } = require('bun:test');
const request = require('supertest');
const { spawnSync } = require('child_process');
const { baseURL } = require('./common.js');

const psqlPath = (() => {
    const r = spawnSync('sh', ['-c', 'command -v psql']);
    return r.status === 0 ? r.stdout.toString('utf8').trim() : '';
})();

// Mint a browser-style JWT (no `scopes` claim) the way authapp would, so the
// test can act as a signed-in student without driving CAS.
function mintUserJWT(netid) {
    const url = process.env.YELUKEREST_DEV_DATABASE_URL;
    const sql = `
        set request.jwt.claim.role = 'app';
        set request.jwt.claim.app_name = 'authapp';
        set request.jwt.claim.user_id = '';
        select jwt from api.issue_user_jwt('${netid}');
    `;
    const r = spawnSync(psqlPath, [url, '-At', '-c', sql]);
    if (r.status !== 0) {
        throw new Error(`could not mint a test JWT: ${r.stderr.toString('utf8')}`);
    }
    return r.stdout.toString('utf8').trim().split('\n').pop();
}

const rest = () => request(`${baseURL}/rest`);
const auth = () => request(`${baseURL}`);

describe('personal access tokens', () => {
    let studentJWT;

    // A person may hold five active tokens (issue #347), and this file creates
    // more than that over its run. Clearing up after each test is also what a
    // student does, so the suite exercises the intended shape of the feature
    // rather than working around it -- and it stops one run leaving the next
    // one at the cap.
    async function revokeAllTokens() {
        const listed = await rest()
            .get('/user_api_tokens?is_active=is.true&select=id')
            .set('Authorization', `Bearer ${studentJWT}`);
        expect(listed.status).toBe(200);
        for (const row of listed.body) {
            const revoked = await rest()
                .post('/rpc/revoke_user_api_token')
                .set('Authorization', `Bearer ${studentJWT}`)
                .send({ p_id: row.id });
            expect(revoked.status).toBe(200);
        }
    }

    beforeAll(async () => {
        studentJWT = mintUserJWT('abc123');
        expect(studentJWT.split('.').length).toBe(3);
        await revokeAllTokens();
    });

    afterEach(async () => {
        await revokeAllTokens();
    });

    async function createToken(name, scopes) {
        const body = scopes ? { p_name: name, p_scopes: scopes } : { p_name: name };
        const res = await rest()
            .post('/rpc/create_user_api_token')
            .set('Authorization', `Bearer ${studentJWT}`)
            .set('Accept', 'application/vnd.pgrst.object+json')
            .send(body);
        expect(res.status).toBe(200);
        return res.body;
    }

    async function exchange(token) {
        return auth().post('/auth/token').set('Authorization', `Bearer ${token}`);
    }

    it('creates a read-only token by default', async () => {
        const created = await createToken('default scopes test');
        expect(created.token).toMatch(/^yk_[0-9a-f]{8}_[0-9a-f]{64}$/);
        expect(created.scopes.sort()).toEqual(
            ['course:read', 'grades:read', 'submissions:read']);
    });

    it('never exposes the secret again after creation', async () => {
        const created = await createToken('listing test');
        const res = await rest()
            .get(`/user_api_tokens?token_prefix=eq.${created.token_prefix}`)
            .set('Authorization', `Bearer ${studentJWT}`);
        expect(res.status).toBe(200);
        expect(res.body.length).toBe(1);
        // Neither the secret nor its hash may ever come back out.
        expect(Object.keys(res.body[0])).not.toContain('token');
        expect(Object.keys(res.body[0])).not.toContain('token_hash');
    });

    it('exchanges a token for a short-lived JWT carrying its scopes', async () => {
        const created = await createToken('exchange test');
        const res = await exchange(created.token);
        expect(res.status).toBe(200);
        expect(res.body.token_type).toBe('Bearer');
        expect(res.body.expires_in).toBeGreaterThan(0);
        expect(res.body.scopes.sort()).toEqual(created.scopes.sort());
        expect(res.body.jwt.split('.').length).toBe(3);
    });

    it('refuses every kind of bad credential identically', async () => {
        const bad = [
            `yk_00000000_${'a'.repeat(64)}`,  // unknown prefix
            'not-a-token',                     // malformed
        ];
        for (const token of bad) {
            const res = await exchange(token);
            expect(res.status).toBe(401);
        }
        // ...and with no credential at all.
        const none = await auth().post('/auth/token');
        expect(none.status).toBe(401);
    });

    it('does not accept a token in the query string', async () => {
        const created = await createToken('query string test');
        // A token in a URL lands in access logs and Referer headers.
        const res = await auth().post(`/auth/token?token=${created.token}`);
        expect(res.status).toBe(401);
    });

    it('rejects the token itself against PostgREST', async () => {
        const created = await createToken('direct use test');
        const res = await rest()
            .get('/meetings')
            .set('Authorization', `Bearer ${created.token}`);
        // The long-lived credential is not a JWT and must never work directly.
        expect(res.status).toBe(401);
    });

    it('allows reads with a read-only token', async () => {
        const created = await createToken('read test');
        const { body } = await exchange(created.token);
        const res = await rest()
            .get('/meetings?limit=1')
            .set('Authorization', `Bearer ${body.jwt}`);
        expect(res.status).toBe(200);
    });

    // The heart of it. Before scope enforcement existed this PATCH returned
    // 200: row-level security asks who you are, never what the token was
    // allowed to do.
    it('blocks writes with a read-only token', async () => {
        const created = await createToken('readonly write test');
        const { body } = await exchange(created.token);
        const res = await rest()
            .patch('/assignment_field_submissions?assignment_submission_id=eq.1&assignment_field_slug=eq.secret')
            .set('Authorization', `Bearer ${body.jwt}`)
            .send({ body: 'should be blocked' });
        expect(res.status).toBe(403);
        expect(JSON.stringify(res.body)).toContain('read-only');
    });

    it('allows writes with a submissions:write token', async () => {
        const created = await createToken('writer test',
            ['course:read', 'submissions:read', 'submissions:write']);
        const { body } = await exchange(created.token);
        const res = await rest()
            .patch('/assignment_field_submissions?assignment_submission_id=eq.1&assignment_field_slug=eq.secret')
            .set('Authorization', `Bearer ${body.jwt}`)
            .send({ body: 'foobarsecret-bright-fog' });
        expect([200, 204]).toContain(res.status);
    });

    // A read-only token minting itself a writable one would make the whole
    // read-only default meaningless.
    it('does not let a read-only token create another token', async () => {
        const created = await createToken('escalation test');
        const { body } = await exchange(created.token);
        const res = await rest()
            .post('/rpc/create_user_api_token')
            .set('Authorization', `Bearer ${body.jwt}`)
            .send({ p_name: 'escalated', p_scopes: ['submissions:write'] });
        expect(res.status).toBe(403);
    });

    it('leaves ordinary browser JWTs unaffected', async () => {
        // A browser JWT has no `scopes` claim and must keep the permissions its
        // role gives it, or the scope gate would break the website.
        const res = await rest()
            .patch('/assignment_field_submissions?assignment_submission_id=eq.1&assignment_field_slug=eq.secret')
            .set('Authorization', `Bearer ${studentJWT}`)
            .send({ body: 'foobarsecret-bright-fog' });
        expect([200, 204]).toContain(res.status);
    });

    it('stops exchanging once revoked', async () => {
        const created = await createToken('revocation test');
        const before = await exchange(created.token);
        expect(before.status).toBe(200);

        const listed = await rest()
            .get(`/user_api_tokens?token_prefix=eq.${created.token_prefix}`)
            .set('Authorization', `Bearer ${studentJWT}`);
        const id = listed.body[0].id;

        const revoked = await rest()
            .post('/rpc/revoke_user_api_token')
            .set('Authorization', `Bearer ${studentJWT}`)
            .send({ p_id: id });
        expect(revoked.status).toBe(200);

        const after = await exchange(created.token);
        expect(after.status).toBe(401);
    });

    it('records last_used_at so a forgotten token is visible', async () => {
        const created = await createToken('last used test');
        await exchange(created.token);
        const res = await rest()
            .get(`/user_api_tokens?token_prefix=eq.${created.token_prefix}`)
            .set('Authorization', `Bearer ${studentJWT}`);
        expect(res.body[0].last_used_at).not.toBeNull();
    });

    // ---------------------------------------------------------------
    // Bounds (issue #347)
    // ---------------------------------------------------------------
    // The reproduction from the issue, over HTTP: an ordinary student JWT
    // asking for a five year, write-capable credential in one call.
    it('refuses an expiry beyond the maximum', async () => {
        const fiveYears = new Date();
        fiveYears.setFullYear(fiveYears.getFullYear() + 5);
        const res = await rest()
            .post('/rpc/create_user_api_token')
            .set('Authorization', `Bearer ${studentJWT}`)
            .send({
                p_name: 'footgun probe',
                p_scopes: ['submissions:write'],
                p_expires_at: fiveYears.toISOString(),
            });
        // Refused, not clamped: a caller that asked for five years has to
        // learn it cannot have them.
        expect(res.status).toBe(400);
        expect(JSON.stringify(res.body)).toContain('at most 180 days');
    });

    // The count is a check-then-act, so without a lock on the caller's user
    // row two concurrent creates both read four active tokens and both insert.
    // Only a real second connection can show this, which is why it lives here
    // and not in the database tests: eight requests at once must still leave
    // exactly five tokens.
    it('never lets concurrent creates exceed the five token cap', async () => {
        const attempts = await Promise.all(
            Array.from({ length: 8 }, (unused, i) =>
                rest()
                    .post('/rpc/create_user_api_token')
                    .set('Authorization', `Bearer ${studentJWT}`)
                    .set('Accept', 'application/vnd.pgrst.object+json')
                    .send({ p_name: `race ${i}` })));

        const created = attempts.filter((r) => r.status === 200);
        const refused = attempts.filter((r) => r.status === 409);
        expect(created.length).toBe(5);
        expect(refused.length).toBe(3);
        expect(JSON.stringify(refused[0].body)).toContain('maximum of 5');

        const listed = await rest()
            .get('/user_api_tokens?is_active=is.true&select=id')
            .set('Authorization', `Bearer ${studentJWT}`);
        expect(listed.body.length).toBe(5);
    });
});
