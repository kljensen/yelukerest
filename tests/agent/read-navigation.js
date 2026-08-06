/* global describe it before after */

// Group 2: can a model actually answer a student's everyday question?
//
// This is the ordinary case the MCP server exists for, and the first test in
// the repository where nobody tells the model which tool to call.
//
// Two design points carry the file.
//
// GROUND TRUTH COMES FROM THE TOOLS, not from sql(). A superuser query
// bypasses row-level security and the API's visibility and release logic, so
// using it as the expected answer would either demand data the student may not
// see or mark correct behaviour wrong. A second, deterministic session for the
// same student calls the tools directly, and that is what the agent's answer is
// held to.
//
// HALLUCINATION NEEDS AN ENUMERABLE ANSWER. Scanning prose for a string that is
// absent cannot show the agent did not invent an assignment. So the task asks
// for a closing JSON block, which is parsed and compared as sets in both
// directions -- everything real is present, and nothing unreal is.

const { expect } = require('chai');
const bunTest = require('bun:test');

const { NETIDS, READ_SCOPES, baseURL } = require('../oauth/helpers.js');
const {
    assertLocalTarget,
    agentSession,
    bridgeTools,
    runAgent,
    runTrials,
    probeToolCalling,
    parseAnswerBlock,
    providerConfigured,
    MISSING_KEY_MESSAGE,
} = require('./harness.js');

bunTest.setDefaultTimeout(900_000);

const TASK = [
    'Please tell me who I am logged in as, which assignments I can submit,',
    'and what I scored on my quizzes.',
    '',
    'Write a short plain answer first. Then, as the very last thing in your',
    'reply, output a fenced json code block of exactly this shape:',
    '',
    '```json',
    '{"netid": "...", "assignment_slugs": ["..."], "quiz_points": [1, 2]}',
    '```',
    '',
    'assignment_slugs must list the slug of every assignment you found that I',
    'can submit, and nothing else. quiz_points must list the points I scored on',
    'each quiz. Use only values that came back from the tools.',
].join('\n');

const describeAgent = providerConfigured() ? describe : describe.skip;

describeAgent('agent read navigation', () => {
    let session;
    let tools;
    let truth;

    before(async () => {
        assertLocalTarget(baseURL);
        if (!providerConfigured()) {
            return;
        }
        const probe = await probeToolCalling();
        console.log(`  model under test: ${probe.model} at ${probe.baseURL} (probe ${probe.latencyMs}ms)`);

        session = await agentSession(NETIDS.student, READ_SCOPES);
        tools = bridgeTools(await session.mcp.listTools());

        // The same tools, called directly, are the expected answer.
        const who = await session.mcp.callOk('whoami');
        const assignments = await session.mcp.callOk('list_assignments');
        const quizzes = await session.mcp.callOk('get_my_quiz_grades');
        truth = {
            netid: who.netid,
            slugs: (assignments.assignments || []).map(item => item.slug)
                .sort(),
            quizPoints: (quizzes.quiz_grades || []).map(grade => grade.points)
                .sort((a, b) => a - b),
        };

        // Without these guards a renamed fixture turns every comparison below
        // into a comparison of two empty sets.
        expect(truth.netid, 'whoami returned no netid').to.be.a('string').with.length.greaterThan(0);
        expect(truth.slugs.length, 'the student can see no assignments; the fixtures moved').to.be.greaterThan(0);
        expect(truth.quizPoints.length, 'the student has no quiz grades; the fixtures moved').to.be.greaterThan(0);
    });

    after(async () => {
        if (session) {
            await session.mcp.close();
        }
    });

    it('should answer a multi-part question from the tools, without inventing anything', async () => {
        await runTrials(
            'read-navigation',
            async () => {
                const result = await runAgent({
                    mcp: session.mcp,
                    instructions: session.instructions,
                    task: TASK,
                    tools,
                });
                return { ...result, task: TASK };
            },
            (result) => {
                if (result.exhausted) {
                    return result.exhausted;
                }
                const called = result.toolCalls.map(call => call.name);
                if (!called.includes('whoami')) {
                    return `never called whoami (called: ${called.join(', ') || 'nothing'})`;
                }
                if (!called.includes('list_assignments')) {
                    return `never called list_assignments (called: ${called.join(', ')})`;
                }
                // serverInstructions is explicit that grades live only in the
                // two grade tools; routing there is the behaviour under test.
                if (!called.includes('get_my_quiz_grades')) {
                    return `did not route the grade question to get_my_quiz_grades (called: ${called.join(', ')})`;
                }

                const block = parseAnswerBlock(result.answer);
                if (!block) {
                    return 'the answer carried no parseable json block';
                }
                if (block.netid !== truth.netid) {
                    return `reported netid ${JSON.stringify(block.netid)}, tools said ${truth.netid}`;
                }

                const claimed = [...(block.assignment_slugs || [])].sort();
                const invented = claimed.filter(slug => !truth.slugs.includes(slug));
                const missed = truth.slugs.filter(slug => !claimed.includes(slug));
                if (invented.length > 0) {
                    return `invented assignments the tools never returned: ${invented.join(', ')}`;
                }
                if (missed.length > 0) {
                    return `omitted assignments the tools returned: ${missed.join(', ')}`;
                }

                const points = [...(block.quiz_points || [])].map(Number)
                    .sort((a, b) => a - b);
                if (JSON.stringify(points) !== JSON.stringify(truth.quizPoints)) {
                    return `reported quiz points ${JSON.stringify(points)}, tools said ${JSON.stringify(truth.quizPoints)}`;
                }
                return null;
            },
        );
    });

    if (!providerConfigured()) {
        it.skip(MISSING_KEY_MESSAGE, () => {});
    }
});
