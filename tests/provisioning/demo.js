// Not a test: seeds the dev stack for a hands-on look at the repositories
// page. Run by hand after `YELUKEREST_TEST_KEEP_FAKE=1 bun run
// test_provisioning` has left the fake up and authapp pointed at it:
//
//   bun tests/provisioning/demo.js
//
// then sign in at https://localhost/auth/login as one of the netids it
// prints (the mock CAS accepts any of them) and open
// https://localhost/auth/repositories. The seed is the suite's: the four
// templates (three active, one retired), a GitHub login for every student,
// and the fake scripted so a new repository reads as "copying" for a
// dozen seconds before it is ready, which is long enough to watch the
// page poll.

// The dev stack's certificate is self-signed. `bun test` gets this from
// tests/bun-rest-setup.js; a plain script has to say it itself, and
// superagent needs telling per request as well as through the variable.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const superagent = require('superagent');

if (superagent.Request && superagent.Request.prototype.disableTLSCerts) {
    const originalEnd = superagent.Request.prototype.end;
    superagent.Request.prototype.end = function patchedEnd(...args) {
        this.disableTLSCerts();
        return originalEnd.apply(this, args);
    };
}

const { seed, baselineFake, templates } = require('./helpers.js');

(async () => {
    await seed();
    await baselineFake({
        headCallsUntilReady: 4,
        memberships: {
            abc123: 'active', bde456: 'pending', pt1: 'active', pt2: 'active',
        },
    });
    console.log('seeded.');
    console.log('templates:', Object.values(templates).map(t => `${t.slug}${t.is_active === false ? ' (inactive)' : ''}`).join(', '));
    console.log('students:');
    console.log('  abc123  member of the organization; team bright-fog; every template shows');
    console.log('  bde456  pending membership: Create answers needs_org_join');
    console.log('  pt1 / pt2  team damp-pond: one click makes the team repository for both');
    console.log('  klj39   faculty: the students-only page');
})();
