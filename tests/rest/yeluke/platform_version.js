const {
    restService,
} = require('../common.js');

const {
    we,
} = require('./helpers.js');

describe('platform_version API endpoint', () => {
    it('should expose compatibility metadata without authentication', async () => {
        const response = await restService()
            .get('/platform_version')
            .expect('Content-Type', /json/)
            .expect(200);

        we.expect(response.body)
            .to.have.lengthOf(1);
        we.expect(response.body[0])
            .to.include({
                platform: 'yelukerest',
                platform_compatibility_version: 1,
                schema_compatibility_version: 2,
                admin_api_version: 5,
            });
    });
});
