// Second preload for `bun run test_oauth` (tests/bun-rest-setup.js is the
// first; it installs the mocha-style globals and the default timeout).
//
// The suite creates real OAuth clients in Hydra. Lifecycle hooks declared in a
// preloaded file are global, so this is where the run-wide teardown lives:
// every canary client this run registered is deleted when the run finishes,
// and any client left over by an earlier interrupted run is swept before the
// first registration (see sweepStaleClients in helpers.js).

const { afterAll } = require('bun:test');
const { cleanupClients } = require('./oauth/helpers.js');

afterAll(() => {
    cleanupClients();
});
