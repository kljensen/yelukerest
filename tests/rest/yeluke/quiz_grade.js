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
} = require('./helpers.js');

describe('quiz_grades API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async () => {
        resetdb();
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/quiz_grades')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    const listTestCases = [{
        title: 'should allow students to see only their own quiz_grades',
        expected: [1],
        length: 1,
        status: 200,
        jwt: studentJWTPromise,
    }, {
        title: 'should allow faculty to see all quiz_grades',
        expected: [1, 2],
        length: 2,
        status: 200,
        jwt: facultyJWTPromise,
    }];

    makeListTestCases(it, '/quiz_grades', (x => x.user_id), listTestCases);
});
