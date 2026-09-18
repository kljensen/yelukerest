/* global describe it before */

// The TA path into api.import_quiz_results over HTTP (issue #389).
//
// tests/db/yeluke-import_quiz_results.sql proves the function and the
// quiz_importer boundary against the settings PostgREST would send. This half
// sends real requests through Caddy and PostgREST with JWTs issued by the
// login flow, so what it proves is the boundary as a TA meets it: the one RPC
// answers, everything else about quiz grades still refuses, and the refusals
// arrive as the status codes a client will branch on.
//
// Sample data in play: jlb325 is the TA, klj39 the faculty member, abc123 a
// student with a grade on quiz 1 (intro) and none on quiz 2
// (structuredquerylang).

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const {
    getJWTForNetid,
    postRequestWithJWT,
    we,
} = require('./helpers.js');

const IMPORT = '/rpc/import_quiz_results';

describe('quiz result import as a TA over HTTP', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const taJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'jlb325');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    const batch = (points, extra = {}) => ({
        p_results: [{ meeting_slug: 'structuredquerylang', netid: 'abc123', points }],
        ...extra,
    });

    before(async () => {
        resetdb();
    });

    it('refuses anonymous and student callers', async () => {
        await postRequestWithJWT(IMPORT, batch(9, { p_reason: 'Quiz 2' }), undefined)
            .expect(401);
        await postRequestWithJWT(IMPORT, batch(9, { p_reason: 'Quiz 2' }), await studentJWTPromise)
            .expect(403);
    });

    it('refuses a TA import without a reason', async () => {
        const response = await postRequestWithJWT(IMPORT, batch(9), await taJWTPromise)
            .expect(400);
        we.expect(JSON.stringify(response.body)).to.contain('non-blank p_reason');
    });

    // Issue #392: TAs sit the quizzes too, so a TA batch may name the TA
    // themself and faculty. Observers never do; crt43 is one. The ledger
    // records the actor.
    it('refuses a TA batch that grades an observer', async () => {
        const response = await postRequestWithJWT(IMPORT, {
            p_results: [
                { meeting_slug: 'structuredquerylang', netid: 'jlb325', points: 13 },
                { meeting_slug: 'structuredquerylang', netid: 'crt43', points: 13 },
            ],
            p_reason: 'Quiz 2',
        }, await taJWTPromise).expect(403);
        we.expect(JSON.stringify(response.body)).to.contain('only record grades for students, TAs and faculty, not for: crt43');

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(0);
    });

    it('imports a TA batch that grades the TA and a faculty member', async () => {
        const response = await postRequestWithJWT(IMPORT, {
            p_results: [
                { meeting_slug: 'structuredquerylang', netid: 'jlb325', points: 13 },
                { meeting_slug: 'structuredquerylang', netid: 'klj39', points: 12 },
            ],
            p_reason: 'Quiz 2, staff pages',
            p_import_id: 'ta-q2-staff',
        }, await taJWTPromise).expect(200);
        we.expect(response.body).to.include({
            inserted_count: 2,
            updated_count: 0,
            unchanged_count: 0,
            submission_created_count: 2,
        });

        const ownGrades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await taJWTPromise}`)
            .expect(200);
        we.expect(ownGrades.body).to.have.lengthOf(1);
        we.expect(ownGrades.body[0]).to.include({ quiz_id: 2, user_id: 4, points: 13 });

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2&order=user_id')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(grades.body.map(g => [g.user_id, g.points])).to.deep.equal([[3, 12], [4, 13]]);

        const listing = await restService()
            .get('/quiz_grade_imports?label=eq.ta-q2-staff')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(listing.body).to.have.lengthOf(1);
        we.expect(listing.body[0]).to.include({ actor_user_id: 4, actor_role: 'ta', inserted_count: 2 });
    });

    it('refuses a second TA batch that would change the TA\'s own or the faculty grade', async () => {
        const response = await postRequestWithJWT(IMPORT, {
            p_results: [
                { meeting_slug: 'structuredquerylang', netid: 'jlb325', points: 12 },
                { meeting_slug: 'structuredquerylang', netid: 'klj39', points: 13 },
            ],
            p_reason: 'Quiz 2, staff corrections',
        }, await taJWTPromise).expect(403);
        we.expect(JSON.stringify(response.body)).to.contain('records grades once');
        we.expect(JSON.stringify(response.body)).to.contain('structuredquerylang/jlb325, structuredquerylang/klj39');

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2&order=user_id')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(grades.body.map(g => [g.user_id, g.points])).to.deep.equal([[3, 12], [4, 13]]);
    });

    it('tells a TA nothing about a draft quiz', async () => {
        // entrepreneurship-woot holds a draft quiz; server-side-apps holds none.
        const taJWT = await taJWTPromise;
        const replies = [];
        for (const meetingSlug of ['entrepreneurship-woot', 'server-side-apps']) {
            const response = await postRequestWithJWT(IMPORT, {
                p_results: [{ meeting_slug: meetingSlug, netid: 'abc123', points: 1 }],
                p_reason: 'Quiz',
            }, taJWT).expect(409); // 23503, as for any unknown quiz
            replies.push(JSON.stringify(response.body).replace(meetingSlug, 'MEETING'));
        }
        we.expect(replies[0]).to.equal(replies[1]);
        we.expect(replies[0]).to.contain('does not know a quiz');
        we.expect(replies[0]).to.not.contain('draft');
    });

    // The generated execution id the import returns (issue #390); the
    // p_import_id sent is kept on the ledger as a label.
    let executionId;
    const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

    it('records a new grade for a TA, and the student sees it', async () => {
        const response = await postRequestWithJWT(IMPORT, batch(9, { p_reason: 'Quiz 2 from quiz.som.chat', p_import_id: 'ta-q2' }), await taJWTPromise)
            .expect(200);
        we.expect(response.body).to.include({
            inserted_count: 1,
            updated_count: 0,
            unchanged_count: 0,
            submission_created_count: 1,
            dry_run: false,
        });
        we.expect(response.body.import_id).to.match(UUID);
        executionId = response.body.import_id;

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(1);
        we.expect(grades.body[0]).to.include({ quiz_id: 2, user_id: 1, points: 9 });
    });

    it('lists that import to faculty under its execution id, and not to the TA', async () => {
        const listing = await restService()
            .get('/quiz_grade_imports?label=eq.ta-q2')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(listing.body).to.have.lengthOf(1);
        we.expect(listing.body[0]).to.include({
            id: executionId,
            label: 'ta-q2',
            actor_role: 'ta',
            reason: 'Quiz 2 from quiz.som.chat',
            dry_run: false,
            inserted_count: 1,
            updated_count: 0,
            unchanged_count: 0,
            submission_created_count: 1,
        });

        const events = await restService()
            .get(`/quiz_grade_events?import_id=eq.${executionId}`)
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(events.body).to.have.lengthOf(1);
        we.expect(events.body[0]).to.include({ quiz_id: 2, user_id: 1, points: 9 });

        await restService()
            .get('/quiz_grade_imports')
            .set('Authorization', `Bearer ${await taJWTPromise}`)
            .expect(403);
    });

    it('refuses a TA batch that would change an existing grade', async () => {
        const response = await postRequestWithJWT(IMPORT, batch(10, { p_reason: 'Quiz 2 correction' }), await taJWTPromise)
            .expect(403);
        we.expect(JSON.stringify(response.body)).to.contain('records grades once');
        we.expect(JSON.stringify(response.body)).to.contain('structuredquerylang/abc123');

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body[0]).to.include({ points: 9 });
    });

    it('lets faculty change that grade, with no reason required', async () => {
        const response = await postRequestWithJWT(IMPORT, batch(10), await facultyJWTPromise)
            .expect(200);
        we.expect(response.body).to.include({ inserted_count: 0, updated_count: 1, unchanged_count: 0 });
    });

    it('still refuses the TA everywhere else quiz grades live', async () => {
        const taJWT = await taJWTPromise;
        const asTA = req => req.set('Authorization', `Bearer ${taJWT}`);

        await asTA(restService().post('/quiz_grades'))
            .send({ quiz_id: 2, user_id: 2, points: 13 })
            .expect(403);
        await asTA(restService().patch('/quiz_grades?quiz_id=eq.2&user_id=eq.1'))
            .send({ points: 13 })
            .expect(403);
        await asTA(restService().delete('/quiz_grades?quiz_id=eq.2&user_id=eq.1'))
            .expect(403);

        await asTA(restService().post('/quiz_submissions'))
            .send({ quiz_id: 2, user_id: 2 })
            .expect(403);
        await asTA(restService().patch('/quiz_submissions?quiz_id=eq.2&user_id=eq.1'))
            .send({ user_id: 2 })
            .expect(403);
        await asTA(restService().delete('/quiz_submissions?quiz_id=eq.2&user_id=eq.1'))
            .expect(403);

        await asTA(restService().get('/quiz_grade_events'))
            .expect(403);
        await asTA(restService().get('/quiz_grade_imports'))
            .expect(403);

        // And the grade is still there.
        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(1);
        we.expect(grades.body[0]).to.include({ points: 10 });
    });
});
