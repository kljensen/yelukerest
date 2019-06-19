# Custom docker file to make our builds a little more effocient.
# We want to ensure the node_modules and elm_stuff are cached.
# Otherwise, this Dockerfile is just the same the official node
# Docker image https://hub.docker.com/_/node/. Of course, 
FROM node:10.16.0-stretch

RUN mkdir -p /opt/app
ADD package.json /opt/app/package.json
ADD package-lock.json /opt/app/package-lock.json
ADD elm.json /opt/app/elm.json
ADD postcss.config.js /opt/app/postcss.config.js
RUN cd /opt/app && npm run reinstall