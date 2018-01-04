const common = require('../common.js');
const rest_service = common.rest_service;
const jwt = common.jwt;
const resetdb = common.resetdb;
const baseURL = common.baseURL;
const request = require('supertest');
const should = require("should");
const url = require('url');
const we = require('chai');
const chaiString = require('chai-string');
const agentCookies = require('expect-cookies');

// Add the we string plugin
we.use(chaiString);

const authPath = '/auth/login';
const jwtPath = '/auth/jwt';

/** Logs in a user by netid and returns a superagent agent
 *  that has session cookies set.
 * @param  {String} thisStartURL The base URL of the app
 * @param  {String} thisAuthPath The path to begin log in
 * @param  {String} netid The netid of the person we should authenticate
 * @param  {Boolean} isValid Indicates if we expect this to be a valid user
 */
async function userLogin(thisStartURL, thisAuthPath, netid, isValid) {

    // 1. User requests the login page and is redirected to CAS
    const responseFromLoginPage = await request(thisStartURL)
        .get(thisAuthPath)
        .redirects(1);
    we.expect(responseFromLoginPage.redirects).to.have.lengthOf(1);
    const casURL = new url.URL(responseFromLoginPage.redirects[0]);


    // 2. User loads the CAS page and authenticates, thereby getting
    // redirected back to our original service. Note, we assume we're
    // using our Mock CAS server, so we can send the `id` query
    // parameter and be authenticated.
    const responseFromCASServer = await request(`${casURL.protocol}//${casURL.host}`)
        .get(`${casURL.pathname}${casURL.search}&id=${netid}`);
    we.expect(responseFromCASServer.headers).to.have.property('location');

    // 3. Once we're redirected back to our original login page,
    // our app will use a back-channel to see if our CAS authentication
    // was valid and then check to see if this CAS user is allowed to
    // log into Yelukerest. If they can, a session id will be set in
    // a cookie.
    const yelukeCookieInfo = {
        name: 'yeluke.sid'
    };
    let expectedCookieResult;
    if (isValid) {
        expectedCookieResult = agentCookies.set(yelukeCookieInfo);
    } else {
        expectedCookieResult = agentCookies.not('set', yelukeCookieInfo);
    }
    const finalURL = new url.URL(responseFromCASServer.headers.location);
    const agent = request.agent(`${finalURL.protocol}//${finalURL.host}`);
    const finalResponse = await agent
        .get(`${finalURL.pathname}${finalURL.search}`)
        .expect(expectedCookieResult);

    return agent;
}

/**
 * Gets a JWT response for a user. Uses cookie/session information in the agent
 * @param  {superagent.Agent} agent A superagent agent
 * @param  {String} thisJWTPath Path to route that gives us a JWT
 * @param  {String} contentType The Content-Type that we wish to receive
 * @param  {Number} expiresIn Number of seconds for JWT expiration
 */
async function getJWTRequest(agent, thisJWTPath, contentType = 'text/plain', expiresIn = undefined) {
    let req = agent
        .get(thisJWTPath)
        .accept(contentType);


    // Add the expiresIn query parameter if it is supplied
    if (expiresIn) {
        req = req.query({
            expiresIn,
        });
    }
    return req;
}

/**
 * Thin wrapper over getJWTRequest that parses out the JWT
 * @param  {superagent.Agent} agent A superagent agent
 * @param  {String} thisJWTPath Path to route that gives us a JWT
 * @param  {String} contentType The Content-Type that we wish to receive
 * @param  {Number} expiresIn Number of seconds for JWT expiration
 */
async function getJWT(agent, thisJWTPath, contentType = 'text/plain', expiresIn = undefined) {
    const response = await getJWTRequest(agent, thisJWTPath, expiresIn);
    return response.text;
}

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

    it('should create a session for a valid user', async() => {
        await userLogin(baseURL, authPath, 'abc123', true);
    });

    it('should not create a session for an invalid user', async() => {
        await userLogin(baseURL, authPath, 'invalid23', false);
    });

    it('should let valid users get a JWT', async() => {
        const agent = await userLogin(baseURL, authPath, 'abc123', true);
        const jwt = await getJWT(agent, jwtPath);
        we.expect(jwt).to.be.a.singleLine();
        we.expect(jwt).to.have.lengthOf.at.least(20);
    });

    it('should not let invalid users get a JWT', async() => {
        const tryToGetJWT = async() => {
            const agent = await userLogin(baseURL, authPath, 'invalid23', true);
            const jwt = getJWT(agent, jwtPath);
        }
        we.expect(tryToGetJWT).to.throw;
    });

});