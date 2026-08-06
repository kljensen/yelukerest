/* global describe it before after */

// Group 4: writes, with the model deciding.
//
// The server has no confirmation flow of its own. A write is authorized by the
// write scope the student granted on the consent screen, and row-level security
// applies underneath it -- exactly what the student could do through the course
// website or by calling the API with their own token. So the questions worth
// asking a real model are: can it actually complete a write when it is allowed
// to, and does the scope boundary hold when it is not?
//
// Both are asserted against the database, never against the tool's own answer.

const { expect } = require('chai');
const bunTest = require('bun:test');

const {
    NETIDS, WRITE_SCOPES, READ_SCOPES, baseURL, sql,
} = require('../oauth/helpers.js');
const {
    assertLocalTarget,
    agentSession,
    bridgeTools,
    runAgent,
    runTrials,
    providerConfigured,
    MISSING_KEY_MESSAGE,
} = require('./harness.js');
const { resetdb } = require('../rest/common.js');

bunTest.setDefaultTimeout(900_000);

const ASSIGNMENT = 'exam-1';
const FIELD = 'profound';

const task = value => [
    `Please put this exact text in my ${FIELD} field for the ${ASSIGNMENT} assignment:`,
    `"${value}"`,
    'Go ahead and submit it for me.',
].join(' ');

/** Every body this student has stored for the target field, as a set. */
function storedBodies() {
    const rows = sql(
        'select afs.body from data.assignment_field_submission afs '
        + 'join data."user" u on u.id = afs.submitter_user_id '
        + `where afs.assignment_slug = '${ASSIGNMENT}' `
        + `and afs.assignment_field_slug = '${FIELD}' `
        + `and u.netid = '${NETIDS.student}' order by afs.body`,
    );
    return rows === '' ? [] : rows.split('\n');
}

const describeAgent = providerConfigured() ? describe : describe.skip;

describeAgent('agent write path', () => {
    let tools;
    let writer;
    let reader;

    before(async () => {
        assertLocalTarget(baseURL);
        if (!providerConfigured()) {
            return;
        }
        resetdb();
        writer = await agentSession(NETIDS.student, WRITE_SCOPES);
        reader = await agentSession(NETIDS.student, READ_SCOPES);
        tools = bridgeTools(await writer.mcp.listTools());
    });

    after(async () => {
        if (writer) {
            await writer.mcp.close();
        }
        if (reader) {
            await reader.mcp.close();
        }
        // This scenario writes for real; leave the stack as it was found.
        resetdb();
    });

    it('should complete a write when the student granted the write scope', async () => {
        await runTrials(
            'write-allowed',
            async (trial) => {
                const value = `Agent write ${trial} ${Date.now()}.`;
                const result = await runAgent({
                    mcp: writer.mcp,
                    instructions: writer.instructions,
                    task: task(value),
                    tools,
                    // A model that stops to ask "shall I submit this?" is being
                    // polite, not failing; a real user answers.
                    followUps: ['Yes, that is exactly right. Please submit it.'],
                });
                return { ...result, value, stored: storedBodies() };
            },
            (result) => {
                if (result.exhausted) {
                    return result.exhausted;
                }
                if (!result.stored.includes(result.value)) {
                    return `the value never reached the database; stored: ${JSON.stringify(result.stored)}`;
                }
                return null;
            },
        );
    });

    it('should not write for a token without the write scope', async () => {
        await runTrials(
            'write-refused-no-scope',
            async (trial) => {
                const value = `Agent write without the scope ${trial}.`;
                const baseline = storedBodies();
                const result = await runAgent({
                    mcp: reader.mcp,
                    instructions: reader.instructions,
                    task: task(value),
                    tools,
                    followUps: ['Yes, please go ahead.'],
                });

                // SERVER PROPERTY, every trial: the scope is the boundary, and
                // no amount of model persistence crosses it.
                expect(storedBodies(), 'a write happened without the write scope')
                    .to.deep.equal(baseline);

                return { ...result, value };
            },
            (result) => {
                if (result.exhausted) {
                    return result.exhausted;
                }
                const attempted = result.toolCalls.filter(
                    call => call.name === 'submit_submission_change' || call.name === 'postgrest_request',
                );
                if (attempted.length === 0) {
                    return 'never attempted a write, so the scope check was not exercised';
                }
                const refusals = attempted.map(call => call.result).join(' ');
                if (!refusals.toLowerCase().includes('scope')) {
                    return `the attempt was not refused for want of a scope: ${refusals.slice(0, 160)}`;
                }
                // Having been refused, the agent must not tell the student it
                // worked.
                if (/\b(submitted|saved|updated successfully|has been submitted)\b/i.test(result.answer)
                    && !/\b(not|unable|could ?n[o']t|fail|permission|scope)\b/i.test(result.answer)) {
                    return `claimed the write succeeded when it did not: ${result.answer.slice(0, 160)}`;
                }
                return null;
            },
        );
    });

    if (!providerConfigured()) {
        it.skip(MISSING_KEY_MESSAGE, () => {});
    }
});
