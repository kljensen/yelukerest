// This is a mock CAS server. We use it for testing only.
const app = require('express')();
const path = require('path');
const morgan = require('morgan');
const winston = require('winston');

// Set up logging
const level = process.env.LOG_LEVEL || 'debug';
const logger = new winston.Logger({
    transports: [
        new winston.transports.Console({
            level: level,
            timestamp: function () {
                return (new Date())
                    .toISOString();
            }
        })
    ]
});

// Tell morgan to log through this winston logger
app.use(morgan(':method :url :status :res[content-length] - :response-time ms', {
    stream: {
        write: msg => {
            logger.info('-----------------');
            logger.info(msg);
        }
    }
}));

// Set up our view engine
app.engine('pug', require('pug')
    .__express);
app.set('views', path.join(__dirname, 'views'));
app.set('view engine', 'pug');

app.get('/cas/serviceValidate', (req, res) => {
    res.set('Content-Type', 'text/xml');
    const failureContent = '<cas:serviceResponse xmlns:cas="https://www.yale.edu/tp/cas"><cas:authenticationFailure code="INVALID_TICKET">Ticket ST-1856339-aA5Yuvrxzpv8Tau1cYQ7 not recognized</cas:authenticationFailure></cas:serviceResponse>';
    const ticket = req.query.ticket;
    if (!ticket) {
        logger.info('\t* No ticket in query parameters. Sending INVALID_TICKET response.');
        return res.send(failureContent);
    }

    // We expect to get something like ticket=mock-ticket-blah234, 
    // where blah234 is the netid of the person authenticating.
    const ticketBits = ticket.split('-');
    if (ticketBits.length != 3 || ticketBits[0] != 'mock' || ticketBits[1] != 'ticket') {
        logger.info('\t* Ticket not in expected format. Sending INVALID_TICKET response.');
        return res.send(failureContent);
    }
    const netid = ticketBits[2];
    const response = `<cas:serviceResponse xmlns:cas="https:/www.yale.edu/tp.cas"><cas:authenticationSuccess><cas:user>${netid}</cas:user><cas:foo>bar</cas:foo></cas:authenticationSuccess></cas:serviceResponse>`;
    logger.info(`\t* No ticket in query parameters. Sending authentication success response for netid "${netid}".`);
    return res.send(response);
});

app.use('/cas/login', (req, res) => {
    const service = req.query.service;
    if (!service) {
        logger.info('\t* No service specified in query. Sending 400 response');
        res.status(400);
        res.end();
        return;
    }
    // If they supplied a userid, just do the redirect straight off
    const id = req.query.id;
    if (id) {
        logger.info(`\t* Received netid "${id}" in query. Redirecting to service ${service}`);
        res.redirect(service + `?ticket=mock-ticket-${id}`);
        return;
    }
    logger.info(`\t* Displaying login form for service ${service}`);
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
    logger.info(`MockCAS running on ${host}:${port}`);
});