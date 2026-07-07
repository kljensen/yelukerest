ARG ELM_TOOLS_IMAGE=ghcr.io/kljensen/docker-elm-dev-static:0.19.2@sha256:2f73527ba7e6ab55e37a9e6b9960caa5a4a658b40fd346824baa1a13933ee840
ARG DENO_IMAGE=denoland/deno:alpine-1.46.3@sha256:25bd4946f68c643ba7ce2428a13673ea5fd7123fd868ee36caa60e76607ce0d5

FROM ${ELM_TOOLS_IMAGE} AS elm_tools
FROM ${DENO_IMAGE} AS deno_tools
FROM alpine:3.24.1 AS base

RUN apk add --no-cache ca-certificates gzip inotify-tools jq

COPY --from=elm_tools /usr/local/bin/elm /usr/local/bin/elm
COPY --from=elm_tools /usr/local/bin/elm-format /usr/local/bin/elm-format
COPY --from=elm_tools /usr/local/bin/elm-test-rs /usr/local/bin/elm-test-rs
COPY --from=elm_tools /usr/local/bin/esbuild /usr/local/bin/esbuild

RUN mkdir -p /opt/app
COPY elm.json /opt/app/elm.json
COPY build.sh /opt/app/build.sh
COPY run.sh /opt/app/run.sh
COPY deno-elm-test-rs.sh /opt/app/deno-elm-test-rs.sh
COPY src /opt/app/src
COPY tests /opt/app/tests

WORKDIR /opt/app
RUN mkdir -p dist && elm make src/elm/Main.elm --optimize --output=/tmp/main.js && rm /tmp/main.js

FROM base AS test
COPY --from=deno_tools /bin/deno /usr/local/bin/deno-real
COPY --from=deno_tools /usr/local/lib/ /usr/local/lib/
COPY --from=deno_tools /lib/ld-linux-* /lib/
RUN cp /opt/app/deno-elm-test-rs.sh /usr/local/bin/deno && chmod 755 /usr/local/bin/deno
ENV LD_LIBRARY_PATH=/usr/local/lib
RUN deno --version

FROM base AS app
