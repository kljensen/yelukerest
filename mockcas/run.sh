#!/bin/sh
set -e
echo "Development = ${DEVELOPMENT}"
if [ -z "${DEVELOPMENT}" ]
then
    echo "Not in development mode, so not starting mock CAS server";
    exit 0;
else
    echo "Starting mock CAS server";
    ./node_modules/.bin/nodemon -e js,pug -V ./src/index.js
fi
