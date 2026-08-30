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
#
# Upstream is unmaintained, so local changes live as a patch layer applied at
# build time rather than as a fork. See patches/ for what each one is for.
FROM node:22.8.0-alpine3.19

RUN apk add --no-cache unzip patch

ARG CODEFRAME_COMMIT=4c44fbb5a0e0bde45983b663db9e893fe3c73ea8
RUN wget "https://github.com/thesephist/codeframe/archive/${CODEFRAME_COMMIT}.zip" && \
    unzip "${CODEFRAME_COMMIT}.zip" && \
    rm "${CODEFRAME_COMMIT}.zip" && \
    mv "codeframe-${CODEFRAME_COMMIT}" codeframe

WORKDIR /codeframe

# The patches are context-sensitive diffs against the pinned commit above. They
# are applied without fuzz so that a bumped CODEFRAME_COMMIT fails the build
# instead of silently landing a patch in the wrong place.
COPY patches/ /patches/
RUN set -e; \
    for p in /patches/*.patch; do \
        echo "applying ${p}"; \
        patch -p1 --batch --forward --fuzz=0 < "${p}"; \
    done

# torus-dom is the only runtime dependency of a rendered student page. Upstream
# loaded it from unpkg with no version in the URL, so every page got whatever
# was latest at request time, and a submitted page stopped rendering whenever
# unpkg was unreachable. Vendored instead, at the version unpkg happened to be
# serving, so old submissions keep rendering exactly as they were graded.
#
# torus-dom 0.4.8, dist/index.min.js
# sha256 154abdcff041eb1da230fdb9118f2f7e991a256b5d8e3f5c68ba2ac5463fcb2d
ARG TORUS_DOM_VERSION=0.4.8
ARG TORUS_DOM_SHA256=154abdcff041eb1da230fdb9118f2f7e991a256b5d8e3f5c68ba2ac5463fcb2d
RUN mkdir -p static/vendor && \
    wget -O static/vendor/torus-dom.min.js \
        "https://unpkg.com/torus-dom@${TORUS_DOM_VERSION}/dist/index.min.js" && \
    echo "${TORUS_DOM_SHA256}  static/vendor/torus-dom.min.js" | sha256sum -c -

# --frozen-lockfile, not `npm install`: upstream ships yarn.lock and no
# package-lock.json, so npm ignored the lockfile and re-resolved the whole tree
# against the registry on every build. This image serves a session-carrying
# editor, so the dependency set has to be the pinned one.
RUN yarn install --frozen-lockfile

# config.js resolves DATABASE to the relative path "db", so frames land in
# /codeframe/db. That directory is a named volume in the compose file: without
# it, a restart deletes every page a student has submitted.
ENV PORT=4556

# Origin serving the public /f/<html>/<js>.html artifacts, stamped into the
# editor page at request time. Unset means "same origin as the editor", which
# is the single-host behavior. Set it to the public artifact host so that
# student JavaScript previewed in the editor never runs on the editor's origin.
ENV CODEFRAME_ARTIFACT_ORIGIN=""

EXPOSE 4556

ENTRYPOINT [ "npm", "start" ]
