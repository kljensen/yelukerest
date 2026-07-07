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

describe('assignment_field_submissions API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');

    before(async () => {
        resetdb();
    });

    it('should report one returned row for a broad student PATCH narrowed by RLS', async () => {
        const jwt = await studentJWTPromise;
        const response = await restService()
            .patch('/assignment_field_submissions?assignment_slug=eq.team-selection&select=assignment_submission_id,assignment_field_slug,assignment_slug,body')
            .set('Authorization', `Bearer ${jwt}`)
            .set('Prefer', 'return=representation')
            .send({ body: 'rest-row-count-secret' })
            .expect('Content-Type', /json/)
            .expect(200);

        we.expect(response.body)
            .to.deep.equal([{
                assignment_submission_id: 1,
                assignment_field_slug: 'secret',
                assignment_slug: 'team-selection',
                body: 'rest-row-count-secret',
            }]);
    });
});
