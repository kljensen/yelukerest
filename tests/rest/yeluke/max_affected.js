/* global describe it before after beforeEach */

// Real end-to-end coverage for the `max-affected` guard that mcpapp puts on
// every PATCH and DELETE it sends through the escape hatch (issue #337).
//
// mcpapp/escape_hatch_test.go only proves that mcpapp *builds* the header and
// *recognises* a PGRST124 body -- it feeds a fake PostgREST response back. If
// PostgREST stopped honouring the preference, or stopped rolling the
// transaction back, every one of those unit tests would still pass and one MCP
// call could rewrite a whole team's submissions. These tests talk to the real
// PostgREST and check the rows afterwards, which is the part that matters.
//
// Everything happens inside a disposable meeting so no shared sample data is
// mutated; the fixture is removed in `after`.

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const {
    getJWTForNetid,
    we,
} = require('./helpers.js');

// The exact preference string mcpapp sends. Keep this in sync with
// `escapeHatchBoundedPrefer` in mcpapp/escape_hatch.go.
const BOUNDED_PREFER = 'return=representation, handling=strict, max-affected=1';

// A meeting slug that exists only for this suite.
const FIXTURE_SLUG = 'zz-max-affected-fixture';

describe('PostgREST max-affected bound (issue #337)', () => {
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
    let facultyJWT;

    const authed = req => req.set('Authorization', `Bearer ${facultyJWT}`);

    const readFixtureRows = async () => {
        const response = await authed(restService()
            .get(`/engagements?meeting_slug=eq.${FIXTURE_SLUG}&order=user_id`))
            .expect(200);
        return response.body;
    };

    const deleteFixtureRows = () => authed(restService()
        .delete(`/engagements?meeting_slug=eq.${FIXTURE_SLUG}`));

    before(async () => {
        resetdb();
        facultyJWT = await facultyJWTPromise;
        we.expect(facultyJWT, 'faculty JWT')
            .to.be.a('string');

        await authed(restService()
            .post('/meetings'))
            .send({
                slug: FIXTURE_SLUG,
                title: 'max-affected fixture',
                description: 'Disposable meeting created by tests/rest/yeluke/max_affected.js',
                begins_at: '2030-01-01T10:00:00Z',
                duration: '80 minutes',
                is_draft: true,
            })
            .expect(201);
    });

    // Each test starts from exactly two rows, both 'absent'.
    beforeEach(async () => {
        await deleteFixtureRows()
            .expect(204);
        await authed(restService()
            .post('/engagements'))
            .send([{
                user_id: 1,
                meeting_slug: FIXTURE_SLUG,
                participation: 'absent',
            }, {
                user_id: 2,
                meeting_slug: FIXTURE_SLUG,
                participation: 'absent',
            }])
            .expect(201);
    });

    after(async () => {
        await deleteFixtureRows();
        await authed(restService()
            .delete(`/meetings?slug=eq.${FIXTURE_SLUG}`));
    });

    it('refuses a PATCH matching two rows and rolls it back', async () => {
        const before = await readFixtureRows();
        we.expect(before)
            .to.have.lengthOf(2);

        const response = await authed(restService()
            .patch(`/engagements?meeting_slug=eq.${FIXTURE_SLUG}`))
            .set('Prefer', BOUNDED_PREFER)
            .send({
                participation: 'led',
            })
            .expect(400);

        we.expect(response.body)
            .to.include({
                code: 'PGRST124',
            });
        we.expect(response.body.details)
            .to.match(/2 rows/);

        // The assertion that actually proves the guard: neither row moved.
        // A refusal that still wrote would be worse than no guard at all.
        const after = await readFixtureRows();
        we.expect(after.map(r => r.participation))
            .to.deep.equal(['absent', 'absent']);
        we.expect(after.map(r => r.updated_at))
            .to.deep.equal(before.map(r => r.updated_at));
    });

    it('allows a PATCH matching exactly one row', async () => {
        const response = await authed(restService()
            .patch(`/engagements?meeting_slug=eq.${FIXTURE_SLUG}&user_id=eq.1`))
            .set('Prefer', BOUNDED_PREFER)
            .send({
                participation: 'led',
            })
            .expect(200);

        we.expect(response.body)
            .to.have.lengthOf(1);
        we.expect(response.body[0])
            .to.include({
                user_id: 1,
                participation: 'led',
            });

        const after = await readFixtureRows();
        we.expect(after.map(r => r.participation))
            .to.deep.equal(['led', 'absent']);
    });

    it('refuses a DELETE matching two rows and rolls it back', async () => {
        const response = await authed(restService()
            .delete(`/engagements?meeting_slug=eq.${FIXTURE_SLUG}`))
            .set('Prefer', BOUNDED_PREFER)
            .expect(400);

        we.expect(response.body)
            .to.include({
                code: 'PGRST124',
            });
        we.expect(response.body.details)
            .to.match(/2 rows/);

        const after = await readFixtureRows();
        we.expect(after.map(r => r.user_id))
            .to.deep.equal([1, 2]);
    });

    it('allows a DELETE matching exactly one row', async () => {
        const response = await authed(restService()
            .delete(`/engagements?meeting_slug=eq.${FIXTURE_SLUG}&user_id=eq.2`))
            .set('Prefer', BOUNDED_PREFER)
            .expect(200);

        we.expect(response.body)
            .to.have.lengthOf(1);
        we.expect(response.body[0])
            .to.include({
                user_id: 2,
            });

        const after = await readFixtureRows();
        we.expect(after.map(r => r.user_id))
            .to.deep.equal([1]);
    });

    // Pins down why mcpapp sends handling=strict: without it PostgREST
    // silently ignores max-affected. If someone trims the Prefer header down
    // to just `max-affected=1` this test shows what that buys you -- nothing.
    it('silently ignores max-affected when handling=strict is absent', async () => {
        const response = await authed(restService()
            .patch(`/engagements?meeting_slug=eq.${FIXTURE_SLUG}`))
            .set('Prefer', 'return=representation, max-affected=1')
            .send({
                participation: 'led',
            })
            .expect(200);

        we.expect(response.body)
            .to.have.lengthOf(2);

        const after = await readFixtureRows();
        we.expect(after.map(r => r.participation))
            .to.deep.equal(['led', 'led']);
    });
});
