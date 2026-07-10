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
const apiJSONPath = '/auth/api.json';

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
                .expect(307);
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
            await request(baseURL)
                .get(apiJSONPath)
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

    it('should set HttpOnly SameSite=Lax session cookies in development', async () => {
        let cookies;
        try {
            cookies = await getUserSessionCookie(baseURL, authPath, 'abc123', true);
        } catch (error) {
            throw error;
        }

        const sessionCookie = cookies.find(cookie => cookie.startsWith('session='));
        we.expect(sessionCookie)
            .to.include('HttpOnly');
        we.expect(sessionCookie)
            .to.include('SameSite=Lax');
    });

    it('should not create a session for an invalid user', async () => {
        try {
            const p = await getUserSessionCookie(baseURL, authPath, 'invalid23', false);
            we.expect(p)
                .to.equal(null);
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
            .to.be.a('string')
            .and.not.match(/[\r\n]/);
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
        we.expect(response.body)
            .to.not.have.property('jwt');
    });

    it('should return user-scoped OpenAPI JSON from /auth/api.json', async () => {
        let cookie;
        let response;
        try {
            cookie = await getUserSessionCookie(baseURL, authPath, 'abc123', true);
            response = await request(baseURL)
                .get(apiJSONPath)
                .set('Cookie', [cookie])
                .accept('application/json')
                .expect(200);
        } catch (error) {
            throw error;
        }

        we.expect(response.body)
            .to.satisfy((body) => Boolean(body.swagger || body.openapi));
        we.expect(response.body)
            .to.include({
                basePath: '/rest/',
            });
        we.expect(response.body.securityDefinitions.jwt)
            .to.include({
                name: 'Authorization',
                type: 'apiKey',
                in: 'header',
            });
        we.expect(response.body.security[0])
            .to.have.property('jwt');
        we.expect(response.body.responses.UnauthorizedError)
            .to.include({
                description: 'JWT authorization is missing, invalid, or insufficient',
            });
    });

    it('should sign JWTs with constrained identity and validity claims', async () => {
        let jwt;
        try {
            jwt = await getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
        } catch (error) {
            throw error;
        }

        const payload = decodeJWTPayload(jwt);
        we.expect(payload)
            .to.include({
                iss: 'yelukerest',
                aud: 'yelukerest-postgrest',
                sub: 'user:1',
                user_id: 1,
                role: 'student',
            });
        const now = Math.floor(Date.now() / 1000);
        we.expect(payload.iat)
            .to.be.at.most(now + 2);
        we.expect(payload.nbf)
            .to.be.at.most(now + 2);
        we.expect(payload.exp)
            .to.be.above(now);
        we.expect(payload.jti)
            .to.be.a('string')
            .and.match(/^[0-9a-f-]{36}$/);
    });

    it('should not mint JWTs for observer users', async () => {
        let jwt;
        try {
            jwt = await getJWTForNetid(baseURL, authPath, jwtPath, 'crt43');
        } catch (error) {
            throw error;
        }

        we.expect(jwt)
            .to.equal(undefined);
    });

    it('should not let invalid users get a JWT', async () => {
        let jwt;
        try {
            jwt = await getJWTForNetid(baseURL, authPath, jwtPath, 'invalid234');
        } catch (error) {
            throw error;
        }
        we.expect(jwt)
            .to.equal(undefined);
    });
});
