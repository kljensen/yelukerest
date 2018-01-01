#!/bin/sh
set -e
# Watch the `src` directory for changes to files ending
# in 'js' and restart the `src/server.js` process.
./node_modules/.bin/nodemon -e js -w src -V src/server.js
