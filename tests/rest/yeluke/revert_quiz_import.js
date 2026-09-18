/* global describe it before */

// Reverting a quiz grade import over HTTP (issue #391).
//
// tests/db/yeluke-revert_quiz_import.sql proves the function and its
// boundary against the settings PostgREST would send. This half sends real
// requests through Caddy and PostgREST with JWTs issued by the login flow:
// faculty can undo an import and the student's grade goes away, a later
// change refuses the revert with a 409 unless forced, the reversal is listed
// with both links, and a TA gets 403.
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
const REVERT = '/rpc/revert_quiz_import';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

describe('reverting a quiz grade import over HTTP', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const taJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'jlb325');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    let facultyJWT;
    const asFaculty = req => req.set('Authorization', `Bearer ${facultyJWT}`);

    let importId;
    let reversalId;

    before(async () => {
        resetdb();
        facultyJWT = await facultyJWTPromise;
        const response = await postRequestWithJWT(IMPORT, {
            p_results: [{ meeting_slug: 'structuredquerylang', netid: 'abc123', points: 9 }],
            p_mark_attended: true,
            p_import_id: 'q2',
            p_reason: 'Quiz 2',
        }, await taJWTPromise).expect(200);
        importId = response.body.import_id;
    });

    it('refuses anonymous, student and TA callers', async () => {
        await postRequestWithJWT(REVERT, { p_import_id: importId, p_reason: 'Undo' }, undefined)
            .expect(401);
        await postRequestWithJWT(REVERT, { p_import_id: importId, p_reason: 'Undo' }, await studentJWTPromise)
            .expect(403);
        await postRequestWithJWT(REVERT, { p_import_id: importId, p_reason: 'Undo' }, await taJWTPromise)
            .expect(403);
        await postRequestWithJWT(REVERT, { p_import_id: importId, p_reason: 'Undo', p_force: true }, await taJWTPromise)
            .expect(403);
    });

    it('refuses a blank reason and a dry-run header', async () => {
        const blank = await postRequestWithJWT(REVERT, { p_import_id: importId, p_reason: ' ' }, facultyJWT)
            .expect(400);
        we.expect(JSON.stringify(blank.body)).to.contain('non-blank p_reason');

        const dryRun = await postRequestWithJWT(IMPORT, {
            p_results: [{ meeting_slug: 'structuredquerylang', netid: 'abc123', points: 1 }],
            p_dry_run: true,
        }, facultyJWT).expect(200);
        const refused = await postRequestWithJWT(REVERT, { p_import_id: dryRun.body.import_id, p_reason: 'Undo' }, facultyJWT)
            .expect(400);
        we.expect(JSON.stringify(refused.body)).to.contain('was a dry run and wrote nothing');
    });

    it('refuses to revert a grade changed since, naming it, until forced', async () => {
        await asFaculty(restService().patch('/quiz_grades?quiz_id=eq.2&user_id=eq.1'))
            .send({ points: 10 })
            .expect(204);

        const refused = await postRequestWithJWT(REVERT, { p_import_id: importId, p_reason: 'Undo' }, facultyJWT)
            .expect(409);
        we.expect(JSON.stringify(refused.body)).to.contain('structuredquerylang/abc123');
        we.expect(JSON.stringify(refused.body)).to.contain('p_force');

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(1);
        we.expect(grades.body[0]).to.include({ points: 10 });

        const listing = await asFaculty(restService().get('/quiz_grade_imports?reverts_import_id=not.is.null'))
            .expect(200);
        we.expect(listing.body).to.have.lengthOf(0);
    });

    it('lets faculty force the revert, and the grade is gone', async () => {
        const response = await postRequestWithJWT(REVERT, {
            p_import_id: importId,
            p_reason: 'Wrong answer key',
            p_force: true,
        }, await facultyJWTPromise).expect(200);
        we.expect(response.body).to.include({
            inserted_count: 0,
            updated_count: 0,
            deleted_count: 1,
            unchanged_count: 0,
            attendance_restored: 1,
            attendance_skipped: 0,
            reverts_import_id: importId,
        });
        we.expect(response.body.import_id).to.match(UUID);
        we.expect(response.body.import_id).to.not.equal(importId);
        reversalId = response.body.import_id;

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(0);

        const engagement = await asFaculty(restService().get('/engagements?user_id=eq.1&meeting_slug=eq.structuredquerylang'))
            .expect(200);
        we.expect(engagement.body[0]).to.include({ participation: 'absent' });
    });

    it('lists the reversal and the import with both links, and audits the events', async () => {
        const listing = await asFaculty(restService().get('/quiz_grade_imports?label=eq.q2&order=created_at.asc'))
            .expect(200);
        we.expect(listing.body).to.have.lengthOf(2);
        we.expect(listing.body[0]).to.include({
            id: importId,
            actor_role: 'ta',
            reverts_import_id: null,
            reverted_by_import_id: reversalId,
            inserted_count: 1,
            deleted_count: 0,
        });
        we.expect(listing.body[1]).to.include({
            id: reversalId,
            actor_role: 'faculty',
            reason: 'Wrong answer key',
            dry_run: false,
            reverts_import_id: importId,
            reverted_by_import_id: null,
            inserted_count: 0,
            updated_count: 0,
            deleted_count: 1,
            attendance_inserted: 0,
            attendance_updated: 1,
            attendance_deleted: 0,
        });

        const events = await restService()
            .get(`/quiz_grade_events?import_id=eq.${reversalId}`)
            .set('Authorization', `Bearer ${facultyJWT}`)
            .expect(200);
        we.expect(events.body).to.have.lengthOf(1);
        we.expect(events.body[0]).to.include({
            event_type: 'voided',
            operation: 'delete',
            quiz_id: 2,
            user_id: 1,
            points: 10,
            source: 'api.revert_quiz_import',
            reason: 'Wrong answer key',
            created_by_user_id: 3,
        });

        await restService()
            .get('/quiz_grade_imports')
            .set('Authorization', `Bearer ${await taJWTPromise}`)
            .expect(403);
    });

    it('reverts the reversal, restoring the state it found', async () => {
        const response = await postRequestWithJWT(REVERT, {
            p_import_id: reversalId,
            p_reason: 'The key was right',
        }, await facultyJWTPromise).expect(200);
        we.expect(response.body).to.include({
            inserted_count: 1,
            deleted_count: 0,
            attendance_restored: 1,
            reverts_import_id: reversalId,
        });

        const grades = await restService()
            .get('/quiz_grades?quiz_id=eq.2')
            .set('Authorization', `Bearer ${await studentJWTPromise}`)
            .expect(200);
        we.expect(grades.body).to.have.lengthOf(1);
        we.expect(grades.body[0]).to.include({ quiz_id: 2, user_id: 1, points: 10 });
    });
});
