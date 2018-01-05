/* global describe it before  */

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
    postRequestWithJWT,
} = require('./helpers.js');

describe('engagements API endpoint', () => {
    let studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    let facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
    let studentJWT;
    let facultyJWT;

    before(async() => {
        resetdb();
        try {
            studentJWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
            facultyJWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('Could not get JWTs for users');
            process.exit(1);
        }
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/engagements')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    it('should not be query-able to anonymous visitors', (done) => {
        restService()
            .get('/engagements?user_id=eq.1')
            .expect('Content-Type', /json/)
            // Notice how PostgREST has 400's in some cases where it seems
            // like it should have 401. This is annoying. There is some info
            // about similar problems https://github.com/begriffs/postgrest/issues?utf8=%E2%9C%93&q=400+401
            .expect(401, done);
    });

    it('should allow logged-in students to see only their own engagements', async() => {
        const response = await restService()
            .get('/engagements')
            .set('Authorization', `Bearer ${studentJWT}`)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body)
            .to.be.a.instanceOf(Array);
        we.expect(response.body)
            .to.have.lengthOf(3);
        const userIds = new Set(response.body.map(x => x.user_id));
        we.expect(userIds.size)
            .to.equal(1);
        we.expect(userIds.has(1))
            .to.have.true(1);
    });

    it('should allow faculty to see all engagements', async() => {
        const response = await restService()
            .get('/engagements')
            .query({
                meeting_id: 'eq.2',
            })
            .set('Authorization', `Bearer ${facultyJWT}`)
            .expect('Content-Type', /json/)
            .expect(200);
        we.expect(response.body)
            .to.be.a.instanceOf(Array);
        we.expect(response.body)
            .to.have.lengthOf(3);
        const userIds = new Set(response.body.map(x => x.user_id));
        we.expect(userIds.size)
            .to.equal(3);
    });

    const newEngagement = {
        user_id: 5,
        meeting_id: 1,
        participation: 'led',
    };

    const tryToInsertNewEngagement = jwt => postRequestWithJWT('/engagements', newEngagement, jwt);

    it('should not accept post requests from anonymous users', (done) => {
        tryToInsertNewEngagement()
            .expect(401, done);
    });

    it('should not accept post requests from students', (done) => {
        tryToInsertNewEngagement(studentJWT)
            .expect(403, done);
    });

    it('should allow posts/inserts from faculty', async() => {
        const req = tryToInsertNewEngagement(facultyJWT)
            .expect(201);
        return req;
    });

    it('should should enforce primary key uniqueness constraints', async() => {
        const req = tryToInsertNewEngagement(facultyJWT)
            .expect(409);
        return req;
    });
});
