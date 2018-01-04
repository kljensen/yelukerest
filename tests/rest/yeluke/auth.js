/* global describe it before */

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
} = require('../common.js');
const request = require('supertest');
const {
    getUserSessionCookie,
    getJWT,
    we,
} = require('./helpers.js');


describe('authentication API endpoint', () => {
    const cleanup = (done) => {
        resetdb();
        done();
    }
    before(cleanup);

    it('login page should give a temporary redirect to the CAS server', async() => {
        await request(baseURL)
            .get(authPath)
            .expect('Location', /http/)
            .expect(307);
    });

    it('should create a session for a valid user', async() => {
        await getUserSessionCookie(baseURL, authPath, 'abc123', true);
    });

    it('should not create a session for an invalid user', async() => {
        const p = getUserSessionCookie(baseURL, authPath, 'invalid23', false);
        we.expect(p)
            .to.be.rejectedWith(Error);
    });

    it('should let valid users get a JWT', async() => {
        const cookie = await getUserSessionCookie(baseURL, authPath, 'abc123', true);
        const jwt = await getJWT(baseURL, jwtPath, [cookie]);
        we.expect(jwt)
            .to.be.a.singleLine();
        we.expect(jwt)
            .to.have.lengthOf.at.least(20);
    });

    it('should not let invalid users get a JWT', async() => {
        const getCookieAndJWT = async() => {
            const cookie = await getUserSessionCookie(baseURL, authPath, 'validuser', true);
            return getJWT(baseURL, jwtPath, [cookie]);
        };
        we.expect(getCookieAndJWT())
            .to.be.rejectedWith(Error);
    });
});
