#!/bin/sh
set -e

if [ -z ${COURSE_TITLE} ]
then
    echo "You must set the COURSE_TITLE environment variable"
fi

if [ -z ${DEVELOPMENT} ]
then
    npm run build
else
    npm run build -- --watch
fi