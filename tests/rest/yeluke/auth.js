const common = require('../common.js');
const rest_service = common.rest_service;
const jwt = common.jwt;
const resetdb = common.resetdb;
const baseURL = common.baseURL;
const request = require('supertest');
const should = require("should");
const chai = require('chai');
const url = require('url');

// Most of what we're testing here requires authentication.
// We're going to need to set-up a mock CAS server,
// like shown here https://github.com/AceMetrix/connect-cas/blob/master/test/service-validate.spec.js
// The, we'll need to dynamically get JWT tokens from our
// app. Also, we'll need to store credentials after logging-in. 
// See https://medium.com/@juha.a.hytonen/testing-authenticated-requests-with-supertest-325ccf47c2bb
// and https://github.com/visionmedia/superagent/blob/master/test/node/agency.js

const authPath = '/auth/login';

describe('Yeluke auth using CAS', function () {
    before(function (done) {
        resetdb();
        done();
    });

    it('login page should give a temporary redirect to the CAS server', async() => {
        const response = await request(baseURL)
            .get(authPath)
            .expect('Location', /http/)
            .expect(307);
    });

    it('should redirect back to the originating service after entering credentials', async() => {
        const response1 = await request(baseURL)
            .get(authPath)
            .redirects(1);
        chai.expect(response1.redirects).to.have.lengthOf(1);
        const casURL = new url.URL(response1.redirects[0]);
        // console.error(`cas url = ${casURL}`);
        const agent = request.agent(casURL.host);
        const netid = 'klj39';
        const path = `${casURL.pathname}${casURL.search}&id=${netid}`;
        // console.error(path);
        await agent
            .get(path) // post to the current URL
            .expect(302);
    });


});