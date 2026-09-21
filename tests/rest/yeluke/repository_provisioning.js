/* global describe it before */

// The repository boundary as HTTP clients meet it (issue #394, roadmap 17).
//
// tests/db/yeluke-repository_provisioning.sql proves the RPCs and the
// policies. This half sends real requests through Caddy and PostgREST with
// JWTs issued by the login flow, so what it proves is the refusals a student
// receives as status codes, that faculty configure a template with an
// ordinary POST, and that a student's repositories reach the me-scoped view
// with their browser URL.
//
// Sample data in play: abc123 is student 1 on team bright-fog, klj39 is the
// faculty member; exam-1 is an open individual assignment.

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
    postRequestWithJWT,
    we,
} = require('./helpers.js');

const template = {
    slug: 'exam-1-starter',
    template_full_name: 'yale-mgt-656/exam-1-starter',
    label: 'Exam 1 starter',
    assignment_slug: 'exam-1',
};

describe('repository templates and provisioning over HTTP', () => {
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

    it('refuses a student who tries to create a template', async () => {
        await restService()
            .post('/repository_templates')
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
            ['/rpc/claim_repository_provisioning', { p_template_slug: 'exam-1-starter', p_user_id: 1 }],
            ['/rpc/record_repository_provisioning', { p_attempt_id: 1, p_stage: 'failed' }],
            ['/rpc/finalize_repository_provisioning', { p_attempt_id: 1 }],
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

    it('lets faculty create a template through the repository_templates view', async () => {
        const jwt = await facultyJWTPromise;
        const response = await restService()
            .post('/repository_templates?select=slug,provider,template_full_name,label,description,is_team,assignment_slug,is_active')
            .set('Authorization', `Bearer ${jwt}`)
            .set('Prefer', 'return=representation')
            .send(template)
            .expect('Content-Type', /json/)
            .expect(201);
        we.expect(response.body).to.deep.equal([{
            ...template,
            provider: 'github',
            description: null,
            is_team: false,
            is_active: true,
        }]);
    });

    it('refuses a team template on an individual assignment', async () => {
        await restService()
            .post('/repository_templates')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .send({ ...template, slug: 'wrong-kind', is_team: true })
            .expect(409);
    });

    it('shows active templates to a student, and my_assignments carries no template columns', async () => {
        const jwt = await studentJWTPromise;
        const templates = await restService()
            .get('/repository_templates?select=slug,label,assignment_slug')
            .set('Authorization', `Bearer ${jwt}`)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(templates.body).to.deep.equal([{ slug: 'exam-1-starter', label: 'Exam 1 starter', assignment_slug: 'exam-1' }]);

        const mine = await restService()
            .get('/my_assignments?slug=eq.exam-1')
            .set('Authorization', `Bearer ${jwt}`)
            .expect(200);
        we.expect(mine.body).to.have.lengthOf(1);
        we.expect(mine.body[0]).to.not.have.any.keys(
            'repository_template_provider', 'repository_template_full_name', 'repository_url_field_slug',
        );
    });

    it('lists the caller\'s repositories on my_repositories with the browser URL', async () => {
        // Rows as the service's finalize, or the old tooling, would leave
        // them: one of the student's own, one of their team's, one of
        // somebody else's.
        runSQL(`
            INSERT INTO data.repository_template (slug, template_full_name, label, is_team, assignment_slug)
            VALUES ('project-starter', 'yale-mgt-656/project-starter', 'Project starter', true, 'project-update-1');
            INSERT INTO data.assignment_repository (template_slug, assignment_slug, is_team, user_id, team_nickname, provider_repo_id, provider_full_name)
            VALUES
                ('exam-1-starter', 'exam-1', false, 1, NULL, 700001, 'yale-mgt-656/exam-1-starter-abc123'),
                ('exam-1-starter', 'exam-1', false, 2, NULL, 700002, 'yale-mgt-656/exam-1-starter-bde456'),
                ('project-starter', 'project-update-1', true, NULL, 'bright-fog', 700003, 'yale-mgt-656/project-starter-bright-fog');
        `);
        const response = await restService()
            .get('/my_repositories?select=template_slug,label,assignment_slug,is_team,team_nickname,repo_url&order=template_slug')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body).to.deep.equal([
            {
                template_slug: 'exam-1-starter',
                label: 'Exam 1 starter',
                assignment_slug: 'exam-1',
                is_team: false,
                team_nickname: null,
                repo_url: 'https://github.com/yale-mgt-656/exam-1-starter-abc123',
            },
            {
                template_slug: 'project-starter',
                label: 'Project starter',
                assignment_slug: 'project-update-1',
                is_team: true,
                team_nickname: 'bright-fog',
                repo_url: 'https://github.com/yale-mgt-656/project-starter-bright-fog',
            },
        ]);

        // klj39 is on bright-fog too, so "mine" for faculty is the team's
        // repository and nobody's individual one.
        const faculty = await restService()
            .get('/my_repositories?select=template_slug')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(faculty.body).to.deep.equal([{ template_slug: 'project-starter' }]);
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
