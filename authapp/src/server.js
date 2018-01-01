'use strict';

const app = require('express')();
const session = require('express-session');
const cas = require('connect-cas');
const url = require('url');
const RedisStore = require('connect-redis')(session);
const config = require('./config.js');

// Dump configZ
cas.configure({
    host: config.cas_host,
});

// Set up an Express session, which is required for CASAuthentication.
// See https://github.com/expressjs/session
const sessionOptions = {
    name: 'yeluke.sid',
    // Use Redis to store our session
    store: new RedisStore({
        host: config.redis_host,
        port: config.redis_port,
    }),
    cookie: {
        // Protext against CSRF
        sameSite: true,
        // Expire after 5 days
        maxAge: 5 * 24 * 60 * 60 * 1000,
    },
    secret: config.session_secret,
    resave: false,
    saveUninitialized: true,
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

app.use(session(sessionOptions));

// NOTE: I am not happy that I'm hard-coding the `/auth/`
// prefix here and also in NGINX. I don't know how to pass
// in an environment variable into Nginx so that this prefix
// is configurable and only written down in one place.
// TODO: find a solution.
const mountPrefix = '/auth';

app.get(mountPrefix, (req, res) => {
    if (req.session.cas && req.session.cas.user) {
        return res.send(`<p>You are logged in. Your username is ${req.session.cas.user} <a href="/logout">Log Out</a></p>`);
    }
    return res.send(`<p>You are not logged in. <a href="${mountPrefix}/login">Log in now.</a><p>`);
});

// This route has the serviceValidate middleware, which verifies
// that CAS authentication has taken place, and also the
// authenticate middleware, which requests it if it has not already
// taken place.

app.get(`${mountPrefix}/login`, cas.serviceValidate(), cas.authenticate(), (req, res) => {
    // When the user lands on this route, they will be redirected
    // to the CAS server if they do not already have the requisite
    // session identifier. Once they return from CAS auth, they'll
    // be redirected back this same URL with URL query parameters 
    // like the following:
    // /auth/login?ticket=ST-136710-jNP4f2342Xpn2bpiys71-vmssoprdapp01
    // The CAS library will use this to fetch netid info and store
    // that is `req.session.cas.user`.

    // If that goes ok, we logged in, now redirect back to the home page.
    return res.redirect('/');
});

app.get(`${mountPrefix}/logout`, (req, res) => {
    if (!req.session) {
        return res.redirect('/');
    }
    // Forget our own login session
    if (req.session.destroy) {
        req.session.destroy();
    } else {
        // Cookie-based sessions have no destroy()
        req.session = null;
    }
    // Send the user to the official campus-wide logout URL
    const options = cas.configure();
    options.pathname = options.paths.logout;
    return res.redirect(url.format(options));
});

const PORT = 4000;
const HOST = '0.0.0.0';
app.listen(PORT, HOST);
console.log(`Running on http://${HOST}:${PORT}`);
