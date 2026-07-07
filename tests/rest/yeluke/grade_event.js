/* global describe it before */

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
    we,
} = require('./helpers.js');

describe('grade history API endpoints', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before(async () => {
        resetdb();
    });

    [
        '/assignment_grade_events',
        '/quiz_grade_events',
        '/grade_events',
    ].forEach((path) => {
        it(`should not expose ${path} to students`, async () => {
            const jwt = await studentJWTPromise;
            const response = await restService()
                .get(path)
                .set('Authorization', `Bearer ${jwt}`);

            we.expect([401, 403]).to.include(response.status);
        });
    });

    makeListTestCases(it, '/assignment_grade_events', (x => x.event_type), [{
        title: 'should allow faculty to see assignment grade history',
        expected: ['recorded', 'recorded', 'recorded', 'recorded'],
        length: 4,
        status: 200,
        jwt: facultyJWTPromise,
    }]);

    makeListTestCases(it, '/quiz_grade_events', (x => x.event_type), [{
        title: 'should allow faculty to see quiz grade history',
        expected: ['recorded', 'recorded'],
        length: 2,
        status: 200,
        jwt: facultyJWTPromise,
    }]);

    makeListTestCases(it, '/grade_events', (x => x.event_type), [{
        title: 'should allow faculty to see grade snapshot history',
        expected: ['recorded', 'recorded', 'recorded', 'recorded'],
        length: 4,
        status: 200,
        jwt: facultyJWTPromise,
    }]);
});
