const request = require('supertest');
const {
    baseURL,
    restService,
} = require('./common.js');

const commonHeaders = {
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'strict-origin-when-cross-origin',
    'permissions-policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), browsing-topics=()',
    'x-frame-options': 'DENY',
};

const expectHeaders = (response, expectedHeaders) => {
    Object.entries(expectedHeaders)
        .forEach(([name, value]) => {
            if (response.headers[name] !== value) {
                throw new Error(`Expected ${name}=${value}, got ${response.headers[name]}`);
            }
        });
};

const expectHeaderAbsent = (response, name) => {
    if (Object.prototype.hasOwnProperty.call(response.headers, name)) {
        throw new Error(`Expected ${name} to be absent, got ${response.headers[name]}`);
    }
};

describe('http security headers', () => {
    it('sets shared browser hardening headers on the frontend', async () => {
        const response = await request(baseURL)
            .get('/')
            .expect(200);

        expectHeaders(response, commonHeaders);
    });

    it('uses a strict CSP for the Elm frontend', async () => {
        const response = await request(baseURL)
            .get('/')
            .expect(200);

        expectHeaders(response, {
            'content-security-policy': "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; img-src 'self' data:; font-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'",
        });
    });

    it('uses a Swagger-compatible CSP for OpenAPI docs', async () => {
        const response = await request(baseURL)
            .get('/openapi/')
            .expect(200);

        expectHeaders(response, {
            ...commonHeaders,
            'content-security-policy': "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; img-src 'self' data:; font-src 'self' https://fonts.gstatic.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; script-src 'self' 'unsafe-inline'; connect-src 'self'",
        });
    });

    it('sets shared browser hardening headers on REST responses', async () => {
        const response = await restService()
            .get('/')
            .expect(200);

        expectHeaders(response, commonHeaders);
        expectHeaderAbsent(response, 'access-control-allow-origin');
    });

    it('sets shared browser hardening headers on authapp responses', async () => {
        const response = await request(baseURL)
            .get('/auth/me')
            .expect(401);

        expectHeaders(response, {
            ...commonHeaders,
            'cache-control': 'no-store',
            pragma: 'no-cache',
            expires: '0',
        });
        expectHeaderAbsent(response, 'access-control-allow-origin');
    });

    it('does not expose REST responses cross-origin by default', async () => {
        const response = await restService()
            .get('/users')
            .set('Origin', 'https://attacker.example')
            .expect(401);

        expectHeaderAbsent(response, 'access-control-allow-origin');
        expectHeaderAbsent(response, 'access-control-allow-credentials');
    });
});
