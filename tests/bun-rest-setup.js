const bunTest = require('bun:test');

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
