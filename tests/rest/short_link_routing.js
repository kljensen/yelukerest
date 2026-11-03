/* global describe it before after */

// Course short links through Caddy (issue #409): a missing single-segment
// GET or HEAD path is proxied to api.follow_short_link. Redirects are never
// followed (`.redirects(0)`), so no request leaves the stack; destinations
// are example.com URLs that are only compared, never fetched.
//
// The PostgREST-down case stops a container, so it lives in
// bin/test-rest-stack.sh rather than here.

const request = require('supertest');
const {
    resetdb,
    runSQL,
    baseURL,
    restService,
} = require('./common.js');

const BROWSER_ACCEPT = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
const DESTINATION = 'https://example.com/notebook?x=1';

// bin/test-rest-stack.sh writes an extensionless file of this name into the
// Elm client's build directory, so a same-named slug can be shown to lose to
// it. Run against any other stack, the test that needs it is skipped.
const STATIC_FILE = process.env.TEST_SHORT_LINK_STATIC_FILE;

const securityHeaders = {
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'strict-origin-when-cross-origin',
    'x-frame-options': 'DENY',
};

const expect = (condition, message) => {
    if (!condition) {
        throw new Error(message);
    }
};

const expectNoCORS = (response) => {
    const cors = Object.keys(response.headers).filter(name => name.startsWith('access-control-'));
    expect(cors.length === 0, `expected no CORS headers, got ${cors.join(', ')}`);
};

// A JWT for the faculty user signed with the course secret, already expired.
// PostgREST would answer it with 401, so a redirect proves Caddy dropped it.
const expiredFacultyToken = () => runSQL(`\\t on\n\\a\nSELECT pgjwt.sign(json_build_object(
        'role', 'faculty', 'user_id', 3,
        'iss', settings.get('jwt_issuer'), 'aud', settings.get('jwt_audience'),
        'exp', extract(epoch FROM now() - interval '1 hour')::int), settings.get('jwt_secret'));`)
    .trim().split('\n').pop();

const site = () => request(baseURL);

// The Caddyfile's own 404 (`respond "Not found" 404`) is plain text with that
// body; a resolver miss is PostgREST's empty response. Telling them apart
// is what shows a path was kept away from the resolver rather than looked up
// and missed. bin/test-rest-stack.sh checks the same paths again with
// PostgREST stopped, where a lookup would be a 502.
const expectCaddyNotFound = (response, path) => {
    expect(response.status === 404, `${path}: expected 404, got ${response.status}`);
    expect(!response.headers.location, `${path} must not redirect`);
    expect(response.text === 'Not found', `${path}: expected Caddy's own 404, got ${JSON.stringify(response.text)} (${response.headers['content-type']})`);
};

describe('short links through Caddy', () => {
    before(() => {
        resetdb();
        const rows = [
            `('rnn', '${DESTINATION}')`,
            "('rest-of-term', 'https://example.com/rest-of-term')",
        ];
        if (STATIC_FILE) {
            rows.push(`('${STATIC_FILE}', 'https://example.com/should-not-win')`);
        }
        runSQL(`INSERT INTO data.short_link (slug, url) VALUES ${rows.join(', ')};`);
    });

    after(() => {
        resetdb();
    });

    it('redirects a GET from a browser', async () => {
        const response = await site()
            .get('/rnn')
            .set('Accept', BROWSER_ACCEPT)
            .redirects(0)
            .expect(302);
        expect(response.headers.location === DESTINATION, `unexpected Location ${response.headers.location}`);
        expect(response.headers['cache-control'] === 'no-store', `unexpected Cache-Control ${response.headers['cache-control']}`);
    });

    it('redirects a HEAD', async () => {
        const response = await site()
            .head('/rnn')
            .set('Accept', BROWSER_ACCEPT)
            .redirects(0)
            .expect(302);
        expect(response.headers.location === DESTINATION, `unexpected Location ${response.headers.location}`);
        expect(response.headers['cache-control'] === 'no-store', `unexpected Cache-Control ${response.headers['cache-control']}`);
    });

    // Why the Caddyfile sends a HEAD upstream as a GET: PostgREST answers HEAD
    // on this RPC with a bare 204 and drops response.status and
    // response.headers. If this starts failing, PostgREST has changed and
    // `method GET` in the Caddyfile may no longer be needed.
    it('pins PostgREST answering a direct HEAD on the resolver with a bare 204', async () => {
        const response = await restService()
            .head('/rpc/follow_short_link?slug=rnn')
            .set('Accept', 'application/json')
            .redirects(0);
        expect(response.status === 204, `expected PostgREST's bare 204 for HEAD, got ${response.status}`);
        expect(!response.headers.location, 'PostgREST now sends Location on HEAD; revisit `method GET` in the Caddyfile');
    });

    it('redirects a slug that starts with a reserved name', async () => {
        const response = await site()
            .get('/rest-of-term')
            .redirects(0)
            .expect(302);
        expect(response.headers.location === 'https://example.com/rest-of-term', `unexpected Location ${response.headers.location}`);
    });

    it('still redirects when the browser sends an expired bearer token and cookies', async () => {
        const response = await site()
            .get('/rnn')
            .set('Accept', BROWSER_ACCEPT)
            .set('Authorization', `Bearer ${expiredFacultyToken()}`)
            .set('Cookie', 'yeluke.sid=not-a-session')
            .set('Prefer', 'return=minimal')
            .set('Accept-Profile', 'data')
            .set('Range', '0-0')
            .redirects(0)
            .expect(302);
        expect(response.headers.location === DESTINATION, `unexpected Location ${response.headers.location}`);
    });

    it('ignores the query string', async () => {
        const response = await site()
            .get('/rnn?slug=other&select=url&url=eq.x')
            .redirects(0)
            .expect(302);
        expect(response.headers.location === DESTINATION, `unexpected Location ${response.headers.location}`);
    });

    it('sends the security headers and no CORS headers', async () => {
        const response = await site()
            .get('/rnn')
            .set('Origin', 'https://attacker.example')
            .redirects(0)
            .expect(302);
        Object.entries(securityHeaders).forEach(([name, value]) => {
            expect(response.headers[name] === value, `expected ${name}=${value}, got ${response.headers[name]}`);
        });
        expect(Boolean(response.headers['content-security-policy']), 'expected a Content-Security-Policy');
        expectNoCORS(response);
    });

    it('answers an unknown slug with 404', async () => {
        const response = await site()
            .get('/no-such-link')
            .set('Accept', BROWSER_ACCEPT)
            .redirects(0)
            .expect(404);
        expect(!response.headers.location, 'a miss must not redirect');
        // PostgREST's answer for the void resolver: no body at all.
        expect(response.text === '', `an unknown slug should be PostgREST's empty 404, got ${JSON.stringify(response.text)}`);
        expect(response.headers['cache-control'] === 'no-store', `unexpected Cache-Control ${response.headers['cache-control']}`);
        Object.entries(securityHeaders).forEach(([name, value]) => {
            expect(response.headers[name] === value, `expected ${name}=${value}, got ${response.headers[name]}`);
        });
    });

    it('does not send other methods or other path shapes to the resolver', async () => {
        expectCaddyNotFound(await site().post('/rnn').redirects(0), 'POST /rnn');
        expectCaddyNotFound(await site().delete('/rnn').redirects(0), 'DELETE /rnn');
        for (const path of ['/rnn/', '/RNN', '/a/rnn', '/-rnn', '/rnn.html', `/a${'b'.repeat(40)}`]) {
            expectCaddyNotFound(await site().get(path).redirects(0), path);
        }
    });

    (STATIC_FILE ? it : it.skip)('serves a real static file over a same-named slug', async () => {
        const response = await site()
            .get(`/${STATIC_FILE}`)
            .redirects(0)
            .expect(200);
        expect(!response.headers.location, 'a static file must not redirect');
    });

    it('still serves the Elm client and its assets', async () => {
        await site().get('/').redirects(0).expect(200);
        const favicon = await site().get('/favicon.ico').redirects(0).expect(200);
        expect(favicon.headers['cache-control'] === 'no-cache', `unexpected Cache-Control ${favicon.headers['cache-control']}`);
    });

    it('leaves the reserved routes alone', async () => {
        // The bare prefixes are excluded from the matcher and stay 404s.
        for (const path of ['/rest', '/auth', '/cas', '/openapi', '/oauth2']) {
            expectCaddyNotFound(await site().get(path).redirects(0), path);
        }
        // Routed paths still reach their own upstreams.
        await restService().get('/platform_version').expect(200);
        await site().get('/auth/me').redirects(0).expect(401);
        await site().get('/openapi/').redirects(0).expect(200);
        const mcp = await site().get('/mcp').redirects(0);
        expect(mcp.status !== 302 && mcp.status !== 404, `/mcp went to the resolver: ${mcp.status}`);
        // Hydra is not started by bin/test-rest-stack.sh, so its routes answer
        // 502 there and 401 on a full stack; either way not the resolver.
        for (const path of ['/userinfo', '/oauth2/token']) {
            const response = await site().get(path).redirects(0);
            expect(response.status !== 302 && response.status !== 404, `${path} went to the resolver: ${response.status}`);
        }
    });

    it('passes an upstream 404 through unchanged', async () => {
        const response = await restService()
            .get('/nonexistent')
            .redirects(0)
            .expect(404);
        expect((response.headers['content-type'] || '').includes('json'), `expected PostgREST's JSON 404, got ${response.headers['content-type']}`);
        expect(!response.headers.location, 'an upstream 404 must not redirect');
    });
});
