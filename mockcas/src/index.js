// This is a mock CAS server. We use it for testing only.
const app = require('express')();
const path = require('path');

// Set up our view engine
app.engine('pug', require('pug')
    .__express);
app.set('views', path.join(__dirname, 'views'));
app.set('view engine', 'pug');

app.get('/cas/serviceValidate', (req, res) => {
    console.log('Got request to /cas/serviceValidate');
    res.set('Content-Type', 'text/xml');
    const failureContent = '<cas:serviceResponse xmlns:cas="https://www.yale.edu/tp/cas"><cas:authenticationFailure code="INVALID_TICKET">Ticket ST-1856339-aA5Yuvrxzpv8Tau1cYQ7 not recognized</cas:authenticationFailure></cas:serviceResponse>';
    const ticket = req.query.ticket;
    if (!ticket) {
        return res.send(failureContent);
    }

    // We expect to get something like ticket=mock-ticket-blah234, 
    // where blah234 is the netid of the person authenticating.
    const ticketBits = ticket.split('-');
    if (ticketBits.length != 3 || ticketBits[0] != 'mock' || ticketBits[1] != 'ticket') {
        return res.send(failureContent);
    }
    const netid = ticketBits[2];
    const response = `<cas:serviceResponse xmlns:cas="https:/www.yale.edu/tp.cas"><cas:authenticationSuccess><cas:user>${netid}</cas:user><cas:foo>bar</cas:foo></cas:authenticationSuccess></cas:serviceResponse>`;
    return res.send(response);
});

app.get('/cas/login', (req, res) => {
    console.log('Got request to /cas/login');
    const service = req.query.service;
    if (!service) {
        res.status(400);
        res.end();
        return;
    }
    // If they supplied a userid, just do the redirect straight off
    const id = req.query.id;
    if (id) {
        res.redirect(service + `?ticket=mock-ticket-${id}`);
        return;
    }
    res.render('login', {
        title: 'MockCAS',
        message: 'Fill in the netid with with you want to authenticate!',
        service: service,
    });
});


// app.get('*', (req, res) => {
//     res.send('mock server running');
// });

const port = process.env.PORT || 8000;
const host = process.env.HOST || '0.0.0.0';
app.listen(port, host, () => {
    console.log(`MockCAS running on ${host}:${port}`);
});
