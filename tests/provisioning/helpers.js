// Helpers for the provisioning integration suite (issue #398): the fake
// GitHub's admin API, a logged-in student session, the two authapp routes,
// and the sample-data seed. bin/test-provisioning.sh starts the fake and
// restarts authapp pointed at it before `bun test` runs this directory.
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

// The two routes. A POST carries Sec-Fetch-Site the way a browser does;
// without it authapp refuses the request as cross-site.
const repositoryRoute = slug => `/auth/assignments/${slug}/repository`;

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

const getRepository = async (cookie, slug) => {
    const response = await request(baseURL)
        .get(repositoryRoute(slug))
        .set('Cookie', cookie)
        .set('Accept', 'application/json');
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
// faculty, for the event ledger students cannot read.
const studentJWT = netid => getJWTForNetid(baseURL, authPath, jwtPath, netid);
const facultyJWT = () => getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

const selectAs = async (jwt, path) => {
    const response = await restService()
        .get(path)
        .set('Authorization', `Bearer ${await jwt}`)
        .expect(200);
    return response.body;
};

const patchAsFaculty = async (path, body) => {
    const jwt = await facultyJWT();
    await restService()
        .patch(path)
        .set('Authorization', `Bearer ${jwt}`)
        .send(body)
        .expect(204);
};

// The students this suite provisions for. Each scenario has its own so the
// per-student admission limit (six POSTs a minute) and the one-repository-
// per-owner rule never couple scenarios. Sample data already has abc123
// (user 1, team bright-fog) and bde456 (user 2, team hazy-mountain); the
// rest are inserted here. GitHub logins equal netids; the fake's account
// ids are 100 + the user id.
const students = {
    happy: { netid: 'abc123', id: 1 },
    interrupted: { netid: 'bde456', id: 2 },
    pending: { netid: 'pr3', id: 13 },
    collision: { netid: 'pr4', id: 14 },
    limited: { netid: 'pr5', id: 15 },
    concurrent: { netid: 'pr6', id: 16 },
    invited: { netid: 'pr7', id: 17 },
    hangup: { netid: 'pr8', id: 18 },
    teammateA: { netid: 'pt1', id: 21, team: 'damp-pond' },
    teammateB: { netid: 'pt2', id: 22, team: 'damp-pond' },
};

const githubID = student => 100 + student.id;

const fakeUsers = () => Object.values(students).map(s => ({ id: githubID(s), login: s.netid }));

const activeMemberships = () => Object.fromEntries(Object.values(students).map(s => [s.netid, 'active']));

// Resets the sample data and layers the suite's fixtures on it: the extra
// students, a GitHub login for every student, and a template on exam-1
// (individual, URL field `url`) and project-update-1 (team, URL field
// `repo-url`). The logins are set with SQL as the superuser: sample data has
// no github-username field for api.import_github_logins to copy from, and
// that RPC is covered by tests/db and tests/rest. Templates are configured
// the way faculty do it, with a PATCH through PostgREST.
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
    `);
    await patchAsFaculty('/assignments?slug=eq.exam-1', {
        repository_template_provider: 'github',
        repository_template_full_name: 'course-org/starter',
        repository_url_field_slug: 'url',
    });
    await patchAsFaculty('/assignments?slug=eq.project-update-1', {
        repository_template_provider: 'github',
        repository_template_full_name: 'course-org/proj-starter',
        repository_url_field_slug: 'repo-url',
    });
};

// The fake's baseline for a scenario: every student's account exists and is
// an active organization member, both templates have contents, and nothing
// else. Scenarios layer their own scripting on top.
const baselineFake = async (overrides = {}) => {
    await scriptFake({
        reset: true,
        users: fakeUsers(),
        memberships: activeMemberships(),
        repos: [
            { full_name: 'course-org/starter', ready: true },
            { full_name: 'course-org/proj-starter', ready: true },
        ],
        ...overrides,
    });
};

module.exports = {
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
};
