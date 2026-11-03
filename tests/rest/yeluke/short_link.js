/* global describe it before after */

// Course short links through PostgREST (issue #408).
//
// tests/db/yeluke-short-link.sql proves the table, the grants and the
// resolver's response settings. This half sends real requests to /rest, so
// what it proves is what PostgREST makes of them: that the resolver's
// response.status and response.headers become a real 302 or 404, and that
// staff can upsert by slug the way a course admin script would. Redirects are
// never followed, so no request leaves the stack.

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

const FOLLOW = '/rpc/follow_short_link';

describe('short links API', () => {
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
    const taJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'jlb325');
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    let facultyJWT;
    let taJWT;
    let studentJWT;

    const upsert = (token, rows) => restService()
        .post('/short_links?on_conflict=slug')
        .set('Authorization', `Bearer ${token}`)
        .set('Prefer', 'resolution=merge-duplicates,return=representation')
        .send(rows);

    before(async () => {
        resetdb();
        [facultyJWT, taJWT, studentJWT] = await Promise.all([facultyJWTPromise, taJWTPromise, studentJWTPromise]);
    });

    after(() => {
        resetdb();
    });

    it('lets faculty create links and upsert them by slug', async () => {
        const created = await upsert(facultyJWT, [
            { slug: 'rnn', url: 'https://example.com/rnn-v1' },
            { slug: 'embeddings', url: 'https://example.com/embeddings' },
        ]).expect(201);
        we.expect(created.body.map(row => row.slug)).to.have.members(['rnn', 'embeddings']);

        const updated = await upsert(facultyJWT, [{ slug: 'rnn', url: 'https://example.com/rnn-v2' }])
            .expect(200);
        we.expect(updated.body).to.have.lengthOf(1);
        we.expect(updated.body[0]).to.include({ slug: 'rnn', url: 'https://example.com/rnn-v2' });

        const listed = await restService()
            .get('/short_links?select=slug,url&order=slug')
            .set('Authorization', `Bearer ${facultyJWT}`)
            .expect(200);
        we.expect(listed.body).to.deep.equal([
            { slug: 'embeddings', url: 'https://example.com/embeddings' },
            { slug: 'rnn', url: 'https://example.com/rnn-v2' },
        ]);
    });

    it('lets a TA upsert, change and delete links', async () => {
        const readAsTA = async () => (await restService()
            .get('/short_links?select=slug,url,created_by_user_id&order=slug')
            .set('Authorization', `Bearer ${taJWT}`)
            .expect(200)).body;

        await upsert(taJWT, [{ slug: 'ta-link', url: 'https://example.com/ta' }]).expect(201);
        await upsert(taJWT, [{ slug: 'ta-link', url: 'https://example.com/ta-v2' }]).expect(200);
        // embeddings was created by faculty (user 3) in the test above.
        await restService()
            .patch('/short_links?slug=eq.embeddings')
            .set('Authorization', `Bearer ${taJWT}`)
            .send({ url: 'https://example.com/embeddings-v2' })
            .expect(204);
        we.expect(await readAsTA()).to.deep.equal([
            { slug: 'embeddings', url: 'https://example.com/embeddings-v2', created_by_user_id: 3 },
            { slug: 'rnn', url: 'https://example.com/rnn-v2', created_by_user_id: 3 },
            { slug: 'ta-link', url: 'https://example.com/ta-v2', created_by_user_id: 4 },
        ]);

        await restService()
            .delete('/short_links?slug=eq.ta-link')
            .set('Authorization', `Bearer ${taJWT}`)
            .expect(204);
        we.expect((await readAsTA()).map(row => row.slug)).to.deep.equal(['embeddings', 'rnn']);
    });

    it('refuses an audit column in a staff write', async () => {
        await restService()
            .post('/short_links')
            .set('Authorization', `Bearer ${facultyJWT}`)
            .send({ slug: 'forged', url: 'https://example.com', created_by_user_id: 4 })
            .expect(403);
    });

    it('refuses a reserved or malformed slug and a non-https URL', async () => {
        for (const row of [
            { slug: 'rest', url: 'https://example.com' },
            { slug: 'Bad_Slug', url: 'https://example.com' },
            { slug: 'plain-http', url: 'http://example.com' },
        ]) {
            await upsert(facultyJWT, [row]).expect(400);
        }
    });

    it('refuses a student and an anonymous caller', async () => {
        await restService()
            .get('/short_links')
            .set('Authorization', `Bearer ${studentJWT}`)
            .expect(403);
        await upsert(studentJWT, [{ slug: 'student-link', url: 'https://example.com' }]).expect(403);
        await restService().get('/short_links').expect(401);
        await restService()
            .post('/short_links')
            .send({ slug: 'anon-link', url: 'https://example.com' })
            .expect(401);
    });

    it('answers a hit with a 302 to the destination', async () => {
        const response = await restService()
            .get(`${FOLLOW}?slug=rnn`)
            .set('Accept', 'application/json')
            .redirects(0)
            .expect(302);
        we.expect(response.headers.location).to.equal('https://example.com/rnn-v2');
        we.expect(response.headers['cache-control']).to.equal('no-store');
    });

    it('answers a miss with a 404 and no Location', async () => {
        const response = await restService()
            .get(`${FOLLOW}?slug=no-such-link`)
            .set('Accept', 'application/json')
            .redirects(0)
            .expect(404);
        we.expect(response.headers).to.not.have.property('location');
        we.expect(response.headers['cache-control']).to.equal('no-store');
    });

    it('is not callable with a signed-in credential; links are followed as anonymous', async () => {
        await restService()
            .get(`${FOLLOW}?slug=rnn`)
            .set('Accept', 'application/json')
            .set('Authorization', `Bearer ${facultyJWT}`)
            .redirects(0)
            .expect(403);
    });
});
