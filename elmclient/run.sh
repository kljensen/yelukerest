#!/bin/sh
set -e
if [ -z ${DEVELOPMENT} ]
then
    npm run build
else
    npm run build -- --watch
fi