/* global describe it before */

const {
    resetdb,
    baseURL,
    authPath,
    jwtPath,
    restService,
} = require('../common.js');

const {
    getJWTForNetid,
    we,
} = require('./helpers.js');

describe('my_assignments API endpoint', () => {
    // abc123 is user 1: a student on bright-fog who owns submission 1 on
    // team-selection, graded 50/50, with no grade exception.
    const studentJWTPromise = getJWTForNetid(baseURL, authPath, jwtPath, 'abc123');

    before(async () => {
        resetdb();
    });

    it('should give a student one me-scoped row with eligibility, extension and submissions', async () => {
        const jwt = await studentJWTPromise;
        const response = await restService()
            .get('/my_assignments?slug=eq.team-selection')
            .set('Authorization', `Bearer ${jwt}`)
            .expect('Content-Type', /json/)
            .expect(200);

        we.expect(response.body).to.have.lengthOf(1);
        const [row] = response.body;

        we.expect(row).to.have.all.keys(
            'slug', 'title', 'is_team', 'is_draft', 'is_markdown', 'points_possible',
            'is_open', 'closed_at', 'created_at', 'updated_at', 'effective_closed_at',
            'submission_window_open',
            'can_submit', 'can_submit_reason', 'extension_closed_at',
            'extension_fractional_credit', 'submissions',
        );
        we.expect(row).to.include({
            slug: 'team-selection',
            is_team: false,
            is_draft: false,
            is_open: true,
            submission_window_open: true,
            can_submit: true,
            can_submit_reason: null,
            extension_closed_at: null,
            extension_fractional_credit: null,
        });
        we.expect(row.effective_closed_at).to.equal(row.closed_at);

        we.expect(row.submissions).to.have.lengthOf(1);
        const [submission] = row.submissions;
        we.expect(submission).to.include({
            id: 1,
            team_nickname: null,
            fields_submitted: 1,
            fields_total: 1,
        });
        we.expect(submission.grade).to.include({
            points: 50,
            description: 'Foo bar bax boo this is your comment',
        });
    });
});
