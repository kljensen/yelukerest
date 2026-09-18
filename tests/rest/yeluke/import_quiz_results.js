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

    it('refuses a TA batch that grades the TA or a faculty member', async () => {
        const taJWT = await taJWTPromise;
        for (const netid of ['jlb325', 'klj39']) {
            const response = await postRequestWithJWT(IMPORT, {
                p_results: [{ meeting_slug: 'structuredquerylang', netid, points: 13 }],
                p_reason: 'Quiz 2',
            }, taJWT).expect(403);
            we.expect(JSON.stringify(response.body)).to.contain(`only record grades for students, not for: ${netid}`);
        }
        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await facultyJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(0);
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

    it('records a new grade for a TA, and the student sees it', async () => {
        const response = await postRequestWithJWT(IMPORT, batch(9, { p_reason: 'Quiz 2 from quiz.som.chat', p_import_id: 'ta-q2' }), await taJWTPromise)
            .expect(200);
        we.expect(response.body).to.include({
            inserted_count: 1,
            updated_count: 0,
            unchanged_count: 0,
            submission_created_count: 1,
            import_id: 'ta-q2',
            dry_run: false,
        });

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(1);
        we.expect(grades.body[0]).to.include({ quiz_id: 2, user_id: 1, points: 9 });
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

        // And the grade is still there.
        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(1);
        we.expect(grades.body[0]).to.include({ points: 10 });
    });
});
