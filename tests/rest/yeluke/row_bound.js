/* global describe it before after beforeEach */

// End-to-end coverage for the statement row bound on student and TA writes
// (issue #346).
//
// This file replaces the coverage that used to live in max_affected.js. That
// tested `Prefer: handling=strict, max-affected=1`, the header mcpapp put on
// every PATCH and DELETE through the escape hatch (issue #337). The header was
// removed with this change, because it bound only the client that chose to
// send it and because it was verb-shaped: PostgREST turns a POST carrying
// `resolution=merge-duplicates` into INSERT ... ON CONFLICT DO UPDATE, which
// is a multi-row update wearing a POST, and that is the shape the Elm client
// and every batch write actually take.
//
// The same reason for testing it here still holds. The database tests prove
// the triggers behave against psql; only these prove that a real request
// through Caddy and PostgREST, with a real student JWT, hits the bound and
// that nothing was written when it does. They send no Prefer bound of their
// own -- that is the point.
//
// Everything happens inside a disposable assignment so no shared sample data
// is mutated; the fixture is removed in `after`.

const {
    resetdb,
    runSQL,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const {
    getJWTForNetid,
    we,
} = require('./helpers.js');

// The bound, as the schema defines it: data.request_row_bound_default().
const ROW_BOUND = 64;

// The stricter bound on the parent table, from the trigger argument on
// data.assignment_submission.
const SUBMISSION_BOUND = 4;

const FIXTURE_SLUG = 'zz-row-bound-fixture';

// One field per row the tests need to write, and a few to spare.
const FIELD_COUNT = 130;

const fieldSlug = n => `f-${n}`;

// The payload the Elm client sends: one object per field, no
// assignment_submission_id -- a BEFORE row trigger fills that in.
const fieldRows = (from, to, body) => {
    const rows = [];
    for (let n = from; n <= to; n += 1) {
        rows.push({
            assignment_slug: FIXTURE_SLUG,
            assignment_field_slug: fieldSlug(n),
            body,
        });
    }
    return rows;
};

describe('database row bound on student and TA writes (issue #346)', () => {
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    let facultyJWT;
    let studentJWT;

    const asFaculty = req => req.set('Authorization', `Bearer ${facultyJWT}`);
    const asStudent = req => req.set('Authorization', `Bearer ${studentJWT}`);

    // The Elm client's request: a JSON array of one object per field, with
    // return=representation and resolution=merge-duplicates
    // (elmclient/src/elm/Assignments/Commands.elm sends those as two Prefer
    // headers; superagent cannot, and one header with both is equivalent).
    const upsert = rows => asStudent(restService()
        .post('/assignment_field_submissions'))
        .set('Prefer', 'return=representation, resolution=merge-duplicates')
        .send(rows);

    const readFieldSubmissions = async () => {
        const response = await asFaculty(restService()
            .get(`/assignment_field_submissions?assignment_slug=eq.${FIXTURE_SLUG}&order=assignment_field_slug`))
            .expect(200);
        return response.body;
    };

    before(async () => {
        resetdb();
        [facultyJWT, studentJWT] = await Promise.all([facultyJWTPromise, studentJWTPromise]);
        we.expect(facultyJWT, 'faculty JWT')
            .to.be.a('string');
        we.expect(studentJWT, 'student JWT')
            .to.be.a('string');

        // Built in SQL rather than over the API: the fixture needs more fields
        // than the bound itself allows a client to write, and creating it is
        // not what these tests are about.
        runSQL(`
            INSERT INTO data.assignment
                (slug, points_possible, is_draft, is_team, title, body, closed_at)
            VALUES ('${FIXTURE_SLUG}', 10, false, false, 'row bound fixture', '',
                    current_timestamp + '30 days'::interval);
            INSERT INTO data.assignment_field
                (slug, assignment_slug, label, help, placeholder)
            SELECT 'f-' || g, '${FIXTURE_SLUG}', 'label', 'help', 'placeholder'
            FROM generate_series(1, ${FIELD_COUNT}) g;
        `);
    });

    after(() => {
        runSQL(`
            DELETE FROM data.assignment_field_submission WHERE assignment_slug = '${FIXTURE_SLUG}';
            DELETE FROM data.assignment_submission WHERE assignment_slug = '${FIXTURE_SLUG}';
            DELETE FROM data.assignment_field WHERE assignment_slug = '${FIXTURE_SLUG}';
            DELETE FROM data.assignment WHERE slug = '${FIXTURE_SLUG}';
            DELETE FROM data.assignment_submission WHERE assignment_slug LIKE 'zz-parent-bound-%';
            DELETE FROM data.assignment WHERE slug LIKE 'zz-parent-bound-%';
        `);
    });

    // Every test starts with the student owning one empty submission.
    beforeEach(() => {
        runSQL(`
            DELETE FROM data.assignment_field_submission WHERE assignment_slug = '${FIXTURE_SLUG}';
            DELETE FROM data.assignment_submission WHERE assignment_slug = '${FIXTURE_SLUG}';
            INSERT INTO data.assignment_submission
                (assignment_slug, user_id, is_team, submitter_user_id)
            VALUES ('${FIXTURE_SLUG}', 1, false, 1);
        `);
    });

    it('writes a batch upsert of exactly the bound', async () => {
        const response = await upsert(fieldRows(1, ROW_BOUND, 'at the bound'))
            .expect(201);

        we.expect(response.body)
            .to.have.lengthOf(ROW_BOUND);
        we.expect(await readFieldSubmissions())
            .to.have.lengthOf(ROW_BOUND);
    });

    // The case the header could never have caught: a POST that is really a
    // multi-row write, sent by an ordinary student token with no Prefer bound.
    it('refuses a batch upsert one row past the bound and rolls it back', async () => {
        const response = await upsert(fieldRows(1, ROW_BOUND + 1, 'past the bound'))
            .expect(400);

        we.expect(response.body.message)
            .to.match(/may change at most 64 rows/);

        we.expect(await readFieldSubmissions(), 'nothing was written')
            .to.have.lengthOf(0);
    });

    // Both arms of INSERT ... ON CONFLICT DO UPDATE spend one budget. Checked
    // separately, 60 updated and 60 inserted would each pass and the effective
    // bound would be twice what it says.
    it('counts an upsert across both of its arms', async () => {
        await upsert(fieldRows(1, 60, 'first write'))
            .expect(201);

        const response = await upsert(fieldRows(1, 120, 'second write'))
            .expect(400);

        we.expect(response.body.message)
            .to.match(/may change at most 64 rows/);

        const rows = await readFieldSubmissions();
        we.expect(rows, 'the refused upsert added nothing')
            .to.have.lengthOf(60);
        we.expect(rows.every(r => r.body === 'first write'), 'and changed nothing')
            .to.equal(true);
    });

    // A PATCH with no Prefer header at all: the old control was a preference a
    // client could simply omit, and this is the request that omits it.
    it('refuses an unfiltered PATCH with no Prefer header and rolls it back', async () => {
        await upsert(fieldRows(1, ROW_BOUND, 'before the patch'))
            .expect(201);
        await upsert(fieldRows(ROW_BOUND + 1, ROW_BOUND + 1, 'before the patch'))
            .expect(201);

        const response = await asStudent(restService()
            .patch(`/assignment_field_submissions?assignment_slug=eq.${FIXTURE_SLUG}`))
            .send({
                body: 'swept',
            })
            .expect(400);

        we.expect(response.body.message)
            .to.match(/may change at most 64 rows/);

        const rows = await readFieldSubmissions();
        we.expect(rows)
            .to.have.lengthOf(ROW_BOUND + 1);
        we.expect(rows.every(r => r.body === 'before the patch'), 'nothing was swept')
            .to.equal(true);
    });

    // The Elm client's real save: five fields of one submission in one POST.
    it('still allows the Elm client multi-field save', async () => {
        const response = await upsert(fieldRows(1, 5, 'https://example.com/first'))
            .expect(201);
        we.expect(response.body)
            .to.have.lengthOf(5);

        // Saving again is the same request with every row conflicting, so it
        // is all ON CONFLICT DO UPDATE and PostgREST answers 200 rather than
        // 201. That arm is counted too; five rows is well inside the bound.
        const again = await upsert(fieldRows(1, 5, 'https://example.com/second'))
            .expect(200);
        we.expect(again.body)
            .to.have.lengthOf(5);
    });

    // One statement, one parent submission. This one spans the fixture and the
    // student's own team-selection submission from the sample data.
    it('refuses a statement spanning two assignment submissions', async () => {
        await upsert(fieldRows(1, 1, 'fixture body'))
            .expect(201);

        const response = await asStudent(restService()
            .patch(`/assignment_field_submissions?assignment_slug=in.(${FIXTURE_SLUG},team-selection)`))
            .send({
                body: 'spanning',
            })
            .expect(400);

        we.expect(response.body.message)
            .to.match(/different assignment submissions/);

        const rows = await readFieldSubmissions();
        we.expect(rows.map(r => r.body))
            .to.deep.equal(['fixture body']);
    });

    it('bounds how many assignment submissions one request creates', async () => {
        runSQL(`
            INSERT INTO data.assignment
                (slug, points_possible, is_draft, is_team, title, body, closed_at)
            SELECT 'zz-parent-bound-' || g, 10, false, false, 'parent bound ' || g, '',
                   current_timestamp + '30 days'::interval
            FROM generate_series(1, ${SUBMISSION_BOUND + 1}) g;
        `);

        const submissionRows = count => {
            const rows = [];
            for (let n = 1; n <= count; n += 1) {
                rows.push({
                    assignment_slug: `zz-parent-bound-${n}`,
                });
            }
            return rows;
        };

        const refused = await asStudent(restService()
            .post('/assignment_submissions'))
            .set('Prefer', 'return=representation')
            .send(submissionRows(SUBMISSION_BOUND + 1))
            .expect(400);

        we.expect(refused.body.message)
            .to.match(/may change at most 4 rows/);

        const allowed = await asStudent(restService()
            .post('/assignment_submissions'))
            .set('Prefer', 'return=representation')
            .send(submissionRows(SUBMISSION_BOUND))
            .expect(201);

        we.expect(allowed.body)
            .to.have.lengthOf(SUBMISSION_BOUND);
    });

    // Faculty are exempt: the import and course-loading tooling writes in bulk
    // through this same path and must keep working.
    it('leaves faculty unbounded', async () => {
        await upsert(fieldRows(1, ROW_BOUND, 'student write'))
            .expect(201);
        await upsert(fieldRows(ROW_BOUND + 1, ROW_BOUND + 20, 'student write'))
            .expect(201);

        const response = await asFaculty(restService()
            .patch(`/assignment_field_submissions?assignment_slug=eq.${FIXTURE_SLUG}`))
            .set('Prefer', 'return=representation')
            .send({
                body: 'faculty sweep',
            })
            .expect(200);

        we.expect(response.body)
            .to.have.lengthOf(ROW_BOUND + 20);
    });
});
