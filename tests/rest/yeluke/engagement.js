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
    makeInsertTestCases,
} = require('./helpers.js');

describe('engagements API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
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

    const insertTestCases = [{
        title: 'should not accept post requests from anonymous users',
        status: 403,
    }, {
        title: 'should allow posts/inserts from faculty',
        status: 201,
        jwt: facultyJWTPromise,
    }, {
        title: 'should not accept post requests from students',
        status: 403,
        jwt: studentJWTPromise,
    }, {
        title: 'should should enforce primary key uniqueness constraints',
        status: 403,
        jwt: facultyJWTPromise,
    }];
    makeInsertTestCases(it, '/engagements', newEngagement, insertTestCases);
});
