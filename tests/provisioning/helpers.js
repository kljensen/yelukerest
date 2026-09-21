// Helpers for the provisioning integration suite (issue #398): the fake
// GitHub's admin API, a logged-in student session, the repositories page
// and its per-template routes, and the sample-data seed.
// bin/test-provisioning.sh starts the fake and restarts authapp pointed at
// it before `bun test` runs lifecycle.js.
const request = require('supertest');

const {
    baseURL,
    authPath,
    jwtPath,
    resetdb,
    runSQL,
    restService,
} = require('../rest/common.js');
const { getUserSessionCookie, getJWTForNetid, we } = require('../rest/yeluke/helpers.js');

const fakeURL = process.env.FAKE_GITHUB_URL || 'http://127.0.0.1:4099';

// The credential authapp was started with. No response from the platform
// may ever contain it; every response in this suite is checked.
const secret = process.env.GITHUB_PROVISIONER_TOKEN || 'fake-token';

const scriptFake = async (patch) => {
    const response = await fetch(`${fakeURL}/__fake/state`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(patch),
    });
    if (response.status !== 204) {
        throw new Error(`fake GitHub refused state: ${response.status}`);
    }
};

const fakeCalls = async () => {
    const response = await fetch(`${fakeURL}/__fake/calls`);
    return response.json();
};

// Polls the call log until a call matching the predicate is there, at most
// `attempts` times 50 ms apart. Returns the entry.
const waitForCall = async (predicate, attempts = 60) => {
    for (let i = 0; i < attempts; i += 1) {
        // eslint-disable-next-line no-await-in-loop
        const found = (await fakeCalls()).find(predicate);
        if (found) {
            return found;
        }
        // eslint-disable-next-line no-await-in-loop
        await new Promise((resolve) => { setTimeout(resolve, 50); });
    }
    throw new Error('the fake never saw the expected call');
};

// Calls matching a method and a path suffix, e.g. ('POST', '/generate').
const callsTo = (calls, method, pathSuffix) => calls
    .filter(call => call.method === method && call.path.endsWith(pathSuffix));

const assertNoSecret = (response) => {
    const everything = JSON.stringify(response.headers) + (response.text || '');
    we.expect(everything).to.not.include(secret);
};

const login = async (netid) => {
    const cookie = await getUserSessionCookie(baseURL, authPath, netid);
    if (!cookie) {
        throw new Error(`no session cookie for ${netid}`);
    }
    return cookie;
};

// The page and its per-template routes. A POST carries Sec-Fetch-Site the
// way a browser does; without it authapp refuses the request as
// cross-site. `Accept: application/json` is what the page's script sends
// and what makes the POST answer JSON rather than a redirect.
const pagePath = '/auth/repositories';
const repositoryRoute = slug => `${pagePath}/${slug}`;

const postRepository = async (cookie, slug) => {
    const response = await request(baseURL)
        .post(repositoryRoute(slug))
        .set('Cookie', cookie)
        .set('Sec-Fetch-Site', 'same-origin')
        .set('Accept', 'application/json')
        .send({});
    assertNoSecret(response);
    return response;
};

// A native form post, as the page makes without its script: a navigation
// that accepts HTML and says nothing about JSON. Redirects are not
// followed so the 303 itself can be checked.
const postRepositoryForm = async (cookie, slug) => {
    const response = await request(baseURL)
        .post(repositoryRoute(slug))
        .set('Cookie', cookie)
        .set('Sec-Fetch-Site', 'same-origin')
        .set('Sec-Fetch-Mode', 'navigate')
        .set('Accept', 'text/html')
        .type('form')
        .redirects(0)
        .ok(res => res.status < 400)
        .send('');
    assertNoSecret(response);
    return response;
};

const getRepository = async (cookie, slug) => {
    const response = await request(baseURL)
        .get(repositoryRoute(slug))
        .set('Cookie', cookie)
        .set('Accept', 'application/json');
    assertNoSecret(response);
    return response;
};

// The page itself, as a browser would ask for it; `query` is appended as
// is. No cookie means a signed-out visitor. Redirects are not followed.
const getPage = async (cookie, query = '') => {
    let req = request(baseURL)
        .get(pagePath + query)
        .set('Accept', 'text/html')
        .redirects(0)
        .ok(res => res.status < 400);
    if (cookie) {
        req = req.set('Cookie', cookie);
    }
    const response = await req;
    assertNoSecret(response);
    return response;
};

// Polls GET until it stops answering 202 copying, at most `attempts`
// times one second apart. Returns every response seen, in order.
const pollUntilSettled = async (cookie, slug, attempts = 15) => {
    const seen = [];
    for (let i = 0; i < attempts; i += 1) {
        // eslint-disable-next-line no-await-in-loop
        const response = await getRepository(cookie, slug);
        seen.push(response);
        if (response.status !== 202) {
            return seen;
        }
        // eslint-disable-next-line no-await-in-loop
        await new Promise((resolve) => { setTimeout(resolve, 1000); });
    }
    return seen;
};

// PostgREST as a student, for checking what the platform recorded; and as
// faculty, for configuring templates and for the event ledger students
// cannot read.
const studentJWT = netid => getJWTForNetid(baseURL, authPath, jwtPath, netid);
const facultyJWT = () => getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

const selectAs = async (jwt, path) => {
    const response = await restService()
        .get(path)
        .set('Authorization', `Bearer ${await jwt}`)
        .expect(200);
    return response.body;
};

const postAsFaculty = async (path, body) => {
    const jwt = await facultyJWT();
    await restService()
        .post(path)
        .set('Authorization', `Bearer ${jwt}`)
        .send(body)
        .expect(201);
};

// The students this suite provisions for. Each scenario has its own so the
// per-student admission limit (six POSTs a minute) and the one-repository-
// per-owner-per-template rule never couple scenarios. Sample data already
// has abc123 (user 1, team bright-fog) and bde456 (user 2, team
// hazy-mountain); the rest are inserted here. GitHub logins equal netids;
// the fake's account ids are 100 + the user id.
const students = {
    happy: { netid: 'abc123', id: 1, team: 'bright-fog' },
    interrupted: { netid: 'bde456', id: 2, team: 'hazy-mountain' },
    pending: { netid: 'pr3', id: 13 },
    collision: { netid: 'pr4', id: 14 },
    limited: { netid: 'pr5', id: 15 },
    concurrent: { netid: 'pr6', id: 16 },
    invited: { netid: 'pr7', id: 17 },
    hangup: { netid: 'pr8', id: 18 },
    untied: { netid: 'pr9', id: 19 },
    // The page scenario's student is on a team so the team template shows.
    page: { netid: 'pr10', id: 20, team: 'hazy-mountain' },
    teammateA: { netid: 'pt1', id: 21, team: 'damp-pond' },
    teammateB: { netid: 'pt2', id: 22, team: 'damp-pond' },
};

const githubID = student => 100 + student.id;

const fakeUsers = () => Object.values(students).map(s => ({ id: githubID(s), login: s.netid }));

const activeMemberships = () => Object.fromEntries(Object.values(students).map(s => [s.netid, 'active']));

// The templates faculty configure, exactly as they would through
// PostgREST: one individual template tied to exam-1, one team template
// tied to project-update-1, one tied to no assignment, and one that has
// been deactivated. The slug is the first half of every repository name
// made from the template.
const templates = {
    exam: {
        slug: 'exam-1-starter',
        label: 'Exam 1 starter',
        description: 'Starter code for the first exam.',
        template_full_name: 'course-org/starter',
        is_team: false,
        assignment_slug: 'exam-1',
    },
    project: {
        slug: 'project-starter',
        label: 'Project starter',
        template_full_name: 'course-org/proj-starter',
        is_team: true,
        assignment_slug: 'project-update-1',
    },
    scratch: {
        slug: 'scratch',
        label: 'Scratch space',
        description: 'A repository for trying things out.',
        template_full_name: 'course-org/scratch-starter',
    },
    retired: {
        slug: 'retired',
        label: 'Retired starter',
        template_full_name: 'course-org/retired-starter',
        is_active: false,
    },
};

// What the happy-path student had already submitted to exam-1 before any
// click, so the suite can show the platform left it alone.
const priorSubmissionURL = 'https://github.com/abc123/handwritten';

// Resets the sample data and layers the suite's fixtures on it: the extra
// students, a GitHub login for every student, a submission the happy-path
// student made by hand, and the templates above. The logins and the
// submission are set with SQL as the superuser: sample data has no
// github-username field for api.import_github_logins to copy from, and
// that RPC is covered by tests/db and tests/rest. Templates are created
// the way faculty do it, with a POST through PostgREST.
const seed = async () => {
    resetdb();
    const inserts = Object.values(students)
        .filter(s => s.id > 5)
        .map(s => `(${s.id}, '${s.netid}', 'Student ${s.netid}', 'prov-${s.netid}', 'student', ${s.team ? `'${s.team}'` : 'NULL'})`)
        .join(',\n');
    runSQL(`
        INSERT INTO data."user" (id, netid, name, nickname, role, team_nickname) VALUES
        ${inserts};
        SELECT setval('data.user_id_seq', (SELECT max(id) FROM data."user"));
        UPDATE data."user" SET github_login = netid WHERE role = 'student';
        INSERT INTO data.assignment_submission (assignment_slug, is_team, user_id, submitter_user_id)
        VALUES ('exam-1', false, ${students.happy.id}, ${students.happy.id});
        INSERT INTO data.assignment_field_submission (assignment_submission_id, assignment_field_slug, assignment_slug, body, submitter_user_id, origin)
        SELECT id, 'url', 'exam-1', '${priorSubmissionURL}', ${students.happy.id}, 'student'
        FROM data.assignment_submission
        WHERE assignment_slug = 'exam-1' AND user_id = ${students.happy.id};
    `);
    for (const template of Object.values(templates)) {
        // eslint-disable-next-line no-await-in-loop
        await postAsFaculty('/repository_templates', template);
    }
};

// The fake's baseline for a scenario: every student's account exists and is
// an active organization member, every template has contents, and nothing
// else. Scenarios layer their own scripting on top.
const templateRepos = () => Object.values(templates)
    .map(t => ({ full_name: t.template_full_name, ready: true }));

const baselineFake = async (overrides = {}) => {
    await scriptFake({
        reset: true,
        users: fakeUsers(),
        memberships: activeMemberships(),
        repos: templateRepos(),
        ...overrides,
    });
};

module.exports = {
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
};
