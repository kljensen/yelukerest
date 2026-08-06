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
// The scope checks pin down the write path's only gate on both mechanisms --
// submit_submission_change and the postgrest_request escape hatch -- without a
// model in the loop. The agent files exercise the same boundary through a real
// model, but a model is free to attempt no write at all, so the mechanism is
// established here and the behaviour is measured there.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS, WRITE_SCOPES, READ_SCOPES, baseURL, sql,
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
        session = await agentSession(NETIDS.student, WRITE_SCOPES);
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

    describe('the scope boundary', () => {
        // Deterministic coverage of the only gate the write path has. The
        // model-driven files exercise the same boundary through an agent, but
        // a model is free not to attempt a write at all, so the mechanism is
        // pinned down here.

        it('should let a write-scoped token write, with no ceremony', async () => {
            const body = `Written with the write scope ${Date.now()}.`;
            const result = await session.mcp.callOk('submit_submission_change', {
                assignment_slug: ASSIGNMENT, field_slug: FIELD, body,
            });
            expect(result.body)
                .to.equal(body);
            expect(storedBodies())
                .to.contain(body);
        });

        it('should refuse a write for a read-only token, and write nothing', async () => {
            const reader = await agentSession(NETIDS.student, READ_SCOPES);
            const before_ = storedBodies();
            const message = await reader.mcp.callExpectError('submit_submission_change', {
                assignment_slug: ASSIGNMENT, field_slug: FIELD, body: 'Written without the scope.',
            });
            expect(message.toLowerCase())
                .to.contain('scope');
            expect(storedBodies())
                .to.deep.equal(before_);
            await reader.mcp.close();
        });

        it('should preview without needing the write scope, and write nothing', async () => {
            const reader = await agentSession(NETIDS.student, READ_SCOPES);
            const before_ = storedBodies();
            const summary = await reader.mcp.callOk('preview_submission_change', {
                assignment_slug: ASSIGNMENT, field_slug: FIELD, body: 'Only previewed.',
            });
            expect(summary.proposed_body)
                .to.equal('Only previewed.');
            expect(storedBodies())
                .to.deep.equal(before_);
            await reader.mcp.close();
        });

        it('should gate the escape hatch on the verb, not on a token dance', async () => {
            const reader = await agentSession(NETIDS.student, READ_SCOPES);
            const read = await reader.mcp.callOk('postgrest_request', {
                method: 'GET', path: '/assignments', query: { select: 'slug' },
            });
            expect(read.status)
                .to.equal(200);
            const message = await reader.mcp.callExpectError('postgrest_request', {
                method: 'DELETE',
                path: '/assignment_field_submissions',
                query: { assignment_slug: `eq.${ASSIGNMENT}` },
            });
            expect(message.toLowerCase())
                .to.contain('scope');
            await reader.mcp.close();
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
