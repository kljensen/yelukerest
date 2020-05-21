# Custom docker file to make our builds a little more effocient.
# We want to ensure the node_modules and elm_stuff are cached.
# Otherwise, this Dockerfile is just the same the official node
# Docker image https://hub.docker.com/_/node/. Of course, 
FROM node:12.16.3-stretch

# Install the elm binary
RUN \
    curl -L -o elm.gz https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz \
    && gunzip elm.gz \
    && chmod a+x elm \
    && mv elm /usr/local/bin

RUN mkdir -p /opt/app
ADD package.json /opt/app/package.json
ADD package-lock.json /opt/app/package-lock.json
ADD elm.json /opt/app/elm.json
ADD postcss.config.js /opt/app/postcss.config.js
RUN cd /opt/app && \
    rm -rf node_modules && \
    npm install && \
    mkdir -p src/elm dist && \
    elm make; true