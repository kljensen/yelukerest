// A deterministic stand-in for the GitHub REST API, for integration runs of
// self-serve assignment repositories (issue #398). Bun, no dependencies.
//
//   bun tests/fake-github/server.js          # listens on FAKE_GITHUB_PORT, default 4099
//
// It implements exactly the endpoints authapp/github.go calls and nothing
// else; an unknown path is a 404 like GitHub's own. Every response shape is
// the subset of GitHub's that the client decodes. Two admin endpoints make
// it scriptable from a test:
//
//   POST /__fake/state   merge scripted state (below); {"reset": true} first
//                        empties everything, calls included. 400 when a
//                        scripted repository id was already handed out.
//   GET  /__fake/calls   the call log, oldest first:
//                        [{method, path, status, body, startedAt, finishedAt}]
//                        status is 0 while the call is in flight and -1 for a
//                        dropped connection; body is the parsed JSON request
//                        body (never a header); times are Unix milliseconds
//
// State, all keys optional:
//
//   users:        [{id, login}]                     accounts GET /users/{login} knows
//   memberships:  {login: "active"|"pending"|"none"}  organization membership state
//   repos:        [{full_name, id?, template_full_name?, created_at?, ready?}]
//                 existing repositories; ready=true means the default branch
//                 has a commit now (a template must be ready to be generated
//                 from), ready=false means HEAD answers 409 until
//                 headCallsUntilReady is spent
//   headCallsUntilReady:  N   a generated repository answers 409 to its first
//                             N GET .../commits/HEAD calls, then 200 (default 0)
//   collaboratorStatus:   201|204   what PUT .../collaborators answers (default 204)
//   nextGenerate:     {fail: "timeout"|"hangup"|"server_error"|"rate_limit",
//                      retryAfter?: seconds, landed?: bool}
//                     one-shot: the next generate fails this way. landed
//                     (default true for timeout/hangup) creates the repository
//                     anyway, which is the ambiguous case the retry has to
//                     reconcile. "hangup" is a 201 whose body is cut off (see
//                     the note where it is sent); "timeout" holds the reply
//                     past the client's deadline.
//   nextCollaborator: {fail: "server_error"|"rate_limit", retryAfter?: seconds}
//                     one-shot: the next collaborator PUT fails this way.
//   generateTimeoutMs: how long a "timeout" generate holds the response
//                      (default 16000, past the client's 15 s deadline)
//   generateDelayMs:   how long every successful generate takes (default 0),
//                      for overlapping two requests on purpose
//
// FAKE_GITHUB_TOKEN, when set, is the only bearer token accepted; anything
// else is 401. The token's value is never written to the log or a response.

const port = Number(process.env.FAKE_GITHUB_PORT || 4099);
// Loopback by default; bin/test-provisioning.sh passes 0.0.0.0 on Linux,
// where host.docker.internal reaches the host's bridge address instead.
const hostname = process.env.FAKE_GITHUB_BIND || '127.0.0.1';
const expectedToken = process.env.FAKE_GITHUB_TOKEN || '';

// Repository ids survive a reset: GitHub's are unique for all time, and the
// platform refuses to record one id for two owners, so a fake that handed
// out 1000 again after every reset would turn every scenario after the
// first into a repository_conflict. Scripted ids join the same set, so a
// scenario cannot reuse one either, by accident or on purpose.
let nextRepoID = 1000;
const usedRepoIDs = new Set();

const allocateRepoID = (requested) => {
    if (requested !== undefined) {
        if (usedRepoIDs.has(requested)) {
            throw new Error(`repository id ${requested} was already handed out`);
        }
        usedRepoIDs.add(requested);
        return requested;
    }
    while (usedRepoIDs.has(nextRepoID)) {
        nextRepoID += 1;
    }
    usedRepoIDs.add(nextRepoID);
    return nextRepoID++;
};

const initialState = () => ({
    users: new Map(),
    memberships: new Map(),
    repos: new Map(),
    headCallsUntilReady: 0,
    collaboratorStatus: 204,
    nextGenerate: null,
    nextCollaborator: null,
    generateTimeoutMs: 16000,
    generateDelayMs: 0,
    calls: [],
});

let state = initialState();

const json = (status, body, headers = {}) => new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...headers },
});

const notFound = () => json(404, { message: 'Not Found' });

const repoJSON = (repo) => {
    const out = {
        id: repo.id,
        full_name: repo.full_name,
        html_url: `https://github.com/${repo.full_name}`,
        default_branch: 'main',
        created_at: repo.created_at,
    };
    if (repo.template_full_name) {
        out.template_repository = { full_name: repo.template_full_name };
    }
    return out;
};

const addRepo = (spec) => {
    const repo = {
        id: allocateRepoID(spec.id),
        full_name: spec.full_name,
        template_full_name: spec.template_full_name || null,
        // GitHub reports created_at to the second.
        created_at: spec.created_at || new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
        headCallsUntilReady: spec.ready === false ? Infinity : (spec.headCallsUntilReady ?? 0),
        headCalls: 0,
    };
    state.repos.set(repo.full_name, repo);
    return repo;
};

const applyState = (patch) => {
    if (patch.reset) {
        state = initialState();
    }
    for (const user of patch.users || []) {
        state.users.set(user.login, { id: user.id, login: user.login });
    }
    for (const [login, membership] of Object.entries(patch.memberships || {})) {
        state.memberships.set(login, membership);
    }
    for (const repo of patch.repos || []) {
        addRepo(repo);
    }
    for (const key of ['headCallsUntilReady', 'collaboratorStatus', 'nextGenerate', 'nextCollaborator', 'generateTimeoutMs', 'generateDelayMs']) {
        if (key in patch) {
            state[key] = patch[key];
        }
    }
};

// A scripted failure, shared by generate and the collaborator PUT. Returns
// a Response, or the string "hangup" for the caller to close the socket.
const failureResponse = (failure) => {
    switch (failure.fail) {
    case 'server_error':
        return json(500, { message: 'Server Error' });
    case 'rate_limit':
        return json(403, {
            message: 'You have exceeded a secondary rate limit. Please wait a few minutes before you try again.',
            documentation_url: 'https://docs.github.com/rest/overview/resources-in-the-rest-api#secondary-rate-limits',
        }, { 'Retry-After': String(failure.retryAfter ?? 2) });
    case 'hangup':
        return 'hangup';
    case 'timeout':
        return new Promise((resolve) => {
            setTimeout(() => resolve(json(201, { message: 'too late' })), state.generateTimeoutMs);
        });
    default:
        return json(500, { message: `unknown scripted failure ${failure.fail}` });
    }
};

const sleep = ms => new Promise((resolve) => { setTimeout(resolve, ms); });

const route = async (req, url, entry) => {
    const parts = url.pathname.split('/').filter(Boolean);
    const { method } = req;
    if (method === 'POST' || method === 'PUT') {
        entry.body = await req.json().catch(() => null);
    }

    // GET /users/{login}
    if (method === 'GET' && parts.length === 2 && parts[0] === 'users') {
        const user = state.users.get(parts[1]);
        return user ? json(200, user) : notFound();
    }
    // GET|PUT /orgs/{org}/memberships/{login}
    if (parts.length === 4 && parts[0] === 'orgs' && parts[2] === 'memberships') {
        const login = parts[3];
        if (method === 'GET') {
            const membership = state.memberships.get(login);
            if (!membership || membership === 'none') {
                return notFound();
            }
            return json(200, { state: membership, role: 'member' });
        }
        if (method === 'PUT') {
            const current = state.memberships.get(login);
            const next = current === 'active' ? 'active' : 'pending';
            state.memberships.set(login, next);
            return json(200, { state: next, role: 'member' });
        }
    }
    // PUT /orgs/{org}/teams/{slug}/memberships/{login}
    if (method === 'PUT' && parts.length === 6 && parts[0] === 'orgs' && parts[2] === 'teams' && parts[4] === 'memberships') {
        return json(200, { state: 'active', role: 'member' });
    }
    // POST /repos/{owner}/{repo}/generate
    if (method === 'POST' && parts.length === 4 && parts[0] === 'repos' && parts[3] === 'generate') {
        const templateName = `${parts[1]}/${parts[2]}`;
        const template = state.repos.get(templateName);
        if (!template) {
            return notFound();
        }
        const body = entry.body || {};
        const fullName = `${body.owner}/${body.name}`;
        if (state.repos.has(fullName)) {
            return json(422, { message: 'Repository creation failed.', errors: [{ message: 'name already exists on this account' }] });
        }
        const failure = state.nextGenerate;
        if (failure) {
            state.nextGenerate = null;
            const landed = failure.landed ?? (failure.fail === 'timeout' || failure.fail === 'hangup');
            if (landed) {
                addRepo({ full_name: fullName, template_full_name: templateName, headCallsUntilReady: state.headCallsUntilReady });
            }
            return failureResponse(failure);
        }
        if (state.generateDelayMs > 0) {
            await sleep(state.generateDelayMs);
        }
        const repo = addRepo({ full_name: fullName, template_full_name: templateName, headCallsUntilReady: state.headCallsUntilReady });
        return json(201, repoJSON(repo));
    }
    // GET /repos/{owner}/{repo}
    if (method === 'GET' && parts.length === 3 && parts[0] === 'repos') {
        const repo = state.repos.get(`${parts[1]}/${parts[2]}`);
        return repo ? json(200, repoJSON(repo)) : notFound();
    }
    // GET /repos/{owner}/{repo}/commits/HEAD
    if (method === 'GET' && parts.length === 5 && parts[0] === 'repos' && parts[3] === 'commits' && parts[4] === 'HEAD') {
        const repo = state.repos.get(`${parts[1]}/${parts[2]}`);
        if (!repo) {
            return notFound();
        }
        repo.headCalls += 1;
        if (repo.headCalls <= repo.headCallsUntilReady) {
            return json(409, { message: 'Git Repository is empty.' });
        }
        return json(200, { sha: '0123abcd0123abcd0123abcd0123abcd0123abcd' });
    }
    // PUT /repos/{owner}/{repo}/collaborators/{login}
    if (method === 'PUT' && parts.length === 5 && parts[0] === 'repos' && parts[3] === 'collaborators') {
        const repo = state.repos.get(`${parts[1]}/${parts[2]}`);
        if (!repo) {
            return notFound();
        }
        const failure = state.nextCollaborator;
        if (failure) {
            state.nextCollaborator = null;
            return failureResponse(failure);
        }
        if (state.collaboratorStatus === 201) {
            return json(201, { id: 1, invitee: { login: parts[4] } });
        }
        return new Response(null, { status: 204 });
    }
    return notFound();
};

const server = Bun.serve({
    port,
    hostname,
    async fetch(req) {
        const url = new URL(req.url);
        if (url.pathname === '/__fake/state' && req.method === 'POST') {
            try {
                applyState(await req.json());
            } catch (error) {
                return json(400, { message: error.message });
            }
            return new Response(null, { status: 204 });
        }
        if (url.pathname === '/__fake/calls' && req.method === 'GET') {
            return json(200, state.calls);
        }
        if (url.pathname === '/__fake/health') {
            return json(200, { ok: true });
        }

        const entry = {
            method: req.method, path: url.pathname, status: 0, body: null, startedAt: Date.now(), finishedAt: null,
        };
        state.calls.push(entry);
        if (expectedToken && req.headers.get('authorization') !== `Bearer ${expectedToken}`) {
            entry.status = 401;
            entry.finishedAt = Date.now();
            return json(401, { message: 'Bad credentials' });
        }
        const result = await route(req, url, entry);
        entry.finishedAt = Date.now();
        if (result === 'hangup') {
            entry.status = -1;
            // Bun.serve has no socket to sever, and it turns an errored or
            // unfinished stream into a cleanly ended chunked reply, so the
            // nearest thing to a dropped connection it can produce is a
            // 201 whose body stops after a few bytes. The Go client cannot
            // decode that and reports a server error, which for the caller
            // is the same ambiguous "did it land?" as a real hangup: the
            // repository exists and nothing came back that says so.
            return new Response(new ReadableStream({
                start(controller) {
                    controller.enqueue(new TextEncoder().encode('{"id":'));
                    controller.close();
                },
            }), { status: 201, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
        }
        entry.status = result.status;
        return result;
    },
});

console.log(`fake GitHub listening on http://${hostname}:${server.port}`);
