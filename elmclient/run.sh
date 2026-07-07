#!/bin/sh
set -e

if [ -z "${COURSE_TITLE:-}" ]
then
    echo "You should set the COURSE_TITLE environment variable"
fi

if [ -z "${DEVELOPMENT:-}" ]
then
    sh /opt/app/build.sh
else
    sh /opt/app/build.sh
    while inotifywait -r -e modify,create,delete,move src elm.json
    do
        sh /opt/app/build.sh
    done
fi
