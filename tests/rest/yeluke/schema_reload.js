/* global describe it after */

// Proves that `NOTIFY pgrst, 'reload schema'` actually reaches the running
// PostgREST.
//
// Several migrations end with that NOTIFY, and it is the only thing that makes
// a freshly deployed view or function reachable over the API without
// restarting PostgREST. bin/test-rest-stack.sh bootstraps every migration
// *before* PostgREST starts, so a green suite otherwise says nothing about
// whether the notification channel still works. If it silently stopped
// working -- db-channel-enabled turned off, the channel renamed, LISTEN
// dropped by a connection pooler -- a deployed migration would appear to work
// in tests and 404 in production until someone restarted the container.
//
// The probe is a uniquely named view created and dropped inside this test. It
// is not referenced by anything else, so a failure here cannot corrupt the
// database for the other suites; the worst case is one stale entry in the
// schema cache, which the final reload clears.

const {
    runSQL,
    restService,
} = require('../common.js');

const {
    we,
} = require('./helpers.js');

const PROBE_VIEW = 'zz_schema_reload_probe';
const PROBE_TOKEN = 'schema-reload-probe';

const sleep = ms => new Promise((resolve) => {
    setTimeout(resolve, ms);
});

const dropProbe = () => {
    runSQL(`DROP VIEW IF EXISTS api.${PROBE_VIEW};\nNOTIFY pgrst, 'reload schema';\n`);
};

/**
 * Polls the probe endpoint until it returns the wanted status.
 * @param {Number} wantStatus the status code we are waiting for
 * @param {Number} timeoutMS how long to wait before giving up
 * @returns {Object} the last response received
 */
const pollProbe = async (wantStatus, timeoutMS = 15000) => {
    const deadline = Date.now() + timeoutMS;
    let response;
    do {
        // eslint-disable-next-line no-await-in-loop
        response = await restService()
            .get(`/${PROBE_VIEW}`)
            .ok(() => true);
        if (response.status === wantStatus) {
            return response;
        }
        // eslint-disable-next-line no-await-in-loop
        await sleep(250);
    } while (Date.now() < deadline);
    return response;
};

describe('PostgREST schema cache reload', () => {
    after(() => {
        dropProbe();
    });

    it('exposes a newly created api view after NOTIFY, without a restart', async () => {
        // Start from a known-absent state so a leftover probe cannot make this
        // test pass for the wrong reason.
        dropProbe();
        const missing = await pollProbe(404, 5000);
        we.expect(missing.status, 'probe should not exist before it is created')
            .to.equal(404);

        runSQL(`
            CREATE VIEW api.${PROBE_VIEW} AS SELECT '${PROBE_TOKEN}'::text AS token;
            ALTER VIEW api.${PROBE_VIEW} OWNER TO api;
            GRANT SELECT ON api.${PROBE_VIEW} TO anonymous;
            NOTIFY pgrst, 'reload schema';
        `);

        const found = await pollProbe(200);
        we.expect(found.status, 'probe should be reachable after NOTIFY pgrst, reload schema')
            .to.equal(200);
        we.expect(found.body)
            .to.deep.equal([{
                token: PROBE_TOKEN,
            }]);

        // And the reload works in the other direction too, which is what a
        // migration's revert.sql relies on.
        dropProbe();
        const gone = await pollProbe(404);
        we.expect(gone.status, 'probe should disappear after it is dropped and reloaded')
            .to.equal(404);
    });
});
