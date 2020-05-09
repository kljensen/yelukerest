const chai = require('chai');
const request = require('supertest');
const common = require('./common.js');

chai.should();

const { resetdb, baseURL } = common;

describe('auth/login', () => {
    before((done) => {
        resetdb();
        done();
    });

    it('should redirect to CAS', (done) => {
        request(baseURL).get('/auth/login').expect(307, done);
    });

    // it('me', (done) => {
    //     restService()
    //         .post('/rpc/me')
    //         .set('Accept', 'application/vnd.pgrst.object+json')
    //         .set('Authorization', `Bearer ${jwt}`)
    //         .send({})
    //         .expect('Content-Type', /json/)
    //         .expect(200, done)
    //         .expect((r) => {
    //             r.body.email.should.equal('alice@email.com');
    //         });
    // });

    // it('refresh_token', (done) => {
    //     restService()
    //         .post('/rpc/refresh_token')
    //         .set('Accept', 'application/vnd.pgrst.object+json')
    //         .set('Authorization', `Bearer ${jwt}`)
    //         .send({})
    //         .expect('Content-Type', /json/)
    //         .expect(200, done)
    //         .expect((r) => {
    //             r.body.length.should.above(0);
    //         });
    // });
});
