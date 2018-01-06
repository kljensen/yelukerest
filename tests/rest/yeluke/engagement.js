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
    makeListTestCases,
    makeInsertTestCases,
} = require('./helpers.js');

describe('engagements API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async() => {
        resetdb();
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/engagements')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    const listTestCases = [{
        title: 'should allow students to see only their own engagements foo',
        expected: [1, 1, 1],
        length: 3,
        status: 200,
        jwt: studentJWTPromise,
    }, {
        title: 'should allow faculty to see all engagements foo',
        expected: [1, 2, 3, 1, 2, 3, 1, 2, 3],
        length: 9,
        status: 200,
        jwt: facultyJWTPromise,
    }];

    makeListTestCases(it, '/engagements', (x => x.user_id), listTestCases);

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
