const bunTest = require('bun:test');
const superagent = require('superagent');

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

if (superagent.Request && superagent.Request.prototype.disableTLSCerts) {
    const originalEnd = superagent.Request.prototype.end;
    superagent.Request.prototype.end = function patchedEnd(...args) {
        this.disableTLSCerts();
        return originalEnd.apply(this, args);
    };
}

const wrapHook = (hook) => {
    if (hook.length === 0) {
        return hook;
    }

    return () => new Promise((resolve, reject) => {
        hook((error) => {
            if (error) {
                reject(error);
                return;
            }
            resolve();
        });
    });
};

globalThis.describe = bunTest.describe;
globalThis.it = bunTest.it;
globalThis.before = (hook) => bunTest.beforeAll(wrapHook(hook));
globalThis.after = (hook) => bunTest.afterAll(wrapHook(hook));
globalThis.beforeEach = (hook) => bunTest.beforeEach(wrapHook(hook));
globalThis.afterEach = (hook) => bunTest.afterEach(wrapHook(hook));

bunTest.setDefaultTimeout(30000);
