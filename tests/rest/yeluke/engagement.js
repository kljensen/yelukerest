/* global describe it before */

const common = require('../common.js');

const restService = common.rest_service;


describe('engagements', () => {
    before((done) => {
        common.resetdb();
        done();
    });

    it('should not be visible to anonymous visitors', (done) => {
        restService()
            .get('/engagements')
            .expect('Content-Type', /json/)
            .expect(401, done);
    });

    it('should not be query-able to anonymous visitors', (done) => {
        restService()
            .get('/engagements?id=eq.1')
            .expect('Content-Type', /json/)
            // Notice how PostgREST has 400's in some cases where it seems
            // like it should have 401. This is annoying. There is some info
            // about similar problems https://github.com/begriffs/postgrest/issues?utf8=%E2%9C%93&q=400+401
            .expect(400, done);
    });


    const newEngagement = {
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

    it('should not accept other HTTP verbs', (done) => {
        restService()
            .post('/engagements')
            .send(newEngagement)
            .expect(400, done);
    });

    it('should not accept invalid POST requests', (done) => {
        restService()
            .post('/engagements')
            .send({})
            .expect(401, done);
    });
});
