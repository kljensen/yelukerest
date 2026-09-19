/* global describe it before */

// The provisioning lifecycle end to end (issue #398): a browser session
// through Caddy to authapp, authapp through PostgREST to the service RPCs,
// and authapp to a scripted fake GitHub (tests/fake-github/server.js).
// Run with `bun run test_provisioning`, which starts the fake and restarts
// authapp pointed at it; see bin/test-provisioning.sh.
//
// What tests/db and tests/rest cannot show is here: that a click converges
// on one repository across retries, interruptions, rate limits and
// concurrent clicks, and that what the platform records -- the mapping,
// the submission, the URL field's origin, the event count -- is the same
// however it got there. The Go tests in authapp/ cover the handler's
// branches against an in-process fake; this suite proves the real wiring.
//
// Every scenario has its own student (helpers.js says why) and scripts the
// fake explicitly at its start. Like tests/db and tests/rest, the suite
// resets the shared dev database's sample data before it starts.

const {
    we,
    students,
    githubID,
    seed,
    baselineFake,
    scriptFake,
    fakeCalls,
    waitForCall,
    callsTo,
    login,
    postRepository,
    getRepository,
    pollUntilSettled,
    studentJWT,
    facultyJWT,
    selectAs,
} = require('./helpers.js');

const sleep = ms => new Promise((resolve) => { setTimeout(resolve, ms); });

describe('assignment repository provisioning, end to end', () => {
    before(async () => {
        await seed();
    });

    it('creates one repository, records it once, and answers ready once the contents land', async () => {
        const student = students.happy;
        // The generated repository's first two HEAD reads say "empty", as
        // GitHub does while it copies the template.
        await baselineFake({ headCallsUntilReady: 2 });
        const cookie = await login(student.netid);
        const repoURL = `https://github.com/course-org/exam-1-${student.netid}`;

        const created = await postRepository(cookie, 'exam-1');
        we.expect(created.status).to.equal(202);
        we.expect(created.body).to.deep.equal({ state: 'copying', repo_url: repoURL, join_url: null });

        const polls = await pollUntilSettled(cookie, 'exam-1');
        const last = polls[polls.length - 1];
        we.expect(last.status).to.equal(200);
        we.expect(last.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });
        polls.slice(0, -1).forEach((poll) => {
            we.expect(poll.body).to.deep.equal({ state: 'copying', repo_url: repoURL, join_url: null });
        });

        let calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'GET', `/exam-1-${student.netid}/commits/HEAD`)).to.have.lengthOf(3);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`)).to.have.lengthOf(1);

        // What the platform recorded, as the student sees it.
        const jwt = studentJWT(student.netid);
        const repositories = await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1');
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0]).to.include({
            assignment_slug: 'exam-1',
            is_team: false,
            user_id: student.id,
            team_nickname: null,
            provider: 'github',
            provider_full_name: `course-org/exam-1-${student.netid}`,
            provider_user_id: githubID(student),
        });
        we.expect(repositories[0].provider_repo_id).to.be.a('number');

        const submissions = await selectAs(jwt, '/assignment_submissions?assignment_slug=eq.exam-1');
        we.expect(submissions).to.have.lengthOf(1);
        we.expect(submissions[0]).to.include({ user_id: student.id, submitter_user_id: student.id });

        const fields = await selectAs(jwt, '/assignment_field_submissions?assignment_slug=eq.exam-1');
        we.expect(fields).to.have.lengthOf(1);
        we.expect(fields[0]).to.include({
            assignment_field_slug: 'url',
            body: repoURL,
            origin: 'provisioning',
            submitter_user_id: student.id,
        });

        // The event ledger is faculty's to read.
        const eventsPath = `/assignment_field_submission_events?assignment_submission_id=eq.${submissions[0].id}`;
        const events = await selectAs(facultyJWT(), eventsPath);
        we.expect(events).to.have.lengthOf(1);
        we.expect(events[0]).to.include({ assignment_field_slug: 'url', event_type: 'submitted' });

        const attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ stage: 'finalized', error_code: null });
        we.expect(attempts[0].provider_repo_id).to.equal(repositories[0].provider_repo_id);
        we.expect(attempts[0].ready_at).to.be.a('string');

        // A second click is a no-op that answers ready: no generate, no new
        // rows, no new event.
        const again = await postRepository(cookie, 'exam-1');
        we.expect(again.status).to.equal(200);
        we.expect(again.body.state).to.equal('ready');
        calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1')).to.have.lengthOf(1);
        we.expect(await selectAs(facultyJWT(), eventsPath)).to.have.lengthOf(1);
    });

    it('resumes an attempt interrupted after generate without generating again', async () => {
        const student = students.interrupted;
        // Generate lands; the first collaborator grant fails with a 500,
        // which is authapp dying between checkpoints as far as the
        // database can tell.
        await baselineFake({ nextCollaborator: { fail: 'server_error' } });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);

        const interrupted = await postRepository(cookie, 'exam-1');
        we.expect(interrupted.status).to.equal(502);
        we.expect(interrupted.body).to.deep.equal({ error: { code: 'github_unavailable', retryable: true } });

        let attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0].stage).to.equal('generated');
        const repoID = attempts[0].provider_repo_id;
        we.expect(repoID).to.be.a('number');
        we.expect(await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1')).to.have.lengthOf(0);

        const status = await getRepository(cookie, 'exam-1');
        we.expect(status.status).to.equal(409);
        we.expect(status.body).to.deep.equal({ error: { code: 'provisioning_interrupted', retryable: true } });

        const resumed = await postRepository(cookie, 'exam-1');
        we.expect(resumed.status).to.equal(200);
        we.expect(resumed.body).to.include({ state: 'ready', repo_url: `https://github.com/course-org/exam-1-${student.netid}` });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`).map(c => c.status)).to.deep.equal([500, 204]);

        // The repository recorded is the one generate returned before the
        // interruption, not a lookalike.
        const repositories = await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1');
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0].provider_repo_id).to.equal(repoID);
        attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts[0]).to.include({ stage: 'finalized', provider_repo_id: repoID });
    });

    it('answers needs_org_join for a pending member and creates nothing', async () => {
        const student = students.pending;
        await baselineFake({ memberships: { [student.netid]: 'pending' } });
        const cookie = await login(student.netid);

        const response = await postRepository(cookie, 'exam-1');
        we.expect(response.status).to.equal(200);
        // join_url is null unless the join flow (issue #399) is configured,
        // which this run does not do.
        we.expect(response.body).to.include({ state: 'needs_org_join', repo_url: null });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(0);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`)).to.have.lengthOf(0);
        const jwt = studentJWT(student.netid);
        we.expect(await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1')).to.have.lengthOf(0);
        we.expect(await selectAs(jwt, '/assignment_submissions?assignment_slug=eq.exam-1')).to.have.lengthOf(0);
    });

    it('refuses a destination name held by an unrelated repository', async () => {
        const student = students.collision;
        // Someone made a repository with the student's destination name
        // long ago, from another template. It is not ours to adopt.
        await baselineFake({
            repos: [
                { full_name: 'course-org/starter', ready: true },
                { full_name: 'course-org/proj-starter', ready: true },
                {
                    full_name: `course-org/exam-1-${student.netid}`,
                    template_full_name: 'course-org/something-else',
                    created_at: '2020-01-01T00:00:00Z',
                    ready: true,
                },
            ],
        });
        const cookie = await login(student.netid);

        const response = await postRepository(cookie, 'exam-1');
        we.expect(response.status).to.equal(409);
        we.expect(response.body).to.deep.equal({ error: { code: 'name_taken', retryable: false } });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(0);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`)).to.have.lengthOf(0);

        // The GET reports the recorded code for staff to see; a further
        // POST would try again, and find the same repository.
        const status = await getRepository(cookie, 'exam-1');
        we.expect(status.status).to.equal(409);
        we.expect(status.body).to.deep.equal({ error: { code: 'name_taken', retryable: true } });
        const jwt = studentJWT(student.netid);
        we.expect(await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1')).to.have.lengthOf(0);
    });

    it('passes a GitHub rate limit on with Retry-After, keeps the attempt, and proceeds once it lifts', async () => {
        const student = students.limited;
        // The next generate is refused as a secondary rate limit with a
        // two-second Retry-After; no repository is created by it.
        await baselineFake({ nextGenerate: { fail: 'rate_limit', retryAfter: 2, landed: false } });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);

        const limited = await postRepository(cookie, 'exam-1');
        we.expect(limited.status).to.equal(429);
        we.expect(limited.headers['retry-after']).to.equal('2');
        we.expect(limited.body).to.deep.equal({ error: { code: 'github_rate_limited', retryable: true } });

        let attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ stage: 'claimed', provider_repo_id: null });
        const attemptID = attempts[0].id;

        // Within the wait, authapp refuses without asking GitHub.
        const tooSoon = await postRepository(cookie, 'exam-1');
        we.expect(tooSoon.status).to.equal(429);
        we.expect(tooSoon.body.error.code).to.equal('github_rate_limited');
        we.expect(callsTo(await fakeCalls(), 'POST', '/generate')).to.have.lengthOf(1);

        await sleep(2500);
        const proceeded = await postRepository(cookie, 'exam-1');
        we.expect(proceeded.status).to.equal(200);
        we.expect(proceeded.body.state).to.equal('ready');
        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate').map(c => c.status)).to.deep.equal([403, 201]);

        // The same attempt carried through, and the repository it recorded
        // at generate is the one in the mapping.
        const repositories = await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1');
        we.expect(repositories).to.have.lengthOf(1);
        attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ id: attemptID, stage: 'finalized', provider_repo_id: repositories[0].provider_repo_id });
    });

    it('recovers a generate whose reply was lost after the repository landed', async () => {
        const student = students.hangup;
        // The dangerous window: GitHub creates the repository and the reply
        // never arrives. Nothing can be recorded, because nothing came back.
        await baselineFake({ nextGenerate: { fail: 'hangup', landed: true } });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);

        const lost = await postRepository(cookie, 'exam-1');
        we.expect(lost.status).to.equal(502);
        we.expect(lost.body).to.deep.equal({ error: { code: 'github_unavailable', retryable: true } });

        let attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ stage: 'failed', error_code: 'github_unavailable', provider_repo_id: null, provider_full_name: null });
        const attemptID = attempts[0].id;
        we.expect(await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1')).to.have.lengthOf(0);

        // The retry looks the name up first, finds a repository generated
        // from our template after the attempt began, and adopts it. No
        // second generate.
        const retried = await postRepository(cookie, 'exam-1');
        we.expect(retried.status).to.equal(200);
        we.expect(retried.body).to.include({ state: 'ready', repo_url: `https://github.com/course-org/exam-1-${student.netid}` });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'GET', `/repos/course-org/exam-1-${student.netid}`).map(c => c.status)).to.deep.equal([404, 200]);
        const repositories = await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1');
        we.expect(repositories).to.have.lengthOf(1);
        attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts[0]).to.include({ id: attemptID, stage: 'finalized', provider_repo_id: repositories[0].provider_repo_id });
    });

    it('serves two overlapping clicks from one student with one generate', async () => {
        const student = students.concurrent;
        // Generate takes 1.5 s at the fake. The second click is sent once
        // the first's generate is in flight, so the two requests genuinely
        // overlap inside authapp rather than merely being issued together.
        await baselineFake({ generateDelayMs: 1500 });
        const cookie = await login(student.netid);
        const startedAt = Date.now();

        const first = postRepository(cookie, 'exam-1');
        const generate = await waitForCall(call => call.method === 'POST' && call.path.endsWith('/generate'));
        we.expect(generate.status).to.equal(0);
        const second = postRepository(cookie, 'exam-1');
        const responses = await Promise.all([first, second]);
        we.expect(Date.now() - startedAt).to.be.at.least(1500);
        for (const response of responses) {
            we.expect(response.status).to.equal(200);
            we.expect(response.body).to.include({ state: 'ready', repo_url: `https://github.com/course-org/exam-1-${student.netid}` });
        }

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        const jwt = studentJWT(student.netid);
        const attempts = await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1');
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0].stage).to.equal('finalized');
        const repositories = await selectAs(jwt, '/assignment_repositories?assignment_slug=eq.exam-1');
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0].provider_repo_id).to.equal(attempts[0].provider_repo_id);
        const submissions = await selectAs(jwt, '/assignment_submissions?assignment_slug=eq.exam-1');
        we.expect(submissions).to.have.lengthOf(1);
        we.expect(await selectAs(jwt, '/assignment_field_submissions?assignment_slug=eq.exam-1')).to.have.lengthOf(1);
        we.expect(await selectAs(facultyJWT(), `/assignment_field_submission_events?assignment_submission_id=eq.${submissions[0].id}`)).to.have.lengthOf(1);
    });

    it('treats a collaborator invitation (201) as a conflict and adopts the repository on retry', async () => {
        const student = students.invited;
        await baselineFake({ collaboratorStatus: 201 });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);

        const conflicted = await postRepository(cookie, 'exam-1');
        we.expect(conflicted.status).to.equal(409);
        we.expect(conflicted.body).to.deep.equal({ error: { code: 'collaborator_not_member', retryable: false } });
        we.expect((await selectAs(jwt, '/assignment_repository_provisionings?assignment_slug=eq.exam-1'))[0])
            .to.include({ stage: 'failed', error_code: 'collaborator_not_member' });

        // Once the student is a member the grant is a 204. The retry resets
        // the attempt to claimed, finds the repository generate made last
        // time under our template, and adopts it rather than generating.
        await scriptFake({ collaboratorStatus: 204 });
        const retried = await postRepository(cookie, 'exam-1');
        we.expect(retried.status).to.equal(200);
        we.expect(retried.body.state).to.equal('ready');
        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`).map(c => c.status)).to.deep.equal([201, 204]);
    });

    it('provisions one team repository, grants every teammate, and hides it from others', async () => {
        const { teammateA, teammateB } = students;
        await baselineFake();
        const cookieA = await login(teammateA.netid);
        const cookieB = await login(teammateB.netid);
        const repoURL = 'https://github.com/course-org/project-update-1-damp-pond';

        const created = await postRepository(cookieA, 'project-update-1');
        we.expect(created.status).to.equal(200);
        we.expect(created.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        for (const teammate of [teammateA, teammateB]) {
            const grants = callsTo(calls, 'PUT', `/collaborators/${teammate.netid}`);
            we.expect(grants).to.have.lengthOf(1);
            we.expect(grants[0]).to.include({
                path: `/repos/course-org/project-update-1-damp-pond/collaborators/${teammate.netid}`,
                status: 204,
            });
            we.expect(grants[0].body).to.deep.equal({ permission: 'push' });
        }

        // The teammate who did not click sees the same repository.
        const seenByB = await getRepository(cookieB, 'project-update-1');
        we.expect(seenByB.status).to.equal(200);
        we.expect(seenByB.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });
        const jwtB = studentJWT(teammateB.netid);
        const repositories = await selectAs(jwtB, '/assignment_repositories?assignment_slug=eq.project-update-1');
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0]).to.include({
            is_team: true, team_nickname: 'damp-pond', user_id: null, provider_user_id: null,
        });
        const fields = await selectAs(jwtB, '/assignment_field_submissions?assignment_slug=eq.project-update-1');
        we.expect(fields).to.have.lengthOf(1);
        we.expect(fields[0]).to.include({ assignment_field_slug: 'repo-url', body: repoURL, origin: 'provisioning' });

        // A teammate's click is the same repository, not a second one.
        const again = await postRepository(cookieB, 'project-update-1');
        we.expect(again.status).to.equal(200);
        we.expect(again.body.repo_url).to.equal(repoURL);
        we.expect(callsTo(await fakeCalls(), 'POST', '/generate')).to.have.lengthOf(1);

        // A student on another team has nothing of damp-pond's to see: not
        // the repository, the attempt, the submission, nor the field.
        const outsider = await getRepository(await login(students.happy.netid), 'project-update-1');
        we.expect(outsider.status).to.equal(404);
        we.expect(outsider.body).to.deep.equal({ error: { code: 'repository_not_started', retryable: false } });
        const jwtOutsider = studentJWT(students.happy.netid);
        we.expect(await selectAs(jwtOutsider, '/assignment_repositories?assignment_slug=eq.project-update-1')).to.have.lengthOf(0);
        we.expect(await selectAs(jwtOutsider, '/assignment_repository_provisionings?assignment_slug=eq.project-update-1')).to.have.lengthOf(0);
        const outsiderSubmissions = await selectAs(jwtOutsider, '/assignment_submissions?assignment_slug=eq.project-update-1');
        we.expect(outsiderSubmissions.map(s => s.team_nickname)).to.not.include('damp-pond');
        const outsiderFields = await selectAs(jwtOutsider, '/assignment_field_submissions?assignment_slug=eq.project-update-1');
        we.expect(outsiderFields.map(f => f.body)).to.not.include(repoURL);
    });
});
