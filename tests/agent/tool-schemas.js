/* global describe it before after */

// Group 1: the parts of the agent story that need no model.
//
// Two things live here, and the second is the important one.
//
// The bridge checks assert that what we publish through tools/list is
// something an OpenAI-compatible host can actually consume. A tool whose
// schema drifts out of shape breaks real clients silently; it should break a
// test loudly.
//
// The elicitation checks drive BOTH write mechanisms -- the curated
// prepare/commit pair and the prepare_api_request + non-GET postgrest_request
// escape hatch -- through the same generic execution path the agent loop uses,
// under each of the three policies. This is what actually proves that path
// works on both mechanisms, and it deliberately does not involve a model: the
// injection scenario cannot prove it, because a model is free to attempt
// neither. Deterministic coverage of the mechanism, stochastic coverage of the
// behaviour.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS, WRITE_SCOPES, baseURL, sql,
} = require('../oauth/helpers.js');
const {
    assertLocalTarget,
    agentSession,
    bridgeTools,
    chatCompletion,
    resolveModel,
    providerConfigured,
    MISSING_KEY_MESSAGE,
} = require('./harness.js');
const { resetdb } = require('../rest/common.js');

bunTest.setDefaultTimeout(300_000);

const ASSIGNMENT = 'exam-1';
const FIELD = 'profound';

// OpenAI's function-name constraint. A tool name that violates it is rejected
// by the provider before any reasoning happens.
const NAME_PATTERN = /^[a-zA-Z0-9_-]{1,64}$/;

function storedBodies(field = FIELD) {
    const rows = sql(
        'select afs.body from data.assignment_field_submission afs '
        + 'join data."user" u on u.id = afs.submitter_user_id '
        + `where afs.assignment_slug = '${ASSIGNMENT}' `
        + `and afs.assignment_field_slug = '${field}' `
        + `and u.netid = '${NETIDS.student}' order by afs.body`,
    );
    return rows === '' ? [] : rows.split('\n');
}

describe('agent tool bridge', () => {
    let session;
    let tools;
    let mcpTools;

    before(async () => {
        assertLocalTarget(baseURL);
        resetdb();
        session = await agentSession(NETIDS.student, WRITE_SCOPES, { eliciting: true });
        mcpTools = await session.mcp.listTools();
        tools = bridgeTools(mcpTools);
    });

    after(async () => {
        if (session) {
            await session.mcp.close();
        }
        resetdb();
    });

    it('should publish tools that survive the bridge to an OpenAI tool list', () => {
        expect(tools.length, 'the server published no tools')
            .to.be.greaterThan(0);
        for (const tool of tools) {
            expect(tool.type)
                .to.equal('function');
            expect(tool.function.name, `tool name ${tool.function.name} is not a legal function name`)
                .to.match(NAME_PATTERN);
            expect(tool.function.description, `tool ${tool.function.name} has no description for the model to read`)
                .to.be.a('string')
                .with.length.greaterThan(0);
            expect(tool.function.parameters.type, `tool ${tool.function.name} has a non-object parameter schema`)
                .to.equal('object');
        }
    });

    it('should carry the server instructions a real client is handed', () => {
        // These are the system prompt the scenarios use. If they ever go
        // missing, every model-driven test silently loses its contract.
        expect(session.instructions)
            .to.be.a('string')
            .with.length.greaterThan(200);
        expect(session.instructions)
            .to.contain('untrusted');
    });

    describe('the generic elicitation path', () => {
        // Both write mechanisms reach the same requestWriteConfirmation, so
        // the agent loop answers elicitation for ANY tool rather than for one
        // known tool name. These tests are that promise, checked directly.

        // Each exchange gets its OWN session, which is a workaround for a real
        // bug rather than tidiness: after a few elicitation round-trips on one
        // session, the next one never delivers its result and the client waits
        // out its 90-second abort (issue #286 -- it makes the older
        // tests/oauth/write-path.js suite intermittently fail too, so it
        // predates this file). A fresh session helps but is not a cure: the
        // resource that runs out is cumulative in the mcpapp PROCESS, and a
        // restart is what actually clears it. When #286 is fixed these can
        // share `session` again, and the shared-session case earns its own
        // regression test at that point.
        const elicitingSession = () => agentSession(NETIDS.student, WRITE_SCOPES, { eliciting: true });

        it('should refuse a curated write when the client cannot confirm', async () => {
            const silent = await agentSession(NETIDS.student, WRITE_SCOPES, { eliciting: false });
            const before_ = storedBodies();
            const body = 'Written with no confirmation channel.';
            const summary = await silent.mcp.callOk('prepare_submission_change', {
                assignment_slug: ASSIGNMENT, field_slug: FIELD, body,
            });
            const outcome = await silent.mcp.callAnsweringElicitation(
                'commit_submission_change',
                { intent_token: summary.intent_token, body },
                { action: 'decline' },
            );
            expect(outcome.elicitations, 'a client that cannot elicit must not be asked')
                .to.have.lengthOf(0);
            expect(outcome.result.isError)
                .to.equal(true);
            expect(storedBodies())
                .to.deep.equal(before_);
            await silent.mcp.close();
        });

        it('should ask, and write, when the curated confirmation is accepted', async () => {
            const fresh = await elicitingSession();
            const body = `Accepted through the generic path ${Date.now()}.`;
            const summary = await fresh.mcp.callOk('prepare_submission_change', {
                assignment_slug: ASSIGNMENT, field_slug: FIELD, body,
            });
            const outcome = await fresh.mcp.callAnsweringElicitation(
                'commit_submission_change',
                { intent_token: summary.intent_token, body },
                { action: 'accept', content: { confirm: true } },
            );
            expect(outcome.elicitations)
                .to.have.lengthOf(1);
            expect(outcome.result.isError)
                .to.not.equal(true);
            expect(storedBodies())
                .to.contain(body);
            await fresh.mcp.close();
        });

        it('should ask, and write nothing, when the curated confirmation is declined', async () => {
            const fresh = await elicitingSession();
            const before_ = storedBodies();
            const body = `Declined through the generic path ${Date.now()}.`;
            const summary = await fresh.mcp.callOk('prepare_submission_change', {
                assignment_slug: ASSIGNMENT, field_slug: FIELD, body,
            });
            const outcome = await fresh.mcp.callAnsweringElicitation(
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
            await fresh.mcp.close();
        });

        it('should ask before a non-GET escape-hatch request, and honour a decline', async () => {
            // The second write mechanism. A loop that only answered
            // elicitation for commit_submission_change would hang here until
            // the client's abort timer, which is exactly the bug this covers.
            const fresh = await elicitingSession();
            const before_ = storedBodies('fooword');
            const payload = JSON.stringify({
                assignment_slug: ASSIGNMENT,
                assignment_field_slug: 'fooword',
                body: `Escape hatch decline ${Date.now()}.`,
            });
            const prepared = await fresh.mcp.callOk('prepare_api_request', {
                method: 'POST', path: '/assignment_field_submissions', body: payload,
            });
            const outcome = await fresh.mcp.callAnsweringElicitation(
                'postgrest_request',
                {
                    method: 'POST',
                    path: '/assignment_field_submissions',
                    body: payload,
                    intent_token: prepared.intent_token,
                },
                { action: 'decline' },
            );
            expect(outcome.elicitations, 'the escape hatch must ask before a non-GET request')
                .to.have.lengthOf(1);
            expect(outcome.elicitations[0].method)
                .to.equal('elicitation/create');
            expect(outcome.result.isError)
                .to.equal(true);
            expect(storedBodies('fooword'))
                .to.deep.equal(before_);
            await fresh.mcp.close();
        });

        it('should not ask before a GET through the escape hatch', async () => {
            const outcome = await session.mcp.callAnsweringElicitation(
                'postgrest_request',
                { method: 'GET', path: '/assignments', query: { select: 'slug' } },
                { action: 'decline' },
            );
            expect(outcome.elicitations, 'a read must not interrupt the user')
                .to.have.lengthOf(0);
            expect(outcome.result.isError)
                .to.not.equal(true);
        });
    });

    describe('provider acceptance', () => {
        // Rather than guessing at a description length limit, hand the real
        // tool list to the real provider and see whether it takes it.
        (providerConfigured() ? it : it.skip)(
            `should be accepted verbatim by the provider (${providerConfigured() ? 'live' : MISSING_KEY_MESSAGE})`,
            async () => {
                const model = await resolveModel();
                const body = await chatCompletion({
                    model,
                    messages: [{ role: 'user', content: 'Say ok.' }],
                    tools,
                    tool_choice: 'auto',
                    temperature: 0,
                    max_tokens: 2000,
                });
                expect(body.choices, 'the provider rejected our published tool schemas')
                    .to.be.an('array')
                    .with.length.greaterThan(0);
            },
        );
    });
});
