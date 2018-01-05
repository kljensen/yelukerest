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
    getJWTForNetid,
    we,
} = require('./helpers.js');

process.on('unhandledRejection', (r) => {
    console.error('Caught an unhandledRejection!');
    console.error(r);
});

describe('authentication API endpoint', () => {
    const cleanup = (done) => {
        resetdb();
        done();
    }
    before(cleanup);

    it('login page should give a temporary redirect to the CAS server', async() => {
        try {
            await request(baseURL)
                .get(authPath)
                .expect('Location', /http/)
                .expect(307);
        } catch (error) {
            throw error;
        }
    });

    it('should create a session for a valid user', async() => {
        try {
            await getUserSessionCookie(baseURL, authPath, 'abc123', true);
        } catch (error) {
            throw error;
        }
    });

    it('should not create a session for an invalid user', async() => {
        try {
            const p = getUserSessionCookie(baseURL, authPath, 'invalid23', false);
            we.expect(p)
                .to.be.rejected;
        } catch (error) {
            throw error;
        }
    });

    it('should let valid users get a JWT', async() => {
        let jwt;
        try {
            jwt = await getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
        } catch (error) {
            throw error;
        }
        we.expect(jwt)
            .to.be.a.singleLine();
        we.expect(jwt)
            .to.have.lengthOf.at.least(20);
    });

    it('should not let invalid users get a JWT', async() => {
        let jwt;
        try {
            jwt = await getJWTForNetid(baseURL, authPath, jwtPath, 'invalid234');
        } catch (error) {
            throw error;
        }
        we.expect(jwt)
            .to.be.undefined();
    });
});
