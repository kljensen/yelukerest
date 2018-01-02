import {
  rest_service,
  jwt,
  resetdb
} from '../common.js';
const request = require('supertest');
const should = require("should");

// Most of what we're testing here requires authentication.
// We're going to need to set-up a mock CAS server,
// like shown here https://github.com/AceMetrix/connect-cas/blob/master/test/service-validate.spec.js
// The, we'll need to dynamically get JWT tokens from our
// app.

describe('engagements', function () {
  before(function (done) {
    resetdb();
    done();
  });

  it('should be selectable', function (done) {
    rest_service()
      .get('/engagements?select=id')
      .expect('Content-Type', /json/)
      .expect(200, done)
      .expect(r => {
        r.body.length.should.equal(3);
        r.body[0].id.should.equal(1);
      })
  });

  it('should be selectable by primary key', function (done) {
    rest_service()
      .get('/engagements/1')
      .expect(200, done)
      .expect(r => {
        r.body.id.should.equal(1);
        r.body.slug.should.equal('intro');
      })
  });

  const newEngagement = {
    "id": 100,
    "slug": "intro",
    "summary": "summary_2_2_2",
    "description": "description_1_",
    "begins_at": "2017-12-27T14:54:50+00:00",
    "duration": "00:00:03",
    "is_draft": false,
    "created_at": "2017-12-27T14:54:50+00:00",
    "updated_at": "2017-12-27T22:09:47.089125+00:00"
  };

  it('should not accept other HTTP verbs', function (done) {
    rest_service()
      .post('/engagements')
      .send(newEngagement)
      .expect(401, done);
  });

  it('should not accept invalid POST requests', function (done) {
    rest_service()
      .post('/engagements')
      .send({})
      .expect(401, done);
  });


});