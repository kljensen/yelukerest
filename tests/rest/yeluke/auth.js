const common = require('../common.js');
const rest_service = common.rest_service;
const jwt = common.jwt;
const resetdb = common.resetdb;
const baseURL = common.baseURL;
const request = require('supertest');
const should = require("should");

// Most of what we're testing here requires authentication.
// We're going to need to set-up a mock CAS server,
// like shown here https://github.com/AceMetrix/connect-cas/blob/master/test/service-validate.spec.js
// The, we'll need to dynamically get JWT tokens from our
// app. Also, we'll need to store credentials after logging-in. 
// See https://medium.com/@juha.a.hytonen/testing-authenticated-requests-with-supertest-325ccf47c2bb

describe('Yeluke CAS auth', function () {
    before(function (done) {
        resetdb();
        done();
    });

    it('login page should give a temporary redirect to the CAS server', async() => {
        console.error('woot');
        const response = await request(`${baseURL}`)
            .get('/auth/login')
            .expect('Location', /http/)
            .expect(307);
        console.error('done with response');
    });

});