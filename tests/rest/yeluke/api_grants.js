/* global describe it before after */

// Data grants for consuming apps over HTTP (issue #387, ADR 0005).
//
// tests/db/yeluke-api-grants.sql proves the reader and the pre-request hook
// against the settings PostgREST would send. This half sends real requests
// through Caddy and PostgREST with credentials signed the way
// api.create_api_grant signs them, so what it proves is the boundary as a
// consumer meets it: which methods and paths a grant credential can use, what
// the query string can and cannot reach, what a row looks like on the wire,
// and that revoking or expiring the grant stops a token whose exp is still in
// the future.
//
// Sample data in play: team-selection is an individual assignment with one
// field, secret, submitted by users 1, 2 and 3; project-update-1 is a team
// assignment with fields repo-url and update-url, submitted once by
// bright-fog; js-koans also has a field called repo-url and no submissions,
// so one is added here. klj39 is the only faculty member.

const {
    resetdb,
    runSQL,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const {
    getJWTForNetid,
    we,
} = require('./helpers.js');

const READER = '/rpc/granted_submissions';
const ROW_KEYS = ['assignment_slug', 'submission_id', 'is_team', 'created_at', 'updated_at', 'identity', 'fields'];
const FAR_FUTURE_EXP = 4102444800; // 2100-01-01

// The payload of a JWT, without verifying it: the tests below take a real
// credential's claims, change one, and have the database sign the result.
const claimsOf = token => JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));

// Sign claims with the course jwt_secret, inside the database, the way
// auth.sign_grant_jwt does. The secret never leaves the database. The token
// is the last line of psql's output, after anything a .psqlrc prints.
const signClaims = (claims) => {
    const json = JSON.stringify(claims).replace(/'/g, "''");
    return runSQL(`\\t on\n\\a\nSELECT pgjwt.sign('${json}'::json, settings.get('jwt_secret'));`)
        .trim().split('\n').pop();
};

describe('api grants over HTTP', () => {
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
    let facultyJWT;

    const asFaculty = req => req.set('Authorization', `Bearer ${facultyJWT}`);
    const readWith = (token, query = '') => restService()
        .get(`${READER}${query}`)
        .set('Authorization', `Bearer ${token}`);

    async function createGrant(name, assignments, expiresAt) {
        const body = { p_name: name, p_assignments: assignments };
        if (expiresAt) {
            body.p_expires_at = expiresAt;
        }
        const response = await asFaculty(restService().post('/rpc/create_api_grant'))
            .set('Accept', 'application/vnd.pgrst.object+json')
            .send(body)
            .expect(200);
        we.expect(response.body.token.split('.')).to.have.lengthOf(3);
        return response.body;
    }

    async function revokeGrant(id) {
        await asFaculty(restService().post('/rpc/revoke_api_grant'))
            .send({ p_id: id })
            .expect(200);
    }

    // netid only on team-selection: the identity attributes name, nickname
    // and team_nickname exist for those submitters and are not granted.
    let secrets;
    // team_nickname and repo-url on project-update-1: update-url is not granted.
    let teamRepos;
    // repo-url on js-koans, which shares that field slug with project-update-1.
    let koansRepos;

    before(async () => {
        resetdb();
        facultyJWT = await facultyJWTPromise;
        runSQL(`
            INSERT INTO data.assignment_submission (id, assignment_slug, is_team, user_id, submitter_user_id)
            VALUES (9201, 'js-koans', false, 2, 2);
            INSERT INTO data.assignment_field_submission
                (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
            VALUES (9201, 'repo-url', 'js-koans', 'https://github.com/bob/koans', 'staff');
        `);
        secrets = await createGrant('secrets app',
            [{ assignment_slug: 'team-selection', identity: ['netid'], field_slugs: ['secret'] }]);
        teamRepos = await createGrant('team repos app',
            [{ assignment_slug: 'project-update-1', identity: ['team_nickname'], field_slugs: ['repo-url'] }]);
        koansRepos = await createGrant('koans app',
            [{ assignment_slug: 'js-koans', identity: [], field_slugs: ['repo-url'] }]);
    });

    after(() => {
        runSQL(`
            DELETE FROM data.assignment_field_submission WHERE assignment_submission_id = 9201;
            DELETE FROM data.assignment_submission WHERE id = 9201;
        `);
    });

    // ---------------------------------------------------------------
    // Wire shape
    // ---------------------------------------------------------------
    it('returns a JSON array of rows with no wrapper column', async () => {
        const response = await readWith(secrets.token, '?p_assignment_slug=team-selection')
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body).to.be.an('array').with.lengthOf(3);
        response.body.forEach(row => we.expect(row).to.have.all.keys(ROW_KEYS));
        const [row] = response.body;
        we.expect(row).to.include({ assignment_slug: 'team-selection', submission_id: 1, is_team: false });
        we.expect(row.identity).to.deep.equal({ netid: 'abc123' });
        we.expect(row.fields).to.have.all.keys('secret');
        we.expect(row.fields.secret).to.have.all.keys('body', 'updated_at');
        we.expect(row.fields.secret.body).to.equal('foobarsecret-bright-fog');
    });

    it('answers HEAD', async () => {
        const response = await restService()
            .head(`${READER}?p_assignment_slug=team-selection`)
            .set('Authorization', `Bearer ${secrets.token}`)
            .expect(200);
        we.expect(response.text || '').to.equal('');
    });

    it('shows a team submission as its team, with only the granted field', async () => {
        const response = await readWith(teamRepos.token).expect(200);
        we.expect(response.body).to.have.lengthOf(1);
        const [row] = response.body;
        we.expect(row).to.include({ assignment_slug: 'project-update-1', submission_id: 4, is_team: true });
        we.expect(row.identity).to.deep.equal({ team_nickname: 'bright-fog' });
        we.expect(row.fields).to.have.all.keys('repo-url');
        we.expect(JSON.stringify(response.body)).to.not.contain('fakedoc');
    });

    it('lists grants to faculty without their credentials', async () => {
        const response = await asFaculty(restService().get(`/api_grants?id=eq.${secrets.id}`))
            .expect(200);
        we.expect(response.body).to.have.lengthOf(1);
        we.expect(Object.keys(response.body[0])).to.not.include('token');
        we.expect(JSON.stringify(response.body)).to.not.contain(secrets.token);
        we.expect(response.body[0].permissions).to.deep.equal(
            [{ assignment_slug: 'team-selection', identity: ['netid'], field_slugs: ['secret'] }]);
    });

    // ---------------------------------------------------------------
    // Method and path
    // ---------------------------------------------------------------
    it('refuses POST, PATCH and DELETE to the reader', async () => {
        const post = await restService().post(READER)
            .set('Authorization', `Bearer ${secrets.token}`)
            .send({ p_assignment_slug: 'team-selection' });
        we.expect(post.status).to.equal(403);
        we.expect(JSON.stringify(post.body)).to.contain('only read');

        // PostgREST itself refuses these on an RPC path, before the hook.
        const patch = await restService().patch(READER)
            .set('Authorization', `Bearer ${secrets.token}`)
            .send({});
        we.expect(patch.status).to.equal(405);

        const del = await restService().delete(READER)
            .set('Authorization', `Bearer ${secrets.token}`);
        we.expect(del.status).to.equal(405);
    });

    it('refuses every other RPC, whether read or written', async () => {
        // A call PostgREST resolves (the parameters match an overload) reaches
        // the hook, which refuses the path; the grant it names is untouched.
        const revoke = await restService().get(`/rpc/revoke_api_grant?p_id=${teamRepos.id}`)
            .set('Authorization', `Bearer ${secrets.token}`);
        we.expect(revoke.status).to.equal(403);
        we.expect(JSON.stringify(revoke.body)).to.contain('only call granted_submissions');
        await readWith(teamRepos.token).expect(200);

        // A write is refused on its method, before its path is considered.
        const create = await restService().post('/rpc/create_api_grant')
            .set('Authorization', `Bearer ${secrets.token}`)
            .send({ p_name: 'escalation', p_assignments: [{ assignment_slug: 'exam-1', identity: ['netid'], field_slugs: ['url'] }] });
        we.expect(create.status).to.equal(403);
        we.expect(JSON.stringify(create.body)).to.contain('only read');
        we.expect(Object.keys(create.body)).to.not.include('token');
    });

    it('refuses every table and view URL', async () => {
        const paths = [
            '/assignment_submissions',
            '/assignment_field_submissions',
            '/users',
            '/api_grants',
            '/my_assignments',
            '/',
        ];
        for (const path of paths) {
            // eslint-disable-next-line no-await-in-loop
            const response = await restService().get(path)
                .set('Authorization', `Bearer ${secrets.token}`);
            we.expect(response.status, path).to.equal(403);
            we.expect(JSON.stringify(response.body), path).to.not.contain('foobarsecret');
        }
    });

    it('does not let a person call the reader', async () => {
        const response = await asFaculty(restService().get(READER));
        we.expect(response.status).to.equal(403);
        we.expect(JSON.stringify(response.body)).to.contain('permission denied');
    });

    // ---------------------------------------------------------------
    // Isolation
    // ---------------------------------------------------------------
    it('reads nothing for an assignment the grant does not cover', async () => {
        const response = await readWith(secrets.token, '?p_assignment_slug=project-update-1')
            .expect(200);
        we.expect(response.body).to.deep.equal([]);
    });

    it('grants a reused field slug on one assignment only', async () => {
        // The koans grant covers repo-url on js-koans. project-update-1 has
        // a submitted repo-url too, and it stays out of reach.
        const koans = await readWith(koansRepos.token).expect(200);
        we.expect(koans.body.map(row => row.assignment_slug)).to.deep.equal(['js-koans']);
        we.expect(koans.body[0].fields['repo-url'].body).to.equal('https://github.com/bob/koans');

        const other = await readWith(koansRepos.token, '?p_assignment_slug=project-update-1')
            .expect(200);
        we.expect(other.body).to.deep.equal([]);
    });

    it('keeps an ungranted identity attribute out of reach of the query string', async () => {
        // Alice Miller (name) and bright-horse (nickname) belong to the
        // submitter of row 1; only netid was granted.
        const probes = [
            '?p_assignment_slug=team-selection&select=identity',
            '?p_assignment_slug=team-selection&select=identity->>name',
            '?p_assignment_slug=team-selection&select=granted_submissions->identity->>name',
            '?p_assignment_slug=team-selection&identity->>name=eq.Alice%20Miller',
            '?p_assignment_slug=team-selection&granted_submissions->identity->>name=eq.Alice%20Miller',
            '?p_assignment_slug=team-selection&order=identity->>name',
            '?p_assignment_slug=team-selection&select=*,user(*)',
            '?p_assignment_slug=team-selection&select=*,assignment_submission(*)',
            '?p_assignment_slug=team-selection&user_id=eq.1',
            '?p_assignment_slug=team-selection&p_identity=name',
        ];
        for (const query of probes) {
            // eslint-disable-next-line no-await-in-loop
            const response = await readWith(secrets.token, query);
            // There is no column for the query string to name (400) and no
            // other overload for an extra argument to select (404).
            we.expect(response.status, query).to.be.oneOf([400, 404]);
            const text = JSON.stringify(response.body);
            we.expect(text, query).to.not.contain('Alice Miller');
            we.expect(text, query).to.not.contain('bright-horse');
        }
    });

    // ---------------------------------------------------------------
    // Paging and limits
    // ---------------------------------------------------------------
    it('pages by submission id with p_after_id', async () => {
        const first = await readWith(secrets.token, '?p_assignment_slug=team-selection&p_limit=2')
            .expect(200);
        we.expect(first.body.map(row => row.submission_id)).to.deep.equal([1, 2]);

        const second = await readWith(secrets.token, '?p_assignment_slug=team-selection&p_limit=2&p_after_id=2')
            .expect(200);
        we.expect(second.body.map(row => row.submission_id)).to.deep.equal([3]);

        const third = await readWith(secrets.token, '?p_assignment_slug=team-selection&p_limit=2&p_after_id=3')
            .expect(200);
        we.expect(third.body).to.deep.equal([]);
    });

    it('refuses a zero or negative p_limit and caps one above 500', async () => {
        const zero = await readWith(secrets.token, '?p_limit=0');
        we.expect(zero.status).to.equal(400);
        we.expect(JSON.stringify(zero.body)).to.contain('positive integer');

        const negative = await readWith(secrets.token, '?p_limit=-1');
        we.expect(negative.status).to.equal(400);

        // Capped, not refused: a consumer asking for more than 500 gets a page.
        const over = await readWith(secrets.token, '?p_limit=501').expect(200);
        we.expect(over.body).to.have.lengthOf(3);
    });

    // ---------------------------------------------------------------
    // Lifecycle: the token still verifies, the grant no longer stands
    // ---------------------------------------------------------------
    it('stops a revoked grant, and an empty page still needs a live grant', async () => {
        const grant = await createGrant('revoked app',
            [{ assignment_slug: 'team-selection', identity: [], field_slugs: ['secret'] }]);
        await readWith(grant.token).expect(200);
        const empty = await readWith(grant.token, '?p_assignment_slug=exam-1').expect(200);
        we.expect(empty.body).to.deep.equal([]);

        await revokeGrant(grant.id);

        const after = await readWith(grant.token);
        we.expect(after.status).to.equal(403);
        we.expect(JSON.stringify(after.body)).to.contain('revoked or has expired');
        const emptyAfter = await readWith(grant.token, '?p_assignment_slug=exam-1');
        we.expect(emptyAfter.status).to.equal(403);
    });

    it('stops a grant that has expired in the database under a token with a future exp', async () => {
        const expiresAt = new Date(Date.now() + 3000).toISOString();
        const grant = await createGrant('short-lived app',
            [{ assignment_slug: 'team-selection', identity: [], field_slugs: ['secret'] }],
            expiresAt);
        // The same claims as the issued credential, with an exp far in the
        // future: only the grant row can refuse this one.
        const longToken = signClaims({ ...claimsOf(grant.token), exp: FAR_FUTURE_EXP });
        await readWith(longToken).expect(200);

        await new Promise(resolve => setTimeout(resolve, 3500));

        const response = await readWith(longToken);
        we.expect(response.status).to.equal(403);
        we.expect(JSON.stringify(response.body)).to.contain('revoked or has expired');
    });

    it('refuses a grant id that does not exist', async () => {
        const token = signClaims({ ...claimsOf(secrets.token), grant_id: 987654, sub: 'grant:987654' });
        const response = await readWith(token);
        we.expect(response.status).to.equal(403);
        we.expect(JSON.stringify(response.body)).to.contain('revoked or has expired');
    });

    // ---------------------------------------------------------------
    // Claims: each fails closed on its own
    // ---------------------------------------------------------------
    it('refuses a credential whose signature does not verify', async () => {
        // A character from the middle of the signature: the last one holds
        // padding bits a decoder ignores, so changing it may change nothing.
        const [header, payload, signature] = secrets.token.split('.');
        const at = 5;
        const flipped = signature[at] === 'A' ? 'B' : 'A';
        const tampered = `${header}.${payload}.${signature.slice(0, at)}${flipped}${signature.slice(at + 1)}`;
        const response = await readWith(tampered);
        we.expect(response.status).to.equal(401);
    });

    it('refuses each malformed claim', async () => {
        // Each is the issued credential's own claims with one changed, signed
        // with the real secret, so only that claim can be what is refused.
        const good = claimsOf(secrets.token);
        const without = (claims, key) => Object.fromEntries(Object.entries(claims).filter(([k]) => k !== key));
        const cases = [
            { title: 'a missing grant_id', claims: without(good, 'grant_id'), message: 'invalid grant_id claim' },
            { title: 'grant_id 0', claims: { ...good, grant_id: 0, sub: 'grant:0' }, message: 'invalid grant_id claim' },
            { title: 'a user subject', claims: { ...good, sub: 'user:3' }, message: 'invalid jwt subject' },
            { title: 'another grant in sub', claims: { ...good, sub: `grant:${teamRepos.id}` }, message: 'invalid jwt subject' },
            { title: 'a missing subject', claims: without(good, 'sub'), message: 'missing jwt subject' },
            { title: 'a wrong audience', claims: { ...good, aud: 'somewhere-else' }, message: 'invalid jwt audience' },
            { title: 'a missing audience', claims: without(good, 'aud'), message: 'invalid jwt audience' },
            { title: 'a wrong issuer', claims: { ...good, iss: 'someone-else' }, message: 'invalid jwt issuer' },
            { title: 'a missing exp', claims: without(good, 'exp'), message: 'invalid exp claim' },
        ];
        for (const tc of cases) {
            // eslint-disable-next-line no-await-in-loop
            const response = await readWith(signClaims(tc.claims));
            we.expect(response.status, tc.title).to.equal(403);
            we.expect(JSON.stringify(response.body), tc.title).to.contain(tc.message);
        }

        // A string exp never reaches the hook: PostgREST refuses it first.
        const stringExp = await readWith(signClaims({ ...good, exp: String(FAR_FUTURE_EXP) }));
        we.expect(stringExp.status).to.equal(401);
    });
});
