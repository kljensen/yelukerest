/* global describe it before */

// Group 6 (runs last, hence the name): the log scan.
//
// The suite has just pushed dozens of access tokens, refresh tokens,
// authorization codes, client secrets and pieces of student coursework through
// every service in the stack. helpers.js records each of those values as it
// goes; this file greps the container logs for them.
//
// The application services are held to "nothing, ever". Caddy is scanned
// separately because it currently logs more than it should -- see the comments
// on those tests.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    WRITE_SCOPES,
    sharedClient,
    fullFlow,
    McpClient,
    serviceLogs,
    observedSecrets,
    recordSecret,
} = require('./helpers.js');

bunTest.setDefaultTimeout(120_000);

// Services that implement the deployment's own logic. Nothing sensitive may
// appear in any of them.
const APP_SERVICES = ['authapp', 'mcpapp', 'hydra', 'postgrest'];

function leaksIn(logs, secrets) {
    return secrets.filter(secret => logs.includes(secret))
        .map(secret => `${secret.slice(0, 32)}...`);
}

describe('service logs', () => {
    let appLogs;
    let proxyLogs;
    let secrets;
    // Grade and submission text observed coming back from the tools during
    // the scan window; see the before hook.
    let toolResultCanaries = [];

    before(async () => {
        // One more round trip, so this file still means something when it is
        // run on its own: a token, a code, an intent token and a piece of
        // student coursework pushed through the whole stack.
        const clientId = (await sharedClient()).client_id;
        const flow = await fullFlow({
            clientId, netid: NETIDS.student, scope: WRITE_SCOPES,
        });
        const body = `Log scan canary ${Date.now()} zzq.`;
        recordSecret(body);
        const mcp = new McpClient(flow.tokens.access_token, {
            capabilities: { elicitation: { form: {} } },
        });
        await mcp.initialize();
        const summary = await mcp.callOk('prepare_submission_change', {
            assignment_slug: 'exam-1', field_slug: 'profound', body,
        });
        recordSecret(summary.intent_token);

        // Pull real grade and submission content through the tools during
        // the scan window, and take the canaries from what came back. Fixed
        // fixture strings would pass vacuously whenever the tools were never
        // called, and would rot silently if the sample data were renamed.
        const grades = await mcp.callOk('get_my_grades');
        const submissions = await mcp.callOk('get_my_submissions');
        toolResultCanaries = [
            ...(grades.grades || [])
                .map(grade => grade.description)
                .filter(text => typeof text === 'string' && text.length > 6),
            ...(submissions.submissions || [])
                .flatMap(submission => submission.fields || [])
                .map(field => field.body)
                .filter(text => typeof text === 'string' && text.length > 6),
        ];
        await mcp.close();

        appLogs = serviceLogs(APP_SERVICES);
        proxyLogs = serviceLogs(['caddy']);
        secrets = [...observedSecrets];
    });

    it('should have produced logs and secrets to scan (guard against a silent pass)', () => {
        expect(appLogs.length)
            .to.be.greaterThan(1000);
        expect(proxyLogs.length)
            .to.be.greaterThan(1000);
        expect(secrets.length)
            .to.be.greaterThan(5);
    });

    describe('application services', () => {
        it('should not log any access, refresh, or ID token', () => {
            const jwts = secrets.filter(secret => secret.split('.').length === 3);
            expect(jwts.length)
                .to.be.greaterThan(0);
            expect(leaksIn(appLogs, jwts))
                .to.deep.equal([]);
        });

        it('should not log any authorization code or refresh token', () => {
            expect(/ory_ac_[A-Za-z0-9._-]{10,}/.test(appLogs))
                .to.equal(false);
            expect(/ory_rt_[A-Za-z0-9._-]{10,}/.test(appLogs))
                .to.equal(false);
        });

        it('should not log any credential or student content the run handled', () => {
            expect(leaksIn(appLogs, secrets))
                .to.deep.equal([]);
        });

        it('should not log an Authorization header value', () => {
            expect(/[Aa]uthorization["' :=]+Bearer [A-Za-z0-9._-]{20,}/.test(appLogs))
                .to.equal(false);
        });

        it('should not log grades or submission bodies from tool results', () => {
            // Values taken from what the grade and submission tools actually
            // returned during the scan window — so this cannot pass because
            // the content never travelled.
            expect(toolResultCanaries.length, 'the tools must have returned content to scan for')
                .to.be.greaterThan(0);
            expect(leaksIn(appLogs, toolResultCanaries))
                .to.deep.equal([]);
        });
    });

    describe('the reverse proxy', () => {
        it('should redact Authorization headers', () => {
            expect(proxyLogs)
                .to.contain('"Authorization":["REDACTED"]');
            expect(/"Authorization":\["Bearer /.test(proxyLogs))
                .to.equal(false);
        });

        it('should not log access, refresh, or ID tokens', () => {
            const jwts = secrets.filter(secret => secret.split('.').length === 3);
            expect(leaksIn(proxyLogs, jwts))
                .to.deep.equal([]);
            expect(/ory_rt_[A-Za-z0-9._-]{10,}/.test(proxyLogs))
                .to.equal(false);
        });

        it('DOES log OAuth authorization codes (known issue, pinned here)', () => {
            // FINDING, reported not fixed: caddy/Caddyfile enables the global
            // `debug` option, and it is mounted from docker-compose.base.yaml,
            // so this applies in production as well as development. Caddy's
            // debug-level "upstream roundtrip" entries include the upstream
            // response headers verbatim, and the authorization endpoint's
            // response is a redirect whose Location carries
            // `?code=ory_ac_...`. Anyone who can read the proxy's logs can
            // read every authorization code the deployment issues.
            //
            // The blast radius is bounded -- codes are single use, short
            // lived, and PKCE-bound, so a log reader without the verifier
            // cannot redeem one -- but they should not be there.
            //
            // This test asserts the CURRENT behaviour so the suite is honest
            // about it. When `debug` is dropped (or the Location header is
            // redacted), this test fails and should be inverted to
            // expect(false).
            expect(/ory_ac_[A-Za-z0-9._-]{10,}/.test(proxyLogs))
                .to.equal(true);
        });
    });
});
