'use strict';

const app = require('express')();
const session = require('express-session');
const cas = require('connect-cas');
const url = require('url');

// Dump configZ
cas.configure({
    host: 'secure.its.yale.edu',
});
console.log(cas.configure());

// Set up an Express session, which is required for CASAuthentication.
app.use(session({
    secret: 'super secret key',
    resave: false,
    saveUninitialized: true,
    // TODO: change session store because the in-memory
    // store supposedly is bad: https://www.npmjs.com/package/express-session
}));


app.get('/', (req, res) => {
    console.log('wooot');
    if (req.session.cas && req.session.cas.user) {
        return res.send(`<p>You are logged in. Your username is ${req.session.cas.user} <a href="/logout">Log Out</a></p>`);
    }
    return res.send('<p>You are not logged in. <a href="/login">Log in now.</a><p>');
});

// This route has the serviceValidate middleware, which verifies
// that CAS authentication has taken place, and also the
// authenticate middleware, which requests it if it has not already
// taken place.

app.get('/login', cas.serviceValidate(), cas.authenticate(), (req, res) => {
    // Great, we logged in, now redirect back to the home page.
    return res.redirect('/');
});

app.get('/logout', (req, res) => {
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
