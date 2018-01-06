/* global describe it before */

const {
    getJWTForNetid,
    makeListTestCases,
    we,
} = require('./helpers.js');

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const mountPoint = '/users';

describe('users API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
    let studentJWT;

    before(async() => {
        resetdb();
        try {
            studentJWT = await studentJWTPromise;
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('Could not get JWTs for users');
            process.exit(1);
        }
    });


    it('should NOT be accessable to anonymous users', async() => {
        return restService()
            .get(mountPoint)
            .expect(401);
    });

    it('should allow authenticated students to see only themselves', async() => {
        const response = await restService()
            .get(mountPoint)
            .set('Authorization', `Bearer ${studentJWT}`)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body)
            .to.be.a.instanceOf(Array);
        we.expect(response.body)
            .to.have.lengthOf(1);
        const userIds = new Set(response.body.map(x => x.user_id));
        we.expect(userIds.size)
            .to.equal(1);
    });

    it('should allow authenticated students to see only themselves', async() => {
        const response = await restService()
            .get(mountPoint)
            .set('Authorization', `Bearer ${studentJWT}`)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body)
            .to.be.a.instanceOf(Array);
        we.expect(response.body)
            .to.have.lengthOf(1);
        const userIds = new Set(response.body.map(x => x.user_id));
        we.expect(userIds.size)
            .to.equal(1);
    });

    const listTestCases = [{
        title: 'should NOT allow anonymous users to see anybody',
        status: 401,
    }, {
        title: 'should allow students to see only themselves',
        set: [1, 2, 3],
        length: 9,
        status: 200,
        jwt: facultyJWTPromise,
    }];

    makeListTestCases(it, '/engagements', (x => x.user_id), listTestCases);
});
