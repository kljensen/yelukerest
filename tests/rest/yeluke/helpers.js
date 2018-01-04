const request = require('supertest');
const we = require('chai');
const url = require('url');
const agentCookies = require('expect-cookies');
const chaiAsPromised = require('chai-as-promised');
const chaiString = require('chai-string');
const dirtyChai = require('dirty-chai');

const {
    restService,
} = require('../common.js');

// Add the we string plugin
we.use(chaiString);
we.use(dirtyChai);
we.use(chaiAsPromised);


/** Logs in a user by netid and returns a superagent agent
 *  that has session cookies set.
 * @param  {String} thisStartURL The base URL of the app
 * @param  {String} thisAuthPath The path to begin log in
 * @param  {String} netid The netid of the person we should authenticate
 * @param  {Boolean} isValid Indicates if we expect this to be a valid user
 * @returns {Promise} A promise that resolves to cookie like
 *                      'yeluke.sid=s%3Abtbv2_jxLhFv2beVKBXgCt...'
 */
async function getUserSessionCookie(thisStartURL, thisAuthPath, netid) {
    // 1. User requests the login page and is redirected to CAS
    const responseFromLoginPage = await request(thisStartURL)
        .get(thisAuthPath)
        .redirects(1);
    we.expect(responseFromLoginPage.redirects)
        .to.have.lengthOf(1);
    const casURL = new url.URL(responseFromLoginPage.redirects[0]);


    // 2. User loads the CAS page and authenticates, thereby getting
    // redirected back to our original service. Note, we assume we're
    // using our Mock CAS server, so we can send the `id` query
    // parameter and be authenticated.
    const responseFromCASServer = await request(`${casURL.protocol}//${casURL.host}`)
        .get(`${casURL.pathname}${casURL.search}&id=${netid}`);
    we.expect(responseFromCASServer.headers)
        .to.have.property('location');

    // 3. Once we're redirected back to our original login page,
    // our app will use a back-channel to see if our CAS authentication
    // was valid and then check to see if this CAS user is allowed to
    // log into Yelukerest. If they can, a session id will be set in
    // a cookie.
    const yelukeCookieInfo = {
        name: 'yeluke.sid',
    };

    const finalURL = new url.URL(responseFromCASServer.headers.location);
    const agent = request.agent(`${finalURL.protocol}//${finalURL.host}`);
    const finalResponse = await agent
        .get(`${finalURL.pathname}${finalURL.search}`)
        .expect(agentCookies.set(yelukeCookieInfo));
    we.expect(finalResponse.header)
        .to.have.property('set-cookie');
    we.expect(finalResponse.header['set-cookie'])
        .to.have.lengthOf(1);
    const sidCookie = finalResponse.header['set-cookie'];
    return sidCookie;
}

/**
 * Gets a JWT response for a user. Uses cookie/session information in the agent
 * @param  {String} thisBaseURL A superagent agent
 * @param  {String} thisJWTPath Path to route that gives us a JWT
 * @param  {Array} cookies An array of strings with cookies to set
 * @param  {String} contentType The Content-Type that we wish to receive
 * @param  {Number} expiresIn Number of seconds for JWT expiration
 * @returns {Promise} a promise that resolves to a request to the JWT-providing endpoint
 */
async function getJWTRequest(thisBaseURL, thisJWTPath, cookies, contentType = 'text/plain', expiresIn = undefined) {
    let req = request(thisBaseURL)
        .get(thisJWTPath)
        .set('Cookie', cookies)
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
 * @param  {String} thisBaseURL Where to start
 * @param  {String} thisJWTPath Path to route that gives us a JWT
 * @param  {Array} cookies An array of strings with cookies to set
 * @param  {String} contentType The Content-Type that we wish to receive
 * @param  {Number} expiresIn Number of seconds for JWT expiration
 * @returns {Promise} A promise that resolves to a string containing a JWT
 */
async function getJWT(thisBaseURL, thisJWTPath, cookies, contentType = 'text/plain', expiresIn = undefined) {
    const response = await getJWTRequest(thisBaseURL, thisJWTPath, cookies, contentType, expiresIn);
    return response.text;
}

/**
 * Gets session and then JWT
 * @param  {String} thisBaseURL Where to start
 * @param  {String} thisAuthPath The path to begin log in
 * @param  {String} thisJWTPath Path to route that gives us a JWT
 * @param  {Array} netid The netid for wish we wish to get a JWT
 * @param  {String} contentType The Content-Type that we wish to receive
 * @param  {Number} expiresIn Number of seconds for JWT expiration
 * @returns {Promise} A promise that resolves to a string containing a JWT
 */
async function getJWTForNetid(thisBaseURL, thisAuthPath, thisJWTPath, netid, contentType = 'text/plain', expiresIn = undefined) {
    const cookie = await getUserSessionCookie(thisBaseURL, thisAuthPath, netid, true);
    return getJWT(thisBaseURL, thisJWTPath, [cookie], contentType, expiresIn);
}


const postRequestWithJWT = (path, body, jwt) => {
    let req = restService()
        .post(path)
        .set('Accept', 'application/vnd.pgrst.object+json');

    if (jwt) {
        req = req.set('Authorization', `Bearer ${jwt}`);
    }
    req = req.send(body);
    return req;
};

const getRequestWithJWT = (path, jwt) => {
    let req = restService()
        .get(path)
        .set('Accept', 'application/vnd.pgrst.object+json');

    if (jwt) {
        console.log('jwt =', jwt);
        req = req.set('Authorization', `Bearer ${jwt}`);
    } else {
        console.log('NO JWT');
    }
    return req;
};


/**
 * Dynamically creates a number of test cases on post/insert. The caller
 * supplies a the `it` from a mocha test suite and this function adds in tests.
 * @param  {it} theIt The `it` from a mocha test suite
 * @param {String} path path to which we will POST
 * @param {Object} body body we will POST
 * @param {Object} testCases the test cases, each of which can override path or body.
 *                  These should have at least a `status` attribute.
 * @returns {undefined}
 */
async function makePostTestCases(theIt, path, body, testCases) {
    testCases.forEach((tc) => {
        theIt(tc.title || 'the test', async() => {
            we.expect(tc)
                .to.have.property('status');
            postRequestWithJWT(tc.path || path, tc.body || body, tc.jwt)
                .expect(tc.status);
        });
    });
}

/**
 * Dynamically creates a number of test cases. Often, we want to verify something
 * like "a user can see only her/his rows" and "a faculty can see all rows". This
 * helps us write those with minimal code duplication.
 * @param  {it} theIt The `it` from a mocha test suite
 * @param {String} path path to which we will POST
 * @param {Function} setMaker a function that is applied to each row of the
 *                              results to create a set.
 * @param {Object} testCases the test cases, each of which can override path.
 *                  These should have at least a `status` attribute. It can
 *                  also have a `length` and a `set` attribute. The `set`
 * @returns {undefined}
 */
async function makeListTestCases(theIt, path, setMaker, testCases) {
    testCases.forEach((tc) => {
        theIt(tc.title || 'the test', async() => {
            we.expect(tc)
                .to.have.property('status');
            console.log('In makelisttestcases, tc = ', tc);
            const response = await getRequestWithJWT(tc.path || path, tc.jwt)
                .expect(tc.status);

            // If we expect an OK response, let's check to ensure
            // the content is also what we expect.
            if (tc.status === 200) {
                we.expect(response.body)
                    .to.be.a.instanceOf(Array);
                if (tc.length) {
                    we.expect(response.body)
                        .to.have.lengthOf(tc.length);
                }
                if ((tc.setMaker || setMaker) && tc.set) {
                    const thisSet = new Set(response.body.map(tc.setMaker || setMaker));
                    we.expect(thisSet)
                        .to.equal(new Set(tc.set));
                }
            }
        });
    });
}

// const tryToInsertNewEngagement = jwt => postRequestWithJWT('/engagements', newEngagement, jwt);

// it('should not accept post requests from anonymous users', (done) => {
//     tryToInsertNewEngagement()
//         .expect(401, done);
// });


module.exports = {
    getJWTRequest,
    getJWT,
    getUserSessionCookie,
    getJWTForNetid,
    we,
    postRequestWithJWT,
    makePostTestCases,
    makeListTestCases,
};
