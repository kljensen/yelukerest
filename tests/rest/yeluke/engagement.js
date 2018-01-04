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
    makePostTestCases,
    makeListTestCases,
} = require('./helpers.js');

describe('engagements API endpoint', async() => {
    let student1JWT = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    let facultyJWT = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async() => {
        resetdb();
        try {
            await Promise.all([student1JWT, facultyJWT]);
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
            .set('Authorization', `Bearer ${student1JWT}`)
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
    // async function makeListTestCases(theIt, path, setMaker, testCases) {


    const listTestCases = [{
        title: 'should allow students to see only their own engagements foo',
        set: [1],
        length: 1,
        status: 200,
        jwt: student1JWT,
    }, {
        title: 'should allow faculty to see all engagements foo',
        set: [1, 2, 3],
        length: 9,
        status: 200,
        jwt: facultyJWT,
    }];
    console.error(`facultyJWT = ${facultyJWT}`);

    makeListTestCases(it, '/engagements', x => x.user_id, listTestCases);

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
        jwt: facultyJWT,
    }, {
        title: 'should not accept post requests from students',
        status: 403,
        jwt: student1JWT,
    }, {
        title: 'should should enforce primary key uniqueness constraints',
        status: 403,
        jwt: facultyJWT,
    }];
    console.error(`facultyJWT = ${facultyJWT}`);
    makePostTestCases(it, '/engagements', newEngagement, insertTestCases);
});
