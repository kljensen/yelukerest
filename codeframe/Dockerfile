# codeframe: a browser editor that hosts what a student writes.
#
# Used by the "tacky website" activity, where the deliverable is a URL rather
# than a repository. Students write HTML/CSS/JS in the browser and submit the
# page it is served at, which is why this has to keep running after the class:
# submitted URLs are the graded artifact, and they resolve here.
#
# Pinned to an upstream commit rather than a tag because codeframe publishes no
# releases and no images. The URL shape it serves -- /f/<frame>/<hash>.html --
# is what the 2025 submissions recorded, so changing versions casually would
# break links that already exist.
FROM node:22.8.0-alpine3.19

RUN apk add --no-cache unzip

ARG CODEFRAME_COMMIT=4c44fbb5a0e0bde45983b663db9e893fe3c73ea8
RUN wget "https://github.com/thesephist/codeframe/archive/${CODEFRAME_COMMIT}.zip" && \
    unzip "${CODEFRAME_COMMIT}.zip" && \
    rm "${CODEFRAME_COMMIT}.zip" && \
    mv "codeframe-${CODEFRAME_COMMIT}" codeframe

WORKDIR /codeframe
RUN npm install

# config.js resolves DATABASE to the relative path "db", so frames land in
# /codeframe/db. That directory is a named volume in the compose file: without
# it, a restart deletes every page a student has submitted.
ENV PORT=4556
EXPOSE 4556

ENTRYPOINT [ "npm", "start" ]
