#!/bin/sh
set -e
npm install
./node_modules/.bin/nodemon -e html,js,css,json ./server.js