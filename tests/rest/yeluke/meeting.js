/* global describe it before */
const common = require('../common.js');


const {
    baseURL,
    authPath,
    jwtPath,
    restService,
} = common;

const {
    getJWTForNetid,
    we,
} = require('./helpers.js');

describe('meetings API endpoint', () => {
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');
    const facultyJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'klj39');

    before((done) => {
        common.resetdb();
        done();
    });

    it('should be selectable', (done) => {
        restService()
            .get('/meetings?select=slug')
            .expect('Content-Type', /json/)
            .expect(200, done)
            .expect((r) => {
                we.expect(r.body)
                    .to.have.lengthOf(4);
            });
    });

    const newMeeting = {
        slug: 'new-meeting',
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
            .post('/meetings')
            .send(newMeeting)
            .expect(401, done);
    });

    it('should not accept invalid POST requests', (done) => {
        restService()
            .post('/meetings')
            .send({})
            .expect(401, done);
    });

    it('should not let anonymous users sync meetings', (done) => {
        restService()
            .post('/rpc/sync_meetings')
            .send({ p_meetings: [] })
            .expect(401, done);
    });

    it('should not let students sync meetings', async () => {
        const jwt = await studentJWTPromise;
        await restService()
            .post('/rpc/sync_meetings')
            .set('Authorization', `Bearer ${jwt}`)
            .send({ p_meetings: [] })
            .expect(403);
    });

    it('should let faculty atomically sync meetings', async () => {
        const jwt = await facultyJWTPromise;
        const response = await restService()
            .post('/rpc/sync_meetings')
            .set('Authorization', `Bearer ${jwt}`)
            .send({
                p_meetings: [{
                    slug: 'intro',
                    title: 'Updated Introduction',
                    summary: 'updated',
                    description: 'updated description',
                    begins_at: '2018-01-01T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: false,
                }, {
                    slug: 'structuredquerylang',
                    title: 'Databases and Structured Query Language',
                    summary: 'summary',
                    description: 'description',
                    begins_at: '2018-01-02T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: true,
                }, {
                    slug: 'entrepreneurship-woot',
                    title: 'The Lean Start-up',
                    summary: 'summary',
                    description: 'description',
                    begins_at: '2018-01-03T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: false,
                }, {
                    slug: 'new-admin-meeting',
                    title: 'New Admin Meeting',
                    summary: 'new',
                    description: 'new description',
                    begins_at: '2018-01-02T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: true,
                }],
            })
            .expect(200);

        we.expect(response.body)
            .to.have.lengthOf(1);
        we.expect(response.body[0])
            .to.include({
                inserted_count: 1,
                updated_count: 3,
                unchanged_count: 0,
                deleted_count: 1,
            });

        const meetings = await restService()
            .get('/meetings?select=slug&order=slug')
            .set('Authorization', `Bearer ${jwt}`)
            .expect(200);

        we.expect(meetings.body.map(meeting => meeting.slug))
            .to.deep.equal(['entrepreneurship-woot', 'intro', 'new-admin-meeting', 'structuredquerylang']);

        const repeatResponse = await restService()
            .post('/rpc/sync_meetings')
            .set('Authorization', `Bearer ${jwt}`)
            .send({
                p_meetings: [{
                    slug: 'intro',
                    title: 'Updated Introduction',
                    summary: 'updated',
                    description: 'updated description',
                    begins_at: '2018-01-01T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: false,
                }, {
                    slug: 'structuredquerylang',
                    title: 'Databases and Structured Query Language',
                    summary: 'summary',
                    description: 'description',
                    begins_at: '2018-01-02T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: true,
                }, {
                    slug: 'entrepreneurship-woot',
                    title: 'The Lean Start-up',
                    summary: 'summary',
                    description: 'description',
                    begins_at: '2018-01-03T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: false,
                }, {
                    slug: 'new-admin-meeting',
                    title: 'New Admin Meeting',
                    summary: 'new',
                    description: 'new description',
                    begins_at: '2018-01-02T14:00:00Z',
                    duration: '01:20:00',
                    is_draft: true,
                }],
            })
            .expect(200);

        we.expect(repeatResponse.body[0])
            .to.include({
                inserted_count: 0,
                updated_count: 0,
                unchanged_count: 4,
                deleted_count: 0,
            });
    });
});
