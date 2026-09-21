/* global describe it before */

// The provisioning lifecycle end to end (issue #398): a browser session
// through Caddy to authapp, authapp through PostgREST to the service RPCs,
// and authapp to a scripted fake GitHub (tests/fake-github/server.js).
// Run with `bun run test_provisioning`, which starts the fake and restarts
// authapp pointed at it; see bin/test-provisioning.sh.
//
// What tests/db and tests/rest cannot show is here: that a click on the
// repositories page converges on one repository across retries,
// interruptions, rate limits and concurrent clicks, and that what the
// platform records -- the mapping and nothing else, no submission -- is
// the same however it got there. The Go tests in authapp/ cover the
// handler's branches against an in-process fake; this suite proves the
// real wiring, the page included.
//
// Every scenario has its own student (helpers.js says why) and scripts the
// fake explicitly at its start. Like tests/db and tests/rest, the suite
// resets the shared dev database's sample data before it starts.

const {
    we,
    students,
    templates,
    templateRepos,
    priorSubmissionURL,
    githubID,
    seed,
    baselineFake,
    scriptFake,
    fakeCalls,
    waitForCall,
    callsTo,
    login,
    pagePath,
    postRepository,
    postRepositoryForm,
    getRepository,
    getPage,
    pollUntilSettled,
    studentJWT,
    facultyJWT,
    selectAs,
} = require('./helpers.js');

const sleep = ms => new Promise((resolve) => { setTimeout(resolve, ms); });

const exam = templates.exam.slug;
const project = templates.project.slug;
const scratch = templates.scratch.slug;

// Everything provisioning could write, read as faculty (who see every
// row), for showing that a request wrote nothing: compare two of these.
const platformSnapshot = async () => {
    const jwt = facultyJWT();
    const snapshot = {};
    const views = {
        repository_provisionings: 'id',
        assignment_repositories: 'id',
        assignment_submissions: 'id',
        assignment_field_submissions: 'assignment_submission_id,assignment_field_slug',
        assignment_field_submission_events: 'id',
    };
    for (const [view, order] of Object.entries(views)) {
        // eslint-disable-next-line no-await-in-loop
        snapshot[view] = await selectAs(jwt, `/${view}?order=${order}`);
    }
    return snapshot;
};

const attemptsOf = (jwt, slug) => selectAs(jwt, `/repository_provisionings?template_slug=eq.${slug}`);
const repositoriesOf = (jwt, slug) => selectAs(jwt, `/assignment_repositories?template_slug=eq.${slug}`);
const myRepositoriesOf = (jwt, slug) => selectAs(jwt, `/my_repositories?template_slug=eq.${slug}`);

describe('repository provisioning, end to end', () => {
    before(async () => {
        await seed();
    });

    it('creates one repository, records the mapping once, writes no submission, and answers ready once the contents land', async () => {
        const student = students.happy;
        // The generated repository's first two HEAD reads say "empty", as
        // GitHub does while it copies the template.
        await baselineFake({ headCallsUntilReady: 2 });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);
        const fullName = `course-org/${exam}-${student.netid}`;
        const repoURL = `https://github.com/${fullName}`;

        // What the student had handed in before any click.
        const submissionsBefore = await selectAs(jwt, '/assignment_submissions?assignment_slug=eq.exam-1');
        we.expect(submissionsBefore).to.have.lengthOf(1);
        const fieldsBefore = await selectAs(jwt, '/assignment_field_submissions?assignment_slug=eq.exam-1');
        we.expect(fieldsBefore).to.have.lengthOf(1);
        we.expect(fieldsBefore[0]).to.include({ assignment_field_slug: 'url', body: priorSubmissionURL, origin: 'student' });
        const eventsPath = `/assignment_field_submission_events?assignment_submission_id=eq.${submissionsBefore[0].id}`;
        const eventsBefore = await selectAs(facultyJWT(), eventsPath);

        const created = await postRepository(cookie, exam);
        we.expect(created.status).to.equal(202);
        we.expect(created.body).to.deep.equal({ state: 'copying', repo_url: repoURL, join_url: null });

        const polls = await pollUntilSettled(cookie, exam);
        const last = polls[polls.length - 1];
        we.expect(last.status).to.equal(200);
        we.expect(last.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });
        polls.slice(0, -1).forEach((poll) => {
            we.expect(poll.body).to.deep.equal({ state: 'copying', repo_url: repoURL, join_url: null });
        });

        let calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'GET', `/${exam}-${student.netid}/commits/HEAD`)).to.have.lengthOf(3);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`)).to.have.lengthOf(1);

        // What the platform recorded, as the student sees it: the mapping,
        // under the template and the assignment the template serves.
        const repositories = await repositoriesOf(jwt, exam);
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0]).to.include({
            template_slug: exam,
            assignment_slug: 'exam-1',
            is_team: false,
            user_id: student.id,
            team_nickname: null,
            provider: 'github',
            provider_full_name: fullName,
            provider_user_id: githubID(student),
        });
        we.expect(repositories[0].provider_repo_id).to.be.a('number');

        const mine = await myRepositoriesOf(jwt, exam);
        we.expect(mine).to.have.lengthOf(1);
        we.expect(mine[0]).to.include({
            id: repositories[0].id,
            template_slug: exam,
            label: templates.exam.label,
            assignment_slug: 'exam-1',
            template_full_name: templates.exam.template_full_name,
            repo_url: repoURL,
        });

        const attempts = await attemptsOf(jwt, exam);
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ stage: 'finalized', error_code: null, assignment_slug: 'exam-1' });
        we.expect(attempts[0].provider_repo_id).to.equal(repositories[0].provider_repo_id);
        we.expect(attempts[0].ready_at).to.be.a('string');

        // The submission is exactly as the student left it: the platform
        // wrote no field, changed none, and added no event.
        we.expect(await selectAs(jwt, '/assignment_submissions?assignment_slug=eq.exam-1')).to.deep.equal(submissionsBefore);
        we.expect(await selectAs(jwt, '/assignment_field_submissions?assignment_slug=eq.exam-1')).to.deep.equal(fieldsBefore);
        we.expect(await selectAs(facultyJWT(), eventsPath)).to.deep.equal(eventsBefore);

        // A second click is a no-op that answers ready: no generate, no new
        // rows.
        const again = await postRepository(cookie, exam);
        we.expect(again.status).to.equal(200);
        we.expect(again.body.state).to.equal('ready');
        calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(await repositoriesOf(jwt, exam)).to.have.lengthOf(1);
        we.expect(await attemptsOf(jwt, exam)).to.have.lengthOf(1);
    });

    it('resumes an attempt interrupted after generate without generating again', async () => {
        const student = students.interrupted;
        // Generate lands; the first collaborator grant fails with a 500,
        // which is authapp dying between checkpoints as far as the
        // database can tell.
        await baselineFake({ nextCollaborator: { fail: 'server_error' } });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);

        const interrupted = await postRepository(cookie, exam);
        we.expect(interrupted.status).to.equal(502);
        we.expect(interrupted.body).to.deep.equal({ error: { code: 'github_unavailable', retryable: true } });

        let attempts = await attemptsOf(jwt, exam);
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0].stage).to.equal('generated');
        const repoID = attempts[0].provider_repo_id;
        we.expect(repoID).to.be.a('number');
        we.expect(await repositoriesOf(jwt, exam)).to.have.lengthOf(0);

        const status = await getRepository(cookie, exam);
        we.expect(status.status).to.equal(409);
        we.expect(status.body).to.deep.equal({ error: { code: 'provisioning_interrupted', retryable: true } });

        const resumed = await postRepository(cookie, exam);
        we.expect(resumed.status).to.equal(200);
        we.expect(resumed.body).to.include({ state: 'ready', repo_url: `https://github.com/course-org/${exam}-${student.netid}` });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`).map(c => c.status)).to.deep.equal([500, 204]);

        // The repository recorded is the one generate returned before the
        // interruption, not a lookalike.
        const repositories = await repositoriesOf(jwt, exam);
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0].provider_repo_id).to.equal(repoID);
        attempts = await attemptsOf(jwt, exam);
        we.expect(attempts[0]).to.include({ stage: 'finalized', provider_repo_id: repoID });
    });

    it('answers needs_org_join for a pending member and creates nothing', async () => {
        const student = students.pending;
        await baselineFake({ memberships: { [student.netid]: 'pending' } });
        const cookie = await login(student.netid);

        const response = await postRepository(cookie, exam);
        we.expect(response.status).to.equal(200);
        // join_url is null unless the join flow (issue #399) is configured,
        // which this run does not do.
        we.expect(response.body).to.include({ state: 'needs_org_join', repo_url: null });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(0);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`)).to.have.lengthOf(0);
        // The attempt was claimed before the membership check and is left
        // at claimed for the next click; nothing else was written.
        const jwt = studentJWT(student.netid);
        const attempts = await attemptsOf(jwt, exam);
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ stage: 'claimed', error_code: null, provider_repo_id: null });
        we.expect(await repositoriesOf(jwt, exam)).to.have.lengthOf(0);
        we.expect(await selectAs(jwt, '/assignment_submissions?assignment_slug=eq.exam-1')).to.have.lengthOf(0);
    });

    it('refuses a destination name held by an unrelated repository', async () => {
        const student = students.collision;
        // Someone made a repository with the student's destination name
        // long ago, from another template. It is not ours to adopt.
        await baselineFake({
            repos: [
                ...templateRepos(),
                {
                    full_name: `course-org/${exam}-${student.netid}`,
                    template_full_name: 'course-org/something-else',
                    created_at: '2020-01-01T00:00:00Z',
                    ready: true,
                },
            ],
        });
        const cookie = await login(student.netid);

        const response = await postRepository(cookie, exam);
        we.expect(response.status).to.equal(409);
        we.expect(response.body).to.deep.equal({ error: { code: 'name_taken', retryable: false } });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(0);
        we.expect(callsTo(calls, 'PUT', `/collaborators/${student.netid}`)).to.have.lengthOf(0);

        // The GET reports the recorded code for staff to see; a further
        // POST would try again, and find the same repository.
        const status = await getRepository(cookie, exam);
        we.expect(status.status).to.equal(409);
        we.expect(status.body).to.deep.equal({ error: { code: 'name_taken', retryable: true } });
        const jwt = studentJWT(student.netid);
        we.expect(await repositoriesOf(jwt, exam)).to.have.lengthOf(0);
    });

    it('passes a GitHub rate limit on with Retry-After, keeps the attempt, and proceeds once it lifts', async () => {
        const student = students.limited;
        // The next generate is refused as a secondary rate limit with a
        // two-second Retry-After; no repository is created by it.
        await baselineFake({ nextGenerate: { fail: 'rate_limit', retryAfter: 2, landed: false } });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);

        const limited = await postRepository(cookie, exam);
        we.expect(limited.status).to.equal(429);
        we.expect(limited.headers['retry-after']).to.equal('2');
        we.expect(limited.body).to.deep.equal({ error: { code: 'github_rate_limited', retryable: true } });

        let attempts = await attemptsOf(jwt, exam);
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ stage: 'claimed', provider_repo_id: null });
        const attemptID = attempts[0].id;

        // Within the wait, authapp refuses without asking GitHub.
        const tooSoon = await postRepository(cookie, exam);
        we.expect(tooSoon.status).to.equal(429);
        we.expect(tooSoon.body.error.code).to.equal('github_rate_limited');
        we.expect(callsTo(await fakeCalls(), 'POST', '/generate')).to.have.lengthOf(1);

        await sleep(2500);
        const proceeded = await postRepository(cookie, exam);
        we.expect(proceeded.status).to.equal(200);
        we.expect(proceeded.body.state).to.equal('ready');
        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate').map(c => c.status)).to.deep.equal([403, 201]);

        // The same attempt carried through, and the repository it recorded
        // at generate is the one in the mapping.
        const repositories = await repositoriesOf(jwt, exam);
        we.expect(repositories).to.have.lengthOf(1);
        attempts = await attemptsOf(jwt, exam);
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

        const lost = await postRepository(cookie, exam);
        we.expect(lost.status).to.equal(502);
        we.expect(lost.body).to.deep.equal({ error: { code: 'github_unavailable', retryable: true } });

        let attempts = await attemptsOf(jwt, exam);
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0]).to.include({ stage: 'failed', error_code: 'github_unavailable', provider_repo_id: null, provider_full_name: null });
        const attemptID = attempts[0].id;
        we.expect(await repositoriesOf(jwt, exam)).to.have.lengthOf(0);

        // The retry looks the name up first, finds a repository generated
        // from our template after the attempt began, and adopts it. No
        // second generate.
        const retried = await postRepository(cookie, exam);
        we.expect(retried.status).to.equal(200);
        we.expect(retried.body).to.include({ state: 'ready', repo_url: `https://github.com/course-org/${exam}-${student.netid}` });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'GET', `/repos/course-org/${exam}-${student.netid}`).map(c => c.status)).to.deep.equal([404, 200]);
        const repositories = await repositoriesOf(jwt, exam);
        we.expect(repositories).to.have.lengthOf(1);
        attempts = await attemptsOf(jwt, exam);
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

        const first = postRepository(cookie, exam);
        const generate = await waitForCall(call => call.method === 'POST' && call.path.endsWith('/generate'));
        we.expect(generate.status).to.equal(0);
        const second = postRepository(cookie, exam);
        const responses = await Promise.all([first, second]);
        we.expect(Date.now() - startedAt).to.be.at.least(1500);
        for (const response of responses) {
            we.expect(response.status).to.equal(200);
            we.expect(response.body).to.include({ state: 'ready', repo_url: `https://github.com/course-org/${exam}-${student.netid}` });
        }

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        const jwt = studentJWT(student.netid);
        const attempts = await attemptsOf(jwt, exam);
        we.expect(attempts).to.have.lengthOf(1);
        we.expect(attempts[0].stage).to.equal('finalized');
        const repositories = await repositoriesOf(jwt, exam);
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0].provider_repo_id).to.equal(attempts[0].provider_repo_id);
        we.expect(await myRepositoriesOf(jwt, exam)).to.have.lengthOf(1);
        we.expect(await selectAs(jwt, '/assignment_submissions?assignment_slug=eq.exam-1')).to.have.lengthOf(0);
    });

    it('treats a collaborator invitation (201) as a conflict and adopts the repository on retry', async () => {
        const student = students.invited;
        await baselineFake({ collaboratorStatus: 201 });
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);

        const conflicted = await postRepository(cookie, exam);
        we.expect(conflicted.status).to.equal(409);
        we.expect(conflicted.body).to.deep.equal({ error: { code: 'collaborator_not_member', retryable: false } });
        we.expect((await attemptsOf(jwt, exam))[0])
            .to.include({ stage: 'failed', error_code: 'collaborator_not_member' });

        // Once the student is a member the grant is a 204. The retry resets
        // the attempt to claimed, finds the repository generate made last
        // time under our template, and adopts it rather than generating.
        await scriptFake({ collaboratorStatus: 204 });
        const retried = await postRepository(cookie, exam);
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
        const fullName = `course-org/${project}-damp-pond`;
        const repoURL = `https://github.com/${fullName}`;

        const created = await postRepository(cookieA, project);
        we.expect(created.status).to.equal(200);
        we.expect(created.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        for (const teammate of [teammateA, teammateB]) {
            const grants = callsTo(calls, 'PUT', `/collaborators/${teammate.netid}`);
            we.expect(grants).to.have.lengthOf(1);
            we.expect(grants[0]).to.include({
                path: `/repos/${fullName}/collaborators/${teammate.netid}`,
                status: 204,
            });
            we.expect(grants[0].body).to.deep.equal({ permission: 'push' });
        }

        // The clicker's GET and the teammate's, who did not click, answer
        // the same repository; my_repositories shows it to the teammate
        // too; and no submission was written for the team.
        const seenByA = await getRepository(cookieA, project);
        we.expect(seenByA.status).to.equal(200);
        we.expect(seenByA.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });
        const seenByB = await getRepository(cookieB, project);
        we.expect(seenByB.status).to.equal(200);
        we.expect(seenByB.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });
        const jwtB = studentJWT(teammateB.netid);
        const repositories = await repositoriesOf(jwtB, project);
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0]).to.include({
            template_slug: project,
            assignment_slug: 'project-update-1',
            is_team: true,
            team_nickname: 'damp-pond',
            user_id: null,
            provider_user_id: null,
        });
        const mineB = await myRepositoriesOf(jwtB, project);
        we.expect(mineB).to.have.lengthOf(1);
        we.expect(mineB[0]).to.include({ is_team: true, team_nickname: 'damp-pond', repo_url: repoURL, label: templates.project.label });
        const teamSubmissions = await selectAs(jwtB, '/assignment_submissions?assignment_slug=eq.project-update-1&team_nickname=eq.damp-pond');
        we.expect(teamSubmissions).to.have.lengthOf(0);

        // A teammate's click is the same repository, not a second one.
        const again = await postRepository(cookieB, project);
        we.expect(again.status).to.equal(200);
        we.expect(again.body.repo_url).to.equal(repoURL);
        we.expect(callsTo(await fakeCalls(), 'POST', '/generate')).to.have.lengthOf(1);

        // A student on another team has nothing of damp-pond's to see: not
        // the repository, the attempt, nor a row of my_repositories.
        const outsider = await getRepository(await login(students.happy.netid), project);
        we.expect(outsider.status).to.equal(404);
        we.expect(outsider.body).to.deep.equal({ error: { code: 'repository_not_started', retryable: false } });
        const jwtOutsider = studentJWT(students.happy.netid);
        we.expect(await repositoriesOf(jwtOutsider, project)).to.have.lengthOf(0);
        we.expect(await attemptsOf(jwtOutsider, project)).to.have.lengthOf(0);
        we.expect(await myRepositoriesOf(jwtOutsider, project)).to.have.lengthOf(0);
        const everything = await selectAs(jwtOutsider, '/my_repositories');
        we.expect(everything.map(r => r.team_nickname)).to.not.include('damp-pond');
    });

    it('creates a repository from a template tied to no assignment', async () => {
        const student = students.untied;
        await baselineFake();
        const cookie = await login(student.netid);
        const jwt = studentJWT(student.netid);
        const repoURL = `https://github.com/course-org/${scratch}-${student.netid}`;

        const created = await postRepository(cookie, scratch);
        we.expect(created.status).to.equal(200);
        we.expect(created.body).to.deep.equal({ state: 'ready', repo_url: repoURL, join_url: null });

        const calls = await fakeCalls();
        we.expect(callsTo(calls, 'POST', '/generate')).to.have.lengthOf(1);
        we.expect(callsTo(calls, 'POST', '/generate')[0].path).to.equal(`/repos/${templates.scratch.template_full_name}/generate`);

        const mine = await myRepositoriesOf(jwt, scratch);
        we.expect(mine).to.have.lengthOf(1);
        we.expect(mine[0]).to.include({ template_slug: scratch, assignment_slug: null, label: templates.scratch.label, repo_url: repoURL });
        const repositories = await repositoriesOf(jwt, scratch);
        we.expect(repositories).to.have.lengthOf(1);
        we.expect(repositories[0]).to.include({ template_slug: scratch, assignment_slug: null, user_id: student.id });
        we.expect((await attemptsOf(jwt, scratch))[0]).to.include({ stage: 'finalized', assignment_slug: null });
    });

    it('answers 404 for a deactivated template on both routes and creates nothing', async () => {
        const student = students.untied;
        await baselineFake();
        const cookie = await login(student.netid);

        const created = await postRepository(cookie, templates.retired.slug);
        we.expect(created.status).to.equal(404);
        we.expect(created.body).to.deep.equal({ error: { code: 'template_inactive', retryable: false } });

        const status = await getRepository(cookie, templates.retired.slug);
        we.expect(status.status).to.equal(404);
        we.expect(status.body).to.deep.equal({ error: { code: 'template_not_found', retryable: false } });

        we.expect(await fakeCalls()).to.have.lengthOf(0);
        const jwt = studentJWT(student.netid);
        we.expect(await attemptsOf(jwt, templates.retired.slug)).to.have.lengthOf(0);
        we.expect(await repositoriesOf(jwt, templates.retired.slug)).to.have.lengthOf(0);
    });

    it('renders the page for a student, with the ready link after a create, and only a note for staff', async () => {
        const student = students.page;
        await baselineFake();
        const cookie = await login(student.netid);
        const fullName = `course-org/${exam}-${student.netid}`;
        const repoURL = `https://github.com/${fullName}`;

        const untouched = await platformSnapshot();

        // Signed out: through login and back.
        const anonymous = await getPage(null);
        we.expect(anonymous.status).to.equal(302);
        we.expect(anonymous.headers.location).to.equal('/auth/login?next=%2Fauth%2Frepositories');

        // A student on a team sees every active template with a Create
        // button, their GitHub login, and no repositories yet.
        const before = await getPage(cookie);
        we.expect(before.status).to.equal(200);
        we.expect(before.headers['content-type']).to.match(/^text\/html/);
        for (const template of [templates.exam, templates.project, templates.scratch]) {
            we.expect(before.text).to.include(`<strong>${template.label}</strong>`);
            we.expect(before.text).to.include(`<form class="create" method="POST" action="${pagePath}/${template.slug}"><button type="submit">Create</button></form>`);
        }
        we.expect(before.text).to.not.include(templates.retired.label);
        we.expect(before.text).to.include(`Connected as <strong>${student.netid}</strong>`);
        we.expect(before.text).to.include('<p id="no-repositories">None yet.</p>');
        we.expect(before.text).to.include(`<script src="${pagePath}.js"></script>`);
        // Rendering the page asks GitHub nothing and writes nothing: not
        // an attempt, not a mapping, not a submission, field or event.
        we.expect(await fakeCalls()).to.have.lengthOf(0);
        we.expect(await platformSnapshot()).to.deep.equal(untouched);

        // The form post, as the page makes without its script: a 303 back
        // to the page with the outcome in the query, which the page shows
        // as a notice.
        const posted = await postRepositoryForm(cookie, exam);
        we.expect(posted.status).to.equal(303);
        we.expect(posted.headers.location).to.equal(`${pagePath}?result=ready&template=${exam}`);
        we.expect(callsTo(await fakeCalls(), 'POST', '/generate')).to.have.lengthOf(1);

        const after = await getPage(cookie, `?result=ready&template=${exam}`);
        we.expect(after.status).to.equal(200);
        we.expect(after.text).to.include(`<p class="notice" id="notice">${exam}: your repository is ready.</p>`);
        we.expect(after.text).to.include(`<li class="template" data-slug="${exam}" data-state="ready"`);
        we.expect(after.text).to.include(`<p class="message">Ready: <a href="${repoURL}">${repoURL}</a></p>`);
        we.expect(after.text).to.not.include(`<form class="create" method="POST" action="${pagePath}/${exam}"`);
        we.expect(after.text).to.include(`<li data-slug="${exam}"><a href="${repoURL}">${fullName}</a> — ${templates.exam.label}</li>`);
        we.expect(after.text).to.not.include('id="no-repositories"');
        // The other templates still offer Create.
        we.expect(after.text).to.include(`<form class="create" method="POST" action="${pagePath}/${scratch}"`);
        we.expect(after.text).to.include(`<form class="create" method="POST" action="${pagePath}/${project}"`);

        // The script is served, and it is the file whose arithmetic
        // `bun test authapp/static` covers.
        const script = await getPage(cookie, '.js');
        we.expect(script.status).to.equal(200);
        we.expect(script.headers['content-type']).to.match(/^text\/javascript/);
        we.expect(script.text).to.include('function nextPollDelay');

        // Staff get the students-only page: no template, no button, and
        // nothing written to render it either.
        const afterCreate = await platformSnapshot();
        const faculty = await getPage(await login('klj39'));
        we.expect(faculty.status).to.equal(200);
        we.expect(faculty.text).to.include('This page is for students');
        we.expect(faculty.text).to.not.include('class="template"');
        we.expect(faculty.text).to.not.include('form class="create"');
        for (const template of Object.values(templates)) {
            we.expect(faculty.text).to.not.include(template.label);
        }
        we.expect(await platformSnapshot()).to.deep.equal(afterCreate);
    });
});
