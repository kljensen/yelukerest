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

describe('quizzes API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async () => {
        resetdb();
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/quizzes')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    const meetingSlugs = [
        'intro',
        'structuredquerylang',
        'entrepreneurship-woot',
    ];
    const listTestCases = [{
        title: 'should allow students to see all quizzes',
        expected: meetingSlugs,
        length: 3,
        status: 200,
        jwt: studentJWTPromise,
    }, {
        title: 'should allow faculty to see all quizzes',
        expected: meetingSlugs,
        length: 3,
        status: 200,
        jwt: facultyJWTPromise,
    }];

    makeListTestCases(it, '/quizzes', (x => x.meeting_slug), listTestCases);

    const newQuiz = {
        meeting_slug: 'entrepreneurship-woot',
        points_possible: 13,
        is_draft: false,
        duration: '00:10:00',
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
    makeInsertTestCases(it, '/quizzes', newQuiz, insertTestCases);
});
