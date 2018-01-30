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

describe('assignment_grades API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async () => {
        resetdb();
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/assignment_grades')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    const listTestCases = [{
        title: 'should allow students to see only their own assignment_grades',
        expected: [1, 4],
        length: 2,
        status: 200,
        jwt: studentJWTPromise,
    }, {
        title: 'should allow faculty to see all assignment_grades',
        expected: [1, 2, 3, 4],
        length: 4,
        status: 200,
        jwt: facultyJWTPromise,
    }];

    makeListTestCases(it, '/assignment_grades', (x => x.assignment_submission_id), listTestCases);
});
