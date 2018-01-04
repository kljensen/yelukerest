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
} = require('./helpers.js');

describe('engagements', () => {
    // eslint-disable-next-line no-unsed-vars
    let student1JWT;
    let student2JWT;
    let facultyJWT;

    before(async() => {
        resetdb();
        try {
            student1JWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
            student2JWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'bde456');
            facultyJWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
        } catch (error) {
            /* eslint-disable-next-line no-console */
            console.error('Could not get JWTs for users');
            process.exit(1);
        }
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/engagements')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    it('should not be query-able to anonymous visitors', (done) => {
        restService()
            .get('/engagements?id=eq.1')
            .expect('Content-Type', /json/)
            // Notice how PostgREST has 400's in some cases where it seems
            // like it should have 401. This is annoying. There is some info
            // about similar problems https://github.com/begriffs/postgrest/issues?utf8=%E2%9C%93&q=400+401
            .expect(400, done);
    });

    it('should not be query-able to anonymous visitors', async() => {});

    const newEngagement = {
        id: 100,
        slug: 'intro',
        summary: 'summary_2_2_2',
        description: 'description_1_',
        begins_at: '2017-12-27T14:54:50+00:00',
        duration: '00:00:03',
        is_draft: false,
        created_at: '2017-12-27T14:54:50+00:00',
        updated_at: '2017-12-27T22:09:47.089125+00:00',
    };

    it('should not accept other HTTP verbs', (done) => {
        restService()
            .post('/engagements')
            .send(newEngagement)
            .expect(400, done);
    });

    it('should not accept invalid POST requests', (done) => {
        restService()
            .post('/engagements')
            .send({})
            .expect(401, done);
    });
});
