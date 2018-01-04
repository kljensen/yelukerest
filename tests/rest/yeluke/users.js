/* global describe it before */

const {
    getJWTForNetid,
    makePostTestCases,
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
    let student1JWT;
    let facultyJWT;

    before(async() => {
        resetdb();
        try {
            student1JWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
            facultyJWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
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
            .set('Authorization', `Bearer ${student1JWT}`)
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
            .set('Authorization', `Bearer ${student1JWT}`)
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


});
