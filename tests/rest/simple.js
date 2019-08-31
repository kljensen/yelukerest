const {
    restService,
} = require('./common.js');

describe('root endpoint', () => {
    it('returns json', (done) => {
        restService()
            .get('/')
            .expect('Content-Type', /json/)
            .expect(200, done);
    });
});
