const chai = require('chai');
const request = require('supertest');
const common = require('./common.js');

chai.should();
// eslint-disable-next-line no-unused-vars
const { expect } = chai;

const { resetdb, baseURL } = common;

describe('auth/login', () => {
    before((done) => {
        resetdb();
        done();
    });

    it('should redirect to CAS', (done) => {
        request(baseURL)
            .get('/auth/login')
            .expect(302, done)
            .expect('location', /^http/i);
    });

});
