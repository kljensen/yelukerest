'use strict';

const express = require('express');
const session = require('express-session');
const cas = require('connect-cas');
const url = require('url');
const httpstatus = require('http-status-codes');
const jsonwebtoken = require('jsonwebtoken');
const pg = require('pg');
const RedisStore = require('connect-redis')(session);
const config = require('./config.js');
const morgan = require('morgan');
const winston = require('winston');
const cookieParser = require('cookie-parser');

// Set up logging
const level = process.env.LOG_LEVEL || 'debug';
const logger = new winston.Logger({
    transports: [
        new winston.transports.Console({
            level,
            timestamp() {
                return (new Date())
                    .toISOString();
            },
        }),
    ],
});

const app = express();

// Tell morgan to log through this winston logger
app.use(morgan(':method :url :status :res[content-length] - :response-time ms', {
    stream: {
        write: (msg) => {
            logger.info(msg);
            logger.info('-----------------');
        },
    },
}));

// Dump configZ
cas.configure({
    host: config.cas_host,
    protocol: config.cas_protocol,
});

if (config.is_development) {
    logger.info('Configuration:');
    logger.info(config);
    logger.info('CAS configuration:');
    logger.info(cas.configure());
}

// Establish database connection. This does not actually
// establish a connection until we request a client from the pool.
const dbPool = pg.Pool({
    host: config.db_host,
    port: config.db_port,
    database: config.db_name,
    user: config.db_user,
    password: config.db_pass,
});


// Set up an Express session, which is required for CASAuthentication.
// See https://github.com/expressjs/session
const sessionOptions = {
    // The name of the cookie stored on the user's browser.
    name: 'yeluke.sid',
    // Use Redis to store our session information server side. The session
    // id stored in the user's browser is only used to find the session info
    // server-side.
    store: new RedisStore({
        host: config.redis_host,
        port: config.redis_port,
    }),
    cookie: {
        // Protext against CSRF
        sameSite: true,
        // Expire after 5 days
        maxAge: 5 * 24 * 60 * 60 * 1000
    },
    // The secret used to sign the cookie so that it is tamper-proof
    secret: config.session_secret,
    // No need to 'touch' our session. If it expires from the session store, fine.
    resave: false,
    // No need to save session information for people prior to authentication
    saveUninitialized: false,
    // Trust the reverse proxy when setting secure cookies
    // (via the "X-Forwarded-Proto" header).
    proxy: true,
};

if (config.is_production) {
    // Trust first proxy
    app.set('trust proxy', 1);
    // Serve secure cookies
    sessionOptions.cookie.secure = true;
}

// app.use(cookieParser(config.session_secret));

// Tell the app to use our session options
app.use(session(sessionOptions));

// Turn off all caching
app.use((req, res, next) => {
    logger.info('----------*********************** START REQ');
    res.header('Cache-Control', 'private, no-cache, no-store, must-revalidate');
    res.header('Expires', '-1');
    res.header('Pragma', 'no-cache');
    if (req.session) {
        logger.info(`Session cookie = ${JSON.stringify(req.session.cookie)}`);
    } else {
        logger.info('No session');
    }
    next();
});


/**
 * Check if a user exists in the database by netid
 * @param  {pg.Pool} pool A connection pool from which to take a connection to Postgres.
 * @param  {String} netid The netid of the student we wish to look for in the database.
 * @returns {Promise} A promise that resolves to an object `id`, `netid` and `role` keys.
 */
async function getYelukeUserInfo(pool, netid) {
    const userInfo = {};
    // Note that this automatically returns the client drawn from the
    // pool back to the pool after the query is completed.
    // See https://github.com/brianc/node-pg-pool
    try {
        const result = await pool.query('SELECT id,netid,role FROM api.users WHERE netid = $1', [netid]);
        userInfo.error = false;
        if (result.rows.length !== 1) {
            return userInfo;
        }
        userInfo.id = result.rows[0].id;
        userInfo.netid = result.rows[0].netid;
        userInfo.role = result.rows[0].role;
    } catch (error) {
        // Catch the promise rejection
        userInfo.error = true;
    }
    return userInfo;
}

/**
 * Destroys a session for a user
 * @param  {express.Request} req The request with session info
 * @returns {undefined}
 */
function destroyRequestSession(req) {
    // Forget our own login session
    if (req.session && req.session.destroy) {
        req.session.destroy();
    } else {
        // Cookie-based sessions have no destroy()
        req.session = null;
    }
}


/**
 * Check to see if the CAS user set by connect-cas exists in the Yeluke database.
 * If so, set the Yeluke user information in the session. This *always* alters
 * the session to reflect the most recent id/netid/role for the user.
 * @param  {express.Request} req An express request
 * @param  {express.Response} res An express response
 * @param  {function} next the callback to signal when we're done
 * @returns {Promise} a promise that must be awaited
 */
async function validateYelukeUser(req, res, next) {
    logger.info('Trying to validateYelukeUser');
    // Once we reach here, the user should have authenticated with CAS.
    let logMsg;
    if (!req.session || !req.session.cas || !req.session.cas.user) {
        logger.info('No CAS information in the session');
        destroyRequestSession(req);
        res.status(httpstatus.UNAUTHORIZED)
            .send('Unauthorized');
        return;
    }
    logMsg = `Found session ID: ${req.sessionID}`;
    logger.info(logMsg);
    logMsg = `Found CAS information in session: ${JSON.stringify(req.session.cas)}`;
    logger.info(logMsg);
    const netid = req.session.cas.user;
    const userInfo = await getYelukeUserInfo(dbPool, netid);
    if (userInfo.error) {
        destroyRequestSession(req);
        res.send(httpstatus.INTERNAL_SERVER_ERROR);
        return;
    }
    logMsg = `CAS ${netid} is NOT authorized to log in`;
    if (!userInfo.id || userInfo.netid !== netid) {
        try {
            logger.info(logMsg);
            destroyRequestSession(req);
            res.status(httpstatus.UNAUTHORIZED)
                .send(logMsg);
            return;

        } catch (error) {
            console.error(error);
            throw error;
        }
    }
    logMsg = `CAS ${netid} is authorized to log in. Setting session info.`;
    logger.info(logMsg);
    req.session.yeluke = {
        user: userInfo,
    };
    next();
}


const router = express.Router();

// In development we might have difficultly connecting to the
// service validation host if it is a mock cas server running
// in a container. Hence, we allow this override.
const serviceValidateOptions = {};
if (config.is_development && config.cas_service_validate_host) {
    serviceValidateOptions.host = config.cas_service_validate_host;
}
const serviceValidate = cas.serviceValidate(serviceValidateOptions);

// The set of middleware to log in a user.
const loginMiddlewareChain = [
    // Check if there is a CAS ticket in the request query parameters.
    // If so, validate it with the CAS server and set `cas.user` in
    // the session.
    serviceValidate,
    // Check if there is a `cas.user` in the session. If there is not,
    // redirect to the CAS service's login page.
    cas.authenticate(),
    // Check if the `cas.user` in the session is a valid Yeluke user.
    // If so, set `yeluke.user` in the session. Else, unauthorized.
    validateYelukeUser,
];


// Login a user. This creates session information.
router.get('/login', loginMiddlewareChain, (req, res) => {
    logger.info(`User ${req.session.cas.user} logged in`);
    return res.redirect('/');
});

// Logout a user. This destroys the session.
router.get('/logout', (req, res) => {
    if (!req.session) {
        return res.redirect('/');
    }
    destroyRequestSession(req);

    // Send the user to the official campus-wide logout URL
    const options = cas.configure();
    options.pathname = options.paths.logout;
    return res.redirect(url.format(options));
});

// Sign a JWT for a user. They must have valid session info.
router.get('/jwt', validateYelukeUser, (req, res) => {
    const twoDaysOfSeconds = 2 * 24 * 60 * 60;
    let expiresIn = twoDaysOfSeconds;

    // Allow a custom expiration expressed in seconds.
    if (req.query.expiresIn) {
        if (Number.isNaN(req.query.expiresIn)) {
            res.send(httpstatus.BAD_REQUEST);
        }
        expiresIn = parseInt(req.query.expiresIn, 10);
        if (expiresIn <= 0 || expiresIn > twoDaysOfSeconds) {
            res.send(httpstatus.BAD_REQUEST);
        }
    }
    // Since we used the `validateYelukeUser` middleware above, we know
    // we have accurate Yeluke user information in the session. Now we'll
    // create a JWT with it.
    const jwtPayload = {
        user_id: req.session.yeluke.user.id,
        role: req.session.yeluke.user.role,
    };
    const signingOptions = {
        algorithm: 'HS256',
        expiresIn,
        issuer: config.jwt_issuer,
    };
    const signedJWT = jsonwebtoken.sign(jwtPayload, config.jwt_secret, signingOptions);

    // sendit is a function that writes the JWT to the response when called.
    const sendit = () => {
        res.send(signedJWT);
    };

    // Handle content negotiation and send the JWT.
    // See http://expressjs.com/en/api.html#res.format
    let logMsg;
    logMsg = `Had session info as follows = ${JSON.stringify(req.session.yeluke)}`;
    logger.info(logMsg);
    logMsg = `Created JWT with payload = ${JSON.stringify(jwtPayload)}`;
    logger.info(logMsg);
    logMsg = `JWT = ${signedJWT.slice(0,10)}...${signedJWT.slice(-10)}`;
    logger.info(logMsg);

    res.format({
        'application/jwt': sendit,
        'text/plain': sendit,
        'text/html': sendit,
        'application/json': () => {
            // Have to wrap it in an object or an array.
            // See https://www.ietf.org/rfc/rfc4627.txt
            res.send({
                token: signedJWT,
            });
        },
        default () {
            res.status(406)
                .send('Not Acceptable');
        },
    });
});




// NOTE: I am not happy that I'm hard-coding the `/auth/`
// prefix here and also in NGINX. I don't know how to pass
// in an environment variable into Nginx so that this prefix
// is configurable and only written down in one place.
// TODO: find a solution.
const mountPrefix = '/auth';
app.use(mountPrefix, router);


const PORT = 4000;
const HOST = '0.0.0.0';
app.listen(PORT, HOST, () => {
    logger.info(`Running on http://${HOST}:${PORT}`);
});

/** TODO: clean up database pool connections. I can't get this working with nodemon.
 * @returns {Promise} a promise that you should await
 */
// function cleanUpDBPool() {
//     console.log('wooot');
//     logger.warn('Cleaning up database connections');
//     return dbPool.end();
// }
// Clean up the database connections upon termination. I can't
// seem to get this to work!
// ['SIGUSR2', 'SIGTERM', 'SIGINT'].forEach((signal) => {
//     process.on(signal, async() => {
//         console.log('Caught signal', signal);
//         await cleanUpDBPool();
//     });
// });
