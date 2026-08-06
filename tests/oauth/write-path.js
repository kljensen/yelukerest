/* global describe it before after */

// Group 5: the write path, end to end, driven by an OAuth client that holds
// the write scope.
//
// The posture this file asserts is deliberately unremarkable: a write needs
// the write scope, and then it happens. That scope is granted by the student
// on the consent screen, and row-level security applies underneath it, so an
// MCP write does exactly what the same student could do through the course
// website or by calling the API with their own token -- no more, and no less.
//
// An earlier design put a server-side confirmation in front of every write and
// refused clients that could not display one. It was removed (see
// docs/mcp-writes.md): it granted less than the API it fronts, it depended on a
// protocol mechanism that has since been withdrawn, and the human it was
// protecting is better served by the host's own tool-approval prompt.
//
// What is still worth asserting: the scope really is enforced, reads cannot
// write, the two-step preview is honest about what would happen, optimistic
// concurrency catches a value that moved under us, and every "nothing was
// written" claim is checked against the database rather than against the
// tool's own answer.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS,
    WRITE_SCOPES,
    READ_SCOPES,
    sharedClient,
    fullFlow,
    McpClient,
    sql,
} = require('./helpers.js');

// bun resets the default per-test timeout for each file; these tests drive a
// real Docker stack (and back off when a rate limiter pushes back), so give
// them room.
bunTest.setDefaultTimeout(240_000);

const { resetdb } = require('../rest/common.js');

const ASSIGNMENT = 'exam-1';
const FIELD = 'profound';

function storedBodies() {
    // The statement is handed to psql through an environment variable, so no
    // shell escaping is involved.
    const rows = sql(
        'select afs.body from data.assignment_field_submission afs '
        + 'join data."user" u on u.id = afs.submitter_user_id '
        + `where afs.assignment_slug = '${ASSIGNMENT}' `
        + `and afs.assignment_field_slug = '${FIELD}' `
        + `and u.netid = '${NETIDS.student}' order by afs.body`,
    );
    return rows === '' ? [] : rows.split('\n');
}

async function tokenFor(netid, scope) {
    const client = await sharedClient();
    const flow = await fullFlow({ clientId: client.client_id, netid, scope });
    return flow.tokens;
}

async function sessionFor(netid, scope) {
    const mcp = new McpClient((await tokenFor(netid, scope)).access_token);
    await mcp.initialize();
    return { mcp };
}

describe('oauth write path', () => {
    let writer;
    let reader;

    before(async () => {
        resetdb();
        writer = await sessionFor(NETIDS.student, WRITE_SCOPES);
        reader = await sessionFor(NETIDS.student, READ_SCOPES);
    });

    after(async () => {
        await writer.mcp.close();
        await reader.mcp.close();
        // Leave the database exactly as the suite found it.
        resetdb();
    });

    describe('preview', () => {
        it('should describe the change without writing anything', async () => {
            const before_ = storedBodies();
            const summary = await writer.mcp.callOk('preview_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body: 'A previewed but unwritten answer.',
            });
            expect(summary.action)
                .to.equal(before_.length === 0 ? 'create' : 'overwrite');
            expect(summary.assignment_slug)
                .to.equal(ASSIGNMENT);
            expect(summary.field_slug)
                .to.equal(FIELD);
            expect(summary.changed)
                .to.equal(true);
            expect(summary.proposed_body)
                .to.equal('A previewed but unwritten answer.');
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should be available to a read-only token', async () => {
            // A preview reads and nothing more, so requiring the write scope
            // for it would be theatre.
            const summary = await reader.mcp.callOk('preview_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body: 'Previewed by a reader.',
            });
            expect(summary.assignment_slug)
                .to.equal(ASSIGNMENT);
        });

        it('should refuse an unknown field', async () => {
            const message = await writer.mcp.callExpectError('preview_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: 'no-such-field',
                body: 'x',
            });
            expect(message)
                .to.contain('no field');
        });

        it('should refuse an unknown assignment', async () => {
            const message = await writer.mcp.callExpectError('preview_submission_change', {
                assignment_slug: 'no-such-assignment',
                field_slug: FIELD,
                body: 'x',
            });
            expect(message)
                .to.contain('not found');
        });
    });

    describe('submit', () => {
        it('should write when the token carries the write scope', async () => {
            const body = `Written with the write scope ${Date.now()}.`;
            const result = await writer.mcp.callOk('submit_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body,
            });
            expect(result.assignment_slug)
                .to.equal(ASSIGNMENT);
            expect(result.field_slug)
                .to.equal(FIELD);
            expect(result.body)
                .to.equal(body);
            expect(storedBodies())
                .to.deep.equal([body]);
        });

        it('should refuse a token without the write scope, and write nothing', async () => {
            // This is the boundary. It is the same boundary the student
            // crossed when they granted the scope on the consent screen.
            const before_ = storedBodies();
            const message = await reader.mcp.callExpectError('submit_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body: 'Written without the write scope.',
            });
            expect(message.toLowerCase())
                .to.contain('scope');
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should show the written value back through the read tools', async () => {
            // Guard against a vacuous pass: with nothing in the database this
            // comparison would hold trivially.
            const stored = storedBodies();
            expect(stored.length, 'a write must have happened before this readback')
                .to.be.greaterThan(0);

            const mine = await writer.mcp.callOk('get_my_submissions');
            const values = (mine.submissions || [])
                .flatMap(submission => submission.fields || [])
                .filter(field => field.assignment_field_slug === FIELD)
                .map(field => field.body);
            expect(values)
                .to.deep.equal(stored);
        });

        it('should reject a write based on a value that has since changed', async () => {
            // Optimistic concurrency survives the simplification: it is not a
            // security control, it is how two writers avoid silently clobbering
            // each other.
            const summary = await writer.mcp.callOk('preview_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body: 'Based on the value we just read.',
            });
            expect(summary.current_updated_at)
                .to.be.a('string')
                .with.length.greaterThan(0);

            // Someone else writes in between.
            await writer.mcp.callOk('submit_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body: `A concurrent write ${Date.now()}.`,
            });

            const message = await writer.mcp.callExpectError('submit_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body: 'Based on a value that moved.',
                expected_updated_at: summary.current_updated_at,
            });
            expect(message)
                .to.contain('changed since you read it');
        });

        it('should refuse a body that exceeds the size limit', async () => {
            const before_ = storedBodies();
            const message = await writer.mcp.callExpectError('submit_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: FIELD,
                body: 'x'.repeat(70_000),
            });
            expect(message)
                .to.contain('maximum');
            expect(storedBodies())
                .to.deep.equal(before_);
        });
    });

    describe('the escape hatch', () => {
        it('should allow a GET with the read scope', async () => {
            const response = await reader.mcp.callOk('postgrest_request', {
                method: 'GET',
                path: '/assignments',
                query: { select: 'slug' },
            });
            expect(response.status)
                .to.equal(200);
            expect(JSON.parse(response.body))
                .to.be.an('array');
        });

        it('should allow a non-GET with the write scope', async () => {
            // No token ceremony: the write scope is the whole gate, exactly as
            // it would be against PostgREST directly.
            const body = `Written through the escape hatch ${Date.now()}.`;
            const response = await writer.mcp.callOk('postgrest_request', {
                method: 'PATCH',
                path: '/assignment_field_submissions',
                query: {
                    assignment_slug: `eq.${ASSIGNMENT}`,
                    assignment_field_slug: `eq.${FIELD}`,
                },
                body: JSON.stringify({ body }),
            });
            expect(response.status)
                .to.be.within(200, 299);
            expect(storedBodies())
                .to.deep.equal([body]);
        });

        it('should refuse a non-GET for a read-only token, and write nothing', async () => {
            const before_ = storedBodies();
            const message = await reader.mcp.callExpectError('postgrest_request', {
                method: 'DELETE',
                path: '/assignment_field_submissions',
                query: { assignment_slug: `eq.${ASSIGNMENT}` },
            });
            expect(message.toLowerCase())
                .to.contain('scope');
            expect(storedBodies())
                .to.deep.equal(before_);
        });
    });
});
