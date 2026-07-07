/* global describe it before */

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const {
    getJWTForNetid,
    we,
} = require('./helpers.js');

describe('assignments API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    const syncPayload = [{
        slug: 'exam-1',
        title: 'Updated Exam',
        points_possible: 55,
        is_draft: false,
        is_markdown: false,
        is_team: false,
        body: 'updated body',
        closed_at: '3018-12-27T14:55:50Z',
        fields: [{
            slug: 'url',
            label: 'Updated repo',
            help: 'Updated help',
            placeholder: 'https://github.com/...',
            is_url: true,
            is_multiline: false,
            display_order: 1,
            pattern: 'https://.*',
            example: 'https://github.com/foo',
        }, {
            slug: 'new-field',
            label: 'New Field',
            help: 'New help',
            placeholder: 'value',
            is_url: false,
            is_multiline: false,
            display_order: 2,
            pattern: '.*',
            example: 'value',
        }],
    }, {
        slug: 'new-admin-assignment',
        title: 'New Admin Assignment',
        points_possible: 10,
        is_draft: true,
        is_markdown: false,
        is_team: false,
        body: 'new body',
        closed_at: '3018-12-28T14:55:50Z',
        fields: [{
            slug: 'repo-url',
            label: 'Repo URL',
            help: 'Repo help',
            placeholder: 'https://github.com/...',
            is_url: true,
            is_multiline: false,
            display_order: 0,
            pattern: 'https://.*',
            example: 'https://github.com/foo',
        }],
    }];

    const expectedDryRun = {
        inserted_count: 1,
        updated_count: 1,
        unchanged_count: 0,
        deleted_count: 0,
        field_inserted_count: 2,
        field_updated_count: 1,
        field_unchanged_count: 0,
        field_deleted_count: 2,
        dry_run: true,
    };

    const expectedApply = {
        ...expectedDryRun,
        dry_run: false,
    };

    const expectedRerun = {
        inserted_count: 0,
        updated_count: 0,
        unchanged_count: 2,
        deleted_count: 0,
        field_inserted_count: 0,
        field_updated_count: 0,
        field_unchanged_count: 3,
        field_deleted_count: 0,
        dry_run: false,
    };

    before(async () => {
        resetdb();
    });

    it('should not let anonymous users sync assignments', (done) => {
        restService()
            .post('/rpc/sync_assignments')
            .send({ p_assignments: [] })
            .expect(401, done);
    });

    it('should not let students sync assignments', async () => {
        const jwt = await studentJWTPromise;
        await restService()
            .post('/rpc/sync_assignments')
            .set('Authorization', `Bearer ${jwt}`)
            .send({ p_assignments: [] })
            .expect(403);
    });

    it('should let faculty dry-run assignment syncs', async () => {
        const jwt = await facultyJWTPromise;
        const response = await restService()
            .post('/rpc/sync_assignments')
            .set('Authorization', `Bearer ${jwt}`)
            .send({
                p_assignments: syncPayload,
                p_delete_missing: false,
                p_dry_run: true,
            })
            .expect(200);

        we.expect(response.body)
            .to.deep.equal([expectedDryRun]);

        const assignments = await restService()
            .get('/assignments?select=slug&order=slug')
            .set('Authorization', `Bearer ${jwt}`)
            .expect(200);

        we.expect(assignments.body.map(assignment => assignment.slug))
            .to.deep.equal(['exam-1', 'js-koans', 'project-update-1', 'team-selection']);
    });

    it('should let faculty apply assignment syncs idempotently', async () => {
        const jwt = await facultyJWTPromise;
        const response = await restService()
            .post('/rpc/sync_assignments')
            .set('Authorization', `Bearer ${jwt}`)
            .send({
                p_assignments: syncPayload,
                p_delete_missing: false,
                p_dry_run: false,
            })
            .expect(200);

        we.expect(response.body)
            .to.deep.equal([expectedApply]);

        const rerun = await restService()
            .post('/rpc/sync_assignments')
            .set('Authorization', `Bearer ${jwt}`)
            .send({
                p_assignments: syncPayload,
                p_delete_missing: false,
                p_dry_run: false,
            })
            .expect(200);

        we.expect(rerun.body)
            .to.deep.equal([expectedRerun]);

        const fields = await restService()
            .get('/assignment_fields?select=assignment_slug,slug&assignment_slug=in.(exam-1,new-admin-assignment)&order=assignment_slug,slug')
            .set('Authorization', `Bearer ${jwt}`)
            .expect(200);

        we.expect(fields.body.map(field => `${field.assignment_slug}/${field.slug}`))
            .to.deep.equal(['exam-1/new-field', 'exam-1/url', 'new-admin-assignment/repo-url']);

        const studentJWT = await studentJWTPromise;
        const studentAssignments = await restService()
            .get('/assignments?select=slug&order=slug')
            .set('Authorization', `Bearer ${studentJWT}`)
            .expect(200);

        we.expect(studentAssignments.body.map(assignment => assignment.slug))
            .to.deep.equal(['exam-1', 'project-update-1', 'team-selection']);

        const studentFields = await restService()
            .get('/assignment_fields?select=assignment_slug,slug&assignment_slug=in.(exam-1,new-admin-assignment)&order=assignment_slug,slug')
            .set('Authorization', `Bearer ${studentJWT}`)
            .expect(200);

        we.expect(studentFields.body.map(field => `${field.assignment_slug}/${field.slug}`))
            .to.deep.equal(['exam-1/new-field', 'exam-1/url']);
    });
});
