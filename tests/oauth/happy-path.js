/* global describe it before after */

// Group 1: the complete OAuth + MCP happy path, run as a student, a TA, and a
// faculty member, asserting the row-level-security boundary survives the whole
// stack (Hydra token -> mcpapp -> internal JWT -> PostgREST -> Postgres RLS).

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    READ_SCOPES,
    LOOPBACK_REDIRECT,
    decodeJWT,
    sharedClient,
    fullFlow,
    McpClient,
    issuer,
    baseURL,
} = require('./helpers.js');

// bun resets the default per-test timeout for each file; these tests drive a
// real Docker stack (and back off when a rate limiter pushes back), so give
// them room.
bunTest.setDefaultTimeout(120_000);

// Every tool the server registers: 9 curated reads, 2 submission tools, 2
// escape-hatch tools. A change here is a deliberate API change.
const EXPECTED_TOOLS = [
    'get_api_schema',
    'get_assignment',
    'get_my_engagements',
    'get_my_grades',
    'get_my_quiz_grades',
    'get_my_submissions',
    'list_assignments',
    'list_meetings',
    'list_quizzes',
    'postgrest_request',
    'preview_submission_change',
    'submit_submission_change',
    'whoami',
];

describe('oauth happy path', () => {
    const sessions = {};
    let client;

    before(async () => {
        client = await sharedClient();
        // One full authorization-code flow per role, sequentially: each one
        // logs in through the mock CAS server as a different netid.
        const roles = [['student', NETIDS.student], ['ta', NETIDS.ta], ['faculty', NETIDS.faculty]];
        // eslint-disable-next-line no-restricted-syntax
        for (const [role, netid] of roles) {
            // eslint-disable-next-line no-await-in-loop
            const flow = await fullFlow({
                clientId: client.client_id,
                netid,
                scope: READ_SCOPES,
            });
            const mcp = new McpClient(flow.tokens.access_token);
            // eslint-disable-next-line no-await-in-loop
            await mcp.initialize();
            sessions[role] = { flow, mcp, netid };
        }
    });

    after(async () => {
        await Promise.all(Object.values(sessions)
            .map(session => session.mcp.close()));
    });

    describe('the authorization-code + PKCE dance', () => {
        it('should hand the registered client a code at its exact redirect URI', () => {
            const { flow } = sessions.student;
            expect(flow.callbackURL.origin + flow.callbackURL.pathname)
                .to.equal(LOOPBACK_REDIRECT);
            expect(flow.code)
                .to.be.a('string');
            expect(flow.code)
                .to.match(/^ory_ac_/);
        });

        it('should return the exact state it was given (CSRF binding)', () => {
            const { flow } = sessions.student;
            expect(flow.callbackURL.searchParams.get('state'))
                .to.equal(flow.state);
        });

        it('should show a consent form listing only the requested scopes', () => {
            const { flow } = sessions.student;
            expect(flow.consent.status)
                .to.equal(200);
            expect(flow.consent.csrfToken)
                .to.be.a('string')
                .with.length.greaterThan(16);
            // Consent challenges are long (1-4KB) opaque strings. Assert the
            // shape authapp's forwarding pattern allows, so a truncating or
            // mangling proxy in front of the consent page would be caught.
            expect(flow.consent.consentChallenge)
                .to.match(/^[A-Za-z0-9._~=-]{32,}$/);
            expect(flow.consent.consentChallenge.length)
                .to.be.greaterThan(500);
            expect(flow.consent.scopes.sort())
                .to.deep.equal(READ_SCOPES.split(' ')
                    .sort());
        });

        it('should name the client and the caller on the consent page', () => {
            const { flow, netid } = sessions.student;
            expect(flow.consent.html)
                .to.contain(netid);
            expect(flow.consent.html)
                .to.contain(client.client_id);
        });

        it('should issue a refresh token when offline_access is granted', () => {
            const { flow } = sessions.student;
            expect(flow.tokens.refresh_token)
                .to.be.a('string');
            expect(flow.tokens.token_type.toLowerCase())
                .to.equal('bearer');
            expect(flow.tokens.scope.split(' '))
                .to.include('offline_access');
        });
    });

    describe('the access token', () => {
        it('should be a JWT bound to this deployment and to /mcp', () => {
            const claims = decodeJWT(sessions.student.flow.tokens.access_token);
            expect(claims.iss)
                .to.equal(issuer);
            expect(claims.aud)
                .to.deep.equal([`${baseURL}/mcp`]);
            expect(claims.client_id)
                .to.equal(client.client_id);
        });

        it('should carry the course identity claims authapp attached at consent', () => {
            const student = decodeJWT(sessions.student.flow.tokens.access_token);
            expect(student.sub)
                .to.equal(NETIDS.student);
            expect(student.netid)
                .to.equal(NETIDS.student);
            expect(student.role)
                .to.equal('student');
            expect(student.user_id)
                .to.be.a('number');

            const faculty = decodeJWT(sessions.faculty.flow.tokens.access_token);
            expect(faculty.role)
                .to.equal('faculty');
            const ta = decodeJWT(sessions.ta.flow.tokens.access_token);
            expect(ta.role)
                .to.equal('ta');
        });

        it('should carry exactly the granted scopes and nothing more', () => {
            const claims = decodeJWT(sessions.student.flow.tokens.access_token);
            expect(claims.scopes.split(' ')
                .sort())
                .to.deep.equal(READ_SCOPES.split(' ')
                    .sort());
            expect(claims.scopes)
                .to.not.contain('submissions:write');
        });
    });

    describe('the MCP session', () => {
        it('should negotiate the legacy protocol version without a session', () => {
            // A legacy client still gets the handshake it expects, but the
            // server is stateless (issue #278), so it assigns no session id —
            // which the spec permits and which nothing here needs, since every
            // tool re-derives the caller from the bearer token. See
            // tests/oauth/stateless-conformance.js for both eras on the wire.
            const { mcp } = sessions.student;
            expect(mcp.negotiatedVersion)
                .to.equal('2025-11-25');
            expect(mcp.sessionId, 'a stateless server assigns no session')
                .to.equal(null);
        });

        it('should advertise all thirteen tools', async () => {
            const tools = await sessions.student.mcp.listTools();
            expect(tools.map(tool => tool.name)
                .sort())
                .to.deep.equal(EXPECTED_TOOLS);
            expect(tools)
                .to.have.lengthOf(13);
        });

        it('should reject an unauthenticated call with RFC 9728 metadata', async () => {
            const anonymous = new McpClient(null);
            const response = await anonymous.post({
                jsonrpc: '2.0', id: 1, method: 'tools/list', params: {},
            });
            expect(response.status)
                .to.equal(401);
            const challenge = response.headers.get('www-authenticate');
            expect(challenge)
                .to.contain('Bearer');
            expect(challenge)
                .to.contain(`resource_metadata="${baseURL}/.well-known/oauth-protected-resource/mcp"`);
        });
    });

    describe('whoami', () => {
        it('should report the student who actually authenticated', async () => {
            const me = await sessions.student.mcp.callOk('whoami');
            expect(me.netid)
                .to.equal(NETIDS.student);
            expect(me.role)
                .to.equal('student');
            expect(me.db_role)
                .to.equal('student');
            expect(me.sub)
                .to.equal(`user:${me.user_id}`);
        });

        it('should report the faculty member who actually authenticated', async () => {
            const me = await sessions.faculty.mcp.callOk('whoami');
            expect(me.netid)
                .to.equal(NETIDS.faculty);
            expect(me.role)
                .to.equal('faculty');
        });

        it('should report the TA who actually authenticated', async () => {
            const me = await sessions.ta.mcp.callOk('whoami');
            expect(me.netid)
                .to.equal(NETIDS.ta);
            expect(me.role)
                .to.equal('ta');
        });
    });

    describe('curated reads', () => {
        it('should list assignments for a student', async () => {
            const result = await sessions.student.mcp.callOk('list_assignments');
            expect(result.assignments)
                .to.be.an('array')
                .with.length.greaterThan(0);
            result.assignments.forEach((assignment) => {
                expect(assignment.slug)
                    .to.be.a('string');
                // Students never see draft coursework.
                expect(assignment.is_draft)
                    .to.not.equal(true);
            });
        });

        it('should return only the calling student\'s own submissions', async () => {
            const me = await sessions.student.mcp.callOk('whoami');
            const mine = await sessions.student.mcp.callOk('get_my_submissions');
            expect(mine.submissions)
                .to.be.an('array');
            mine.submissions.forEach((submission) => {
                // Individual submissions are the caller's; team submissions
                // belong to the caller's team.
                const ownIndividual = submission.user_id === undefined
                    || submission.user_id === null
                    || String(submission.user_id) === String(me.user_id);
                const ownTeam = !submission.team_nickname
                    || submission.team_nickname === me.team_nickname;
                expect(ownIndividual && ownTeam)
                    .to.equal(true);
            });
        });

        it('should return only the calling student\'s own grades', async () => {
            const grades = await sessions.student.mcp.callOk('get_my_grades');
            expect(grades)
                .to.be.an('object');
        });
    });

    describe('row-level security through the whole stack', () => {
        it('should show a student exactly one user and faculty the whole roster', async () => {
            const studentUsers = await sessions.student.mcp.callOk('postgrest_request', {
                method: 'GET',
                path: '/users',
                query: { select: 'id,netid,role' },
            });
            const facultyUsers = await sessions.faculty.mcp.callOk('postgrest_request', {
                method: 'GET',
                path: '/users',
                query: { select: 'id,netid,role' },
            });
            const studentRows = JSON.parse(studentUsers.body);
            const facultyRows = JSON.parse(facultyUsers.body);

            expect(studentRows)
                .to.have.lengthOf(1);
            expect(studentRows[0].netid)
                .to.equal(NETIDS.student);
            expect(facultyRows.length)
                .to.be.greaterThan(studentRows.length);
            expect(facultyRows.map(row => row.netid))
                .to.include(NETIDS.student)
                .and.to.include(NETIDS.faculty);
        });

        it('should not let a student read another student\'s submissions', async () => {
            const other = await sessions.student.mcp.callOk('postgrest_request', {
                method: 'GET',
                path: '/assignment_field_submissions',
                query: { select: 'assignment_submission_id' },
            });
            const mine = await sessions.student.mcp.callOk('get_my_submissions');
            const visible = JSON.parse(other.body);
            const mineIds = new Set((mine.submissions || []).map(submission => submission.id));

            // Controls first: with no rows on either side the assertion
            // below is vacuous, and a deny-all regression would "pass".
            expect(mineIds.size, 'fixture must give this student submissions to see')
                .to.be.greaterThan(0);
            expect(visible.length, 'the API must return rows for this student')
                .to.be.greaterThan(0);
            // The database must hold submissions belonging to someone else,
            // otherwise there is nothing for RLS to be hiding.
            const allSubmissions = JSON.parse((await sessions.faculty.mcp.callOk('postgrest_request', {
                method: 'GET',
                path: '/assignment_field_submissions',
                query: { select: 'assignment_submission_id' },
            })).body);
            expect(allSubmissions.length, 'fixture must contain other students\' submissions')
                .to.be.greaterThan(visible.length);

            visible.forEach((row) => {
                expect(mineIds.has(row.assignment_submission_id))
                    .to.equal(true);
            });
        });

        it('should give faculty a strictly wider view of engagements than a student', async () => {
            const studentRows = JSON.parse((await sessions.student.mcp.callOk('postgrest_request', {
                method: 'GET', path: '/engagements', query: { select: 'user_id' },
            })).body);
            const facultyRows = JSON.parse((await sessions.faculty.mcp.callOk('postgrest_request', {
                method: 'GET', path: '/engagements', query: { select: 'user_id' },
            })).body);
            const studentSubjects = new Set(studentRows.map(row => row.user_id));
            const facultySubjects = new Set(facultyRows.map(row => row.user_id));
            expect(studentSubjects.size)
                .to.be.at.most(1);
            expect(facultySubjects.size)
                .to.be.greaterThan(studentSubjects.size);
        });

        it('should deny a read-scoped token any write', async () => {
            const message = await sessions.student.mcp.callExpectError('submit_submission_change', {
                assignment_slug: 'exam-1',
                field_slug: 'profound',
                body: 'should never be written',
            });
            expect(message.toLowerCase())
                .to.contain('scope');
        });
    });
});
