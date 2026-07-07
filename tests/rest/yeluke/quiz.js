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
    we,
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

    it('should serve current-user quiz submissions from the base endpoint', async () => {
        const jwt = await studentJWTPromise;
        const response = await restService()
            .get('/quiz_submissions?user_id=eq.1&order=quiz_id')
            .set('Authorization', `Bearer ${jwt}`)
            .expect('Content-Type', /json/)
            .expect(200);

        we.expect(response.body)
            .to.have.lengthOf(1);
        we.expect(response.body[0])
            .to.include({
                quiz_id: 1,
                user_id: 1,
            });
        we.expect(response.body[0])
            .to.have.property('created_at')
            .that.is.a('string');
        we.expect(response.body[0])
            .to.have.property('updated_at')
            .that.is.a('string');
        we.expect(response.body[0])
            .not.to.have.property('closed_at');
        we.expect(response.body[0])
            .not.to.have.property('is_open');
    });

    it('should not expose the removed quiz submissions compatibility endpoint', async () => {
        const jwt = await studentJWTPromise;
        await restService()
            .get('/quiz_submissions_info')
            .set('Authorization', `Bearer ${jwt}`)
            .expect(404);
    });

    const newQuiz = {
        meeting_slug: 'server-side-apps',
        points_possible: 13,
        is_draft: false,
        duration: '00:10:00',
    };

    const insertTestCases = [{
        title: 'should not accept post requests from anonymous users',
        status: 401,
    }, {
        title: 'should allow posts/inserts from faculty',
        status: 201,
        jwt: facultyJWTPromise,
    }, {
        title: 'should not accept post requests from students',
        status: 403,
        jwt: studentJWTPromise,
    }, {
        title: 'should enforce meeting_slug uniqueness constraints',
        status: 409,
        jwt: facultyJWTPromise,
    }];
    makeInsertTestCases(it, '/quizzes', newQuiz, insertTestCases);
});
