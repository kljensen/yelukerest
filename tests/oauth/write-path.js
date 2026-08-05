/* global describe it before after beforeEach */

// Group 5: the curated write path (prepare_submission_change ->
// commit_submission_change) driven end to end by an OAuth client that holds
// the write scope.
//
// The interesting property here is that the intent token is NOT the whole
// defence. A commit also requires a confirmation the user actually sees, and
// a client that cannot show one is refused: reads stay available, writes do
// not. Both halves are asserted, and every "nothing was written" claim is
// checked against the database rather than against the tool's own answer.

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

/** Elicitation-capable client: this is what a real MCP host advertises. */
const ELICITING = { capabilities: { elicitation: { form: {} } } };

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

/** Opens an MCP session on an existing access token. */
async function sessionOn(tokens, options = {}) {
    const mcp = new McpClient(tokens.access_token, options);
    await mcp.initialize();
    return { mcp, tokens };
}

async function sessionFor(netid, scope, options = {}) {
    return sessionOn(await tokenFor(netid, scope), options);
}

async function prepare(mcp, body) {
    return mcp.callOk('prepare_submission_change', {
        assignment_slug: ASSIGNMENT,
        field_slug: FIELD,
        body,
    });
}

describe('oauth write path', () => {
    let writer;
    let eliciting;

    before(async () => {
        resetdb();
        // Both sessions ride the same access token: what differs is the MCP
        // session's advertised capabilities, which is the whole point.
        const writeTokens = await tokenFor(NETIDS.student, WRITE_SCOPES);
        writer = await sessionOn(writeTokens);
        eliciting = await sessionOn(writeTokens, ELICITING);
    });

    after(async () => {
        await writer.mcp.close();
        await eliciting.mcp.close();
        // Leave the database exactly as the suite found it.
        resetdb();
    });

    describe('prepare', () => {
        it('should describe the change without writing anything', async () => {
            const before_ = storedBodies();
            const summary = await prepare(writer.mcp, 'A prepared but uncommitted answer.');
            expect(summary.action)
                .to.equal(before_.length === 0 ? 'create' : 'overwrite');
            expect(summary.assignment_slug)
                .to.equal(ASSIGNMENT);
            expect(summary.field_slug)
                .to.equal(FIELD);
            expect(summary.changed)
                .to.equal(true);
            expect(summary.proposed_body)
                .to.equal('A prepared but uncommitted answer.');
            expect(summary.intent_token)
                .to.be.a('string')
                .with.length.greaterThan(20);
            expect(summary.intent_expires_at)
                .to.be.a('string');
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should refuse an unknown field', async () => {
            const message = await writer.mcp.callExpectError('prepare_submission_change', {
                assignment_slug: ASSIGNMENT,
                field_slug: 'no-such-field',
                body: 'x',
            });
            expect(message)
                .to.contain('no field');
        });

        it('should refuse an unknown assignment', async () => {
            const message = await writer.mcp.callExpectError('prepare_submission_change', {
                assignment_slug: 'no-such-assignment',
                field_slug: FIELD,
                body: 'x',
            });
            expect(message)
                .to.contain('not found');
        });
    });

    describe('commit without a confirmation channel', () => {
        it('should fail closed for a client that cannot elicit, and write nothing', async () => {
            // The default MCP client advertises no elicitation capability,
            // which is exactly the shape of a scripted/headless agent. The
            // intent token alone must NOT be enough: an injected instruction
            // can call prepare and commit back to back without the human ever
            // seeing anything.
            const before_ = storedBodies();
            const body = 'Written by a client that cannot confirm.';
            const summary = await prepare(writer.mcp, body);
            const message = await writer.mcp.callExpectError('commit_submission_change', {
                intent_token: summary.intent_token,
                body,
            });
            expect(message)
                .to.contain('cannot show you a write confirmation');
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should reject a fabricated intent token', async () => {
            // The prompt-injection case: an agent that invents the token it
            // was told to pass gets nowhere, and no PostgREST request is made.
            const before_ = storedBodies();
            const message = await eliciting.mcp.callExpectError('commit_submission_change', {
                intent_token: 'yelukerest-intent.made.up',
                body: 'injected content',
            });
            expect(message.length)
                .to.be.greaterThan(0);
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should reject a commit whose body differs from the prepared one', async () => {
            const before_ = storedBodies();
            const summary = await prepare(eliciting.mcp, 'The body the user reviewed.');
            const message = await eliciting.mcp.callExpectError('commit_submission_change', {
                intent_token: summary.intent_token,
                body: 'A different body slipped in afterwards.',
            });
            expect(message)
                .to.contain('does not match the prepared change');
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should reject an intent token minted for a different credential', async () => {
            const before_ = storedBodies();
            const other = await sessionFor(NETIDS.student, WRITE_SCOPES, ELICITING);
            const body = 'Prepared under one token, committed under another.';
            const summary = await prepare(other.mcp, body);
            const message = await eliciting.mcp.callExpectError('commit_submission_change', {
                intent_token: summary.intent_token,
                body,
            });
            expect(message.length)
                .to.be.greaterThan(0);
            expect(storedBodies())
                .to.deep.equal(before_);
            await other.mcp.close();
        });
    });

    describe('commit with a confirmation the user sees', () => {
        it('should ask the client to confirm, then perform the write', async () => {
            const body = `Confirmed answer ${Date.now()}.`;
            const summary = await prepare(eliciting.mcp, body);
            const outcome = await eliciting.mcp.callAnsweringElicitation(
                'commit_submission_change',
                { intent_token: summary.intent_token, body },
                { action: 'accept', content: { confirm: true } },
            );

            // The server really did ask, and asked about this exact change.
            expect(outcome.elicitations)
                .to.have.lengthOf(1);
            expect(outcome.elicitations[0].method)
                .to.equal('elicitation/create');
            expect(outcome.elicitations[0].params.message)
                .to.contain(FIELD);
            expect(outcome.elicitations[0].params.message)
                .to.contain(ASSIGNMENT);
            expect(outcome.elicitations[0].params.requestedSchema.required)
                .to.deep.equal(['confirm']);

            expect(outcome.result.isError)
                .to.not.equal(true);
            expect(outcome.result.structuredContent.assignment_slug)
                .to.equal(ASSIGNMENT);
            expect(outcome.result.structuredContent.field_slug)
                .to.equal(FIELD);
            expect(outcome.result.structuredContent.body)
                .to.equal(body);

            // ...and the value is actually in the database.
            expect(storedBodies())
                .to.deep.equal([body]);
        });

        it('should show the written value back through the read tools', async () => {
            // Guard against a vacuous pass: with nothing in the database
            // this comparison would hold trivially, so require that a value
            // was actually committed before comparing the two views of it.
            const stored = storedBodies();
            expect(stored.length, 'a commit must have happened before this readback')
                .to.be.greaterThan(0);

            const mine = await eliciting.mcp.callOk('get_my_submissions');
            const values = (mine.submissions || [])
                .flatMap(submission => submission.fields || [])
                .filter(field => field.assignment_field_slug === FIELD)
                .map(field => field.body);
            expect(values)
                .to.deep.equal(stored);
        });

        it('should burn the intent token after a successful commit', async () => {
            const before_ = storedBodies();
            const body = `Replay attempt ${Date.now()}.`;
            const summary = await prepare(eliciting.mcp, body);
            const first = await eliciting.mcp.callAnsweringElicitation(
                'commit_submission_change',
                { intent_token: summary.intent_token, body },
            );
            expect(first.result.isError)
                .to.not.equal(true);
            const written = storedBodies();
            expect(written)
                .to.deep.equal([body]);
            expect(written)
                .to.not.deep.equal(before_);

            const replay = await eliciting.mcp.callAnsweringElicitation(
                'commit_submission_change',
                { intent_token: summary.intent_token, body },
            );
            expect(replay.result.isError)
                .to.equal(true);
            // The replay changed nothing.
            expect(storedBodies())
                .to.deep.equal(written);
        });

        it('should write nothing when the user declines', async () => {
            const before_ = storedBodies();
            const body = `Declined answer ${Date.now()}.`;
            const summary = await prepare(eliciting.mcp, body);
            const outcome = await eliciting.mcp.callAnsweringElicitation(
                'commit_submission_change',
                { intent_token: summary.intent_token, body },
                { action: 'decline' },
            );
            expect(outcome.elicitations)
                .to.have.lengthOf(1);
            expect(outcome.result.isError)
                .to.equal(true);
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should write nothing when the user answers without confirming', async () => {
            const before_ = storedBodies();
            const body = `Unconfirmed answer ${Date.now()}.`;
            const summary = await prepare(eliciting.mcp, body);
            const outcome = await eliciting.mcp.callAnsweringElicitation(
                'commit_submission_change',
                { intent_token: summary.intent_token, body },
                { action: 'accept', content: { confirm: false } },
            );
            expect(outcome.result.isError)
                .to.equal(true);
            expect(storedBodies())
                .to.deep.equal(before_);
        });
    });

    describe('the escape hatch write gate', () => {
        it('should allow a GET through postgrest_request with no intent token', async () => {
            const response = await eliciting.mcp.callOk('postgrest_request', {
                method: 'GET',
                path: '/assignments',
                query: { select: 'slug' },
            });
            expect(response.status)
                .to.equal(200);
            expect(JSON.parse(response.body))
                .to.be.an('array');
        });

        it('should refuse a non-GET through postgrest_request with no intent token', async () => {
            const before_ = storedBodies();
            const message = await eliciting.mcp.callExpectError('postgrest_request', {
                method: 'DELETE',
                path: '/assignment_field_submissions',
                query: { assignment_slug: `eq.${ASSIGNMENT}` },
            });
            expect(message.toLowerCase())
                .to.contain('intent');
            expect(storedBodies())
                .to.deep.equal(before_);
        });

        it('should refuse a non-GET for a read-only token before anything else', async () => {
            const reader = await sessionFor(NETIDS.student, READ_SCOPES);
            const message = await reader.mcp.callExpectError('prepare_api_request', {
                method: 'DELETE',
                path: '/assignment_field_submissions',
                query: {},
            });
            expect(message.toLowerCase())
                .to.contain('scope');
            await reader.mcp.close();
        });
    });
});
