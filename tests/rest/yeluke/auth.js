/* eslint-disable no-useless-catch */
/* eslint-disable no-console */

const request = require('supertest');
const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
} = require('../common.js');
const {
    getUserSessionCookie,
    getJWT,
    getJWTForNetid,
    we,
} = require('./helpers.js');

process.on('unhandledRejection', (r) => {
    console.error('Caught an unhandledRejection!');
    console.error(r);
});

const mePath = '/auth/me';

const decodeJWTPayload = (jwt) => {
    const payload = jwt.split('.')[1];
    const base64 = payload.replace(/-/g, '+')
        .replace(/_/g, '/');
    const paddingLength = (4 - (base64.length % 4)) % 4;
    const padded = base64.padEnd(base64.length + paddingLength, '=');
    return JSON.parse(Buffer.from(padded, 'base64')
        .toString('utf8'));
};

describe('authentication API endpoint', () => {
    const cleanup = (done) => {
        resetdb();
        done();
    };
    before(cleanup);

    it('login page should give a temporary redirect to the CAS server', async () => {
        try {
            await request(baseURL)
                .get(authPath)
                .expect('Location', /http/)
                .expect(302);
        } catch (error) {
            throw error;
        }
    });

    it('should reject auth info requests without a session', async () => {
        try {
            await request(baseURL)
                .get(mePath)
                .expect(401);
            await request(baseURL)
                .get(jwtPath)
                .expect(401);
        } catch (error) {
            throw error;
        }
    });

    it('should create a session for a valid user', async () => {
        try {
            await getUserSessionCookie(baseURL, authPath, 'abc123', true);
        } catch (error) {
            throw error;
        }
    });

    it('should not create a session for an invalid user', async () => {
        try {
            const p = await getUserSessionCookie(baseURL, authPath, 'invalid23', false);
            we.expect(p)
                .to.be.null();
        } catch (error) {
            console.log(error);
            throw error;
        }
    });

    it('should let valid users get a JWT', async () => {
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

    it('should return current user data from /auth/me', async () => {
        let cookie;
        let response;
        try {
            cookie = await getUserSessionCookie(baseURL, authPath, 'abc123', true);
            response = await request(baseURL)
                .get(mePath)
                .set('Cookie', [cookie])
                .accept('application/json')
                .expect(200);
        } catch (error) {
            throw error;
        }

        we.expect(response.body)
            .to.include({
                id: 1,
                netid: 'abc123',
                role: 'student',
            });
        we.expect(response.body.jwt)
            .to.be.a.singleLine();

        const payload = decodeJWTPayload(response.body.jwt);
        we.expect(payload)
            .to.include({
                user_id: 1,
                role: 'student',
            });
        we.expect(payload.exp)
            .to.be.above(Math.floor(Date.now() / 1000));
    });

    it('should sign JWTs with the user id, role, and expiry claims', async () => {
        let jwt;
        try {
            jwt = await getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
        } catch (error) {
            throw error;
        }

        const payload = decodeJWTPayload(jwt);
        we.expect(payload)
            .to.include({
                user_id: 1,
                role: 'student',
            });
        we.expect(payload.exp)
            .to.be.above(Math.floor(Date.now() / 1000));
    });

    it('should let observer users authenticate and receive observer JWTs', async () => {
        let cookie;
        let jwt;
        try {
            cookie = await getUserSessionCookie(baseURL, authPath, 'crt43', true);
            jwt = await getJWT(baseURL, jwtPath, [cookie]);
        } catch (error) {
            throw error;
        }

        const payload = decodeJWTPayload(jwt);
        we.expect(payload)
            .to.include({
                user_id: 5,
                role: 'observer',
            });
    });

    it('should not let invalid users get a JWT', async () => {
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
