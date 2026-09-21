/* global describe it before */

// The provisioning boundary as HTTP clients meet it (issue #394).
//
// tests/db/yeluke-assignment_repository_provisioning.sql proves the RPCs and
// the policies. This half sends real requests through Caddy and PostgREST
// with JWTs issued by the login flow, so what it proves is the refusals a
// student receives as status codes, that faculty configure a template with
// an ordinary PATCH, and that the configuration reaches the me-scoped view.
//
// Sample data in play: abc123 is student 1 on team bright-fog, klj39 is the
// faculty member; exam-1 is an open individual assignment whose `url` field
// is a URL field.

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const {
    getJWTForNetid,
    postRequestWithJWT,
    we,
} = require('./helpers.js');

const template = {
    repository_template_provider: 'github',
    repository_template_full_name: 'yale-mgt-656/exam-1-template',
    repository_url_field_slug: 'url',
};

describe('assignment repository provisioning over HTTP', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async () => {
        resetdb();
    });

    // Regression: the first cut of the migration added a second foreign key
    // between assignment and assignment_field, and PostgREST answered the
    // embed the web client makes on every page load with 300 PGRST201.
    it('still embeds assignment fields from assignments, and the reverse', async () => {
        const jwt = await studentJWTPromise;
        const assignments = await restService()
            .get('/assignments?order=closed_at&select=*,fields:assignment_fields(*)')
            .set('Authorization', `Bearer ${jwt}`)
            .expect('Content-Type', /json/)
            .expect(200);
        const exam = assignments.body.find(row => row.slug === 'exam-1');
        we.expect(exam.fields.map(field => field.slug).sort()).to.deep.equal(['fooword', 'profound', 'url']);

        const mine = await restService()
            .get('/my_assignments?slug=eq.exam-1&select=slug,fields:assignment_fields(slug)')
            .set('Authorization', `Bearer ${jwt}`)
            .expect(200);
        we.expect(mine.body[0].fields).to.have.lengthOf(3);

        const fields = await restService()
            .get('/assignment_fields?assignment_slug=eq.exam-1&select=slug,assignment:assignments(slug)')
            .set('Authorization', `Bearer ${jwt}`)
            .expect(200);
        we.expect(fields.body).to.have.lengthOf(3);
        we.expect(fields.body[0].assignment).to.deep.equal({ slug: 'exam-1' });
    });

    it('refuses a student who tries to configure a template', async () => {
        await restService()
            .patch('/assignments?slug=eq.exam-1')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .send(template)
            .expect(403);
    });

    it('refuses a student who tries to write a GitHub identity or its verification', async () => {
        await restService()
            .patch('/users?id=eq.1')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .send({ github_login: 'abc123', github_verified_at: '2026-01-01T00:00:00Z' })
            .expect(403);
    });

    it('refuses faculty who try to write a GitHub identity through the users view', async () => {
        await restService()
            .patch('/users?id=eq.1')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .send({ github_verified_at: '2026-01-01T00:00:00Z' })
            .expect(403);
    });

    it('refuses a student on every service RPC', async () => {
        const jwt = await studentJWTPromise;
        const calls = [
            ['/rpc/claim_repository_provisioning', { p_assignment_slug: 'exam-1', p_user_id: 1 }],
            ['/rpc/record_repository_provisioning', { p_attempt_id: 1, p_stage: 'failed' }],
            ['/rpc/finalize_repository_provisioning', { p_attempt_id: 1, p_repo_url: 'https://github.com/x/y' }],
            ['/rpc/touch_repository_provisioning_readiness', { p_attempt_id: 1, p_ready: true }],
            ['/rpc/set_user_github_identity', {
                p_user_id: 1, p_github_user_id: 1, p_github_login: 'abc123', p_verified: true,
            }],
            ['/rpc/import_github_logins', { p_assignment_slug: 'team-selection', p_field_slug: 'secret' }],
        ];
        for (const [path, body] of calls) {
            // eslint-disable-next-line no-await-in-loop
            await postRequestWithJWT(path, body, jwt).expect(403);
        }
        await postRequestWithJWT(calls[0][0], calls[0][1], undefined).expect(401);
    });

    it('lets faculty configure a template through the assignments view', async () => {
        const jwt = await facultyJWTPromise;
        const response = await restService()
            .patch('/assignments?slug=eq.exam-1&select=slug,repository_template_provider,repository_template_full_name,repository_url_field_slug')
            .set('Authorization', `Bearer ${jwt}`)
            .set('Prefer', 'return=representation')
            .send(template)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body).to.deep.equal([{ slug: 'exam-1', ...template }]);
    });

    it('refuses a template whose field is not a URL field', async () => {
        await restService()
            .patch('/assignments?slug=eq.exam-1')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .send({ ...template, repository_url_field_slug: 'profound' })
            .expect(400);
    });

    it('shows the template columns on my_assignments to a student', async () => {
        const response = await restService()
            .get('/my_assignments?slug=eq.exam-1')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body).to.have.lengthOf(1);
        we.expect(response.body[0]).to.include({ slug: 'exam-1', ...template });

        const unconfigured = await restService()
            .get('/my_assignments?slug=eq.team-selection')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(unconfigured.body[0]).to.include({
            repository_template_provider: null,
            repository_template_full_name: null,
            repository_url_field_slug: null,
        });
    });

    it('classifies a student submission as student whatever origin it claims', async () => {
        const jwt = await studentJWTPromise;
        const submission = await restService()
            .post('/assignment_submissions')
            .set('Authorization', `Bearer ${jwt}`)
            .set('Accept', 'application/vnd.pgrst.object+json')
            .set('Prefer', 'return=representation')
            .send({ assignment_slug: 'exam-1' })
            .expect(201);
        const field = await restService()
            .post('/assignment_field_submissions')
            .set('Authorization', `Bearer ${jwt}`)
            .set('Accept', 'application/vnd.pgrst.object+json')
            .set('Prefer', 'return=representation')
            .send({
                assignment_submission_id: submission.body.id,
                assignment_field_slug: 'url',
                assignment_slug: 'exam-1',
                body: 'https://github.com/abc123/forged',
                origin: 'provisioning',
            })
            .expect(201);
        we.expect(field.body.origin).to.equal('student');
    });
});
