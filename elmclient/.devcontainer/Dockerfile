ARG ELM_TOOLS_IMAGE=ghcr.io/kljensen/docker-elm-dev-static:0.19.2@sha256:2f73527ba7e6ab55e37a9e6b9960caa5a4a658b40fd346824baa1a13933ee840

FROM ${ELM_TOOLS_IMAGE} AS elm_tools
FROM alpine:3.24.1

RUN apk add --no-cache bash ca-certificates git gzip inotify-tools jq nodejs

COPY --from=elm_tools /usr/local/bin/elm /usr/local/bin/elm
COPY --from=elm_tools /usr/local/bin/elm-format /usr/local/bin/elm-format
COPY --from=elm_tools /usr/local/bin/elm-test-rs /usr/local/bin/elm-test-rs
COPY --from=elm_tools /usr/local/bin/esbuild /usr/local/bin/esbuild

ARG USERNAME=elm
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN addgroup -g "$USER_GID" "$USERNAME" \
    && adduser -D -u "$USER_UID" -G "$USERNAME" -s /bin/bash "$USERNAME"
