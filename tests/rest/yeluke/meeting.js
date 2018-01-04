/* global describe it before */

const {
    getJWTForNetid,
    makePostTestCases,
} = require('./helpers.js');

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');


describe('meetings API endpoint', () => {
    let student1JWT;
    let facultyJWT;

    before(async() => {
        resetdb();
        try {
            student1JWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
            facultyJWT = await getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');
        } catch (error) {
            // eslint-disable-next-line no-console
            console.error('Could not get JWTs for users');
            process.exit(1);
        }
    });

    it('should be selectable', async() => {
        return restService()
            .get('/meetings?select=id')
            .expect('Content-Type', /json/)
            .expect(200)
            .expect((r) => {
                r.body.length.should.equal(3);
                r.body[0].id.should.equal(1);
            });
    });

    it('should be selectable by primary key', async() => {
        return restService()
            .get('/meetings/1')
            .expect(200)
            .expect((r) => {
                r.body.id.should.equal(1);
                r.body.slug.should.equal('intro');
            });
    });

    const newMeeting = {
        id: 100,
        slug: 'intro',
        summary: 'summary_2_2_2',
        description: 'description_1_',
        begins_at: '2017-12-27T14:54:50+00:00',
        duration: '00:00:03',
        is_draft: false,
        created_at: '2017-12-27T14:54:50+00:00',
        updated_at: '2017-12-27T22:09:47.089125+00:00',
    };


    const insertTestCases = [{
        title: 'should NOT allow posts/inserts from anonymous users',
        status: 403,
    }, {
        title: 'should allow posts/inserts from faculty',
        status: 201,
        jwt: facultyJWT,
    }, {
        title: 'should NOT allow posts/inserts from students',
        status: 403,
        jwt: student1JWT,
    }, {
        title: 'should should enforce primary key uniqueness constraints',
        status: 403,
        jwt: facultyJWT,
    }];
    makePostTestCases(it, '/engagements', newMeeting, insertTestCases);
});
