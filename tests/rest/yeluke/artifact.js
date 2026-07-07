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
    makeListTestCases,
    we,
} = require('./helpers.js');

describe('artifacts API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async () => {
        resetdb();
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/artifacts')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    const listTestCases = [{
        title: 'should allow students to see only their own visible artifacts',
        expected: ['quiz-1-scan'],
        length: 1,
        status: 200,
        jwt: studentJWTPromise,
        path: '/artifacts?order=slug',
        transformation: artifact => artifact.slug,
    }, {
        title: 'should allow faculty to see all artifacts',
        expected: [1, 2, 3],
        length: 3,
        status: 200,
        jwt: facultyJWTPromise,
        path: '/artifacts?order=id',
        transformation: artifact => artifact.id,
    }];

    makeListTestCases(it, '/artifacts', artifact => artifact.id, listTestCases);

    it('should allow faculty to create artifact metadata', async () => {
        const jwt = await facultyJWTPromise;
        const response = await restService()
            .post('/artifacts')
            .set('Authorization', `Bearer ${jwt}`)
            .set('Prefer', 'return=representation')
            .send({
                user_id: 1,
                quiz_id: 1,
                slug: 'faculty-rest-created',
                title: 'Faculty REST Created',
                url: 'https://example.com/yelukerest/artifacts/faculty-rest-created.pdf',
            })
            .expect(201);

        we.expect(response.body)
            .to.have.lengthOf(1);
        we.expect(response.body[0].slug)
            .to.equal('faculty-rest-created');
    });

    it('should not allow students to create artifact metadata', async () => {
        const jwt = await studentJWTPromise;
        await restService()
            .post('/artifacts')
            .set('Authorization', `Bearer ${jwt}`)
            .send({
                user_id: 1,
                quiz_id: 1,
                slug: 'student-rest-created',
                title: 'Student REST Created',
                url: 'https://example.com/yelukerest/artifacts/student-rest-created.pdf',
            })
            .expect(403);
    });
});
