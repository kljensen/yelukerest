ARG ELM_TOOLS_IMAGE=ghcr.io/kljensen/docker-elm-dev-static:0.19.2@sha256:2f73527ba7e6ab55e37a9e6b9960caa5a4a658b40fd346824baa1a13933ee840

FROM ${ELM_TOOLS_IMAGE} AS elm_tools
FROM alpine:3.24.1 AS base

RUN apk add --no-cache ca-certificates gzip inotify-tools jq

COPY --from=elm_tools /usr/local/bin/elm /usr/local/bin/elm
COPY --from=elm_tools /usr/local/bin/elm-format /usr/local/bin/elm-format
COPY --from=elm_tools /usr/local/bin/elm-test-rs /usr/local/bin/elm-test-rs
COPY --from=elm_tools /usr/local/bin/esbuild /usr/local/bin/esbuild

RUN mkdir -p /opt/app
ADD elm.json /opt/app/elm.json
ADD build.sh /opt/app/build.sh
ADD run.sh /opt/app/run.sh
ADD src /opt/app/src
ADD tests /opt/app/tests

WORKDIR /opt/app
RUN mkdir -p dist && elm make src/elm/Main.elm --optimize --output=/tmp/main.js && rm /tmp/main.js

FROM base AS test
RUN apk add --no-cache nodejs

FROM base AS app
