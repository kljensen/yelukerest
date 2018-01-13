#!/bin/sh
set -e
# This will watch for changes
if [ -z "$DEVELOPMENT" ]
  then
    echo "Running for production"
    npm run build
else
    echo "Running for development"
    npm run dev -- --watch
fi
# TODO: run this differently when we're in production!
# See https://github.com/elm-community/elm-webpack-starter