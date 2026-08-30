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

# GNU tar, not busybox's applet: npm tarballs carry file entries and no
# directory entries, and only GNU tar can extract a subtree by prefix.
RUN apk add --no-cache unzip patch tar

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
        # --no-backup-if-mismatch: without it a patch that applies at a line
        # offset leaves e.g. static/js/main.js.orig in the image, which
        # express.static then serves -- publishing the PRE-patch source, with
        # the analytics and unpkg URLs this layer exists to remove.
        patch -p1 --batch --forward --fuzz=0 --no-backup-if-mismatch < "${p}"; \
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

# Monaco and CodeMirror, the editor's two code-editing backends. Upstream loaded
# both from unpkg at runtime and Monaco's URL carried no version at all, so the
# editor -- since issue #359 the CAS-authenticated origin that holds the session
# cookie -- ran whatever unpkg called latest, with hashed filenames that were not
# even stable between page loads (issue #367).
#
# static/editor-vendor/, NOT static/vendor/: caddy's (codeframe_artifacts)
# snippet serves /static/vendor/* on the public artifact host and 404s the rest
# of /static/. Published pages need torus-dom and nothing here, so anything
# under this prefix stays private to the editor host by construction.
#
# Fetched as registry tarballs rather than file by file: Monaco's min/vs tree is
# 150-odd files whose names are content hashes, so there is no stable per-file
# list to pin. One tarball, one recorded digest.

# The version unpkg was resolving "monaco-editor" to when this was vendored
# (2026-08-30). Frozen rather than upgraded, for the same reason torus-dom was
# pinned at 0.4.8: this is the code the editor is already running in production,
# so pinning it changes nothing observable, while any other choice is an
# untested upgrade. Note monaco.KeyCode.KEY_S, which main.js still uses for the
# Ctrl/Cmd-S binding, was renamed upstream well before 0.56 -- that binding is
# already dead in production, and freezing here keeps it exactly as dead rather
# than mixing a behavior change into a supply-chain fix.
ARG MONACO_VERSION=0.56.0
ARG MONACO_SHA256=b74bc4437205c194b779b0f21e5e7fcd3b4e9acbf3f7c8732a545d2059fb7412
RUN mkdir -p static/editor-vendor/monaco && \
    wget -O /tmp/monaco.tgz \
        "https://registry.npmjs.org/monaco-editor/-/monaco-editor-${MONACO_VERSION}.tgz" && \
    echo "${MONACO_SHA256}  /tmp/monaco.tgz" | sha256sum -c - && \
    tar -xzf /tmp/monaco.tgz -C static/editor-vendor/monaco \
        --strip-components=2 package/min/vs && \
    rm /tmp/monaco.tgz && \
    test -f static/editor-vendor/monaco/vs/loader.js

# The version unpkg was resolving "codemirror@5" to on the same date. Only the
# three directories main.js loads from are kept; the package also ships an ES
# module build and every other language mode, which nothing here requests.
ARG CODEMIRROR_VERSION=5.65.21
ARG CODEMIRROR_SHA256=b26d9d7ae0f42e34b44a8f7667d29a3ab0d3df88d0e79c0dad39dc03ba43f6dc
RUN mkdir -p static/editor-vendor/codemirror && \
    wget -O /tmp/codemirror.tgz \
        "https://registry.npmjs.org/codemirror/-/codemirror-${CODEMIRROR_VERSION}.tgz" && \
    echo "${CODEMIRROR_SHA256}  /tmp/codemirror.tgz" | sha256sum -c - && \
    tar -xzf /tmp/codemirror.tgz -C static/editor-vendor/codemirror \
        --strip-components=1 package/lib package/mode package/addon && \
    rm /tmp/codemirror.tgz && \
    test -f static/editor-vendor/codemirror/lib/codemirror.js

# --frozen-lockfile, not `npm install`: upstream ships yarn.lock and no
# package-lock.json, so npm ignored the lockfile and re-resolved the whole tree
# against the registry on every build. This image serves a session-carrying
# editor, so the dependency set has to be the pinned one.
RUN yarn install --frozen-lockfile

# config.js resolves DATABASE to the relative path "db", so frames land in
# /codeframe/db. That directory is a named volume in the compose file: without
# it, a restart deletes every page a student has submitted.
#
# publish-log.jsonl lives there too -- one line per publish, naming the netid
# that made it (issue #366). It is deliberately on the same volume as the
# frames rather than in stdout or a database; see the comment on recordPublish
# in patches/0005. Read it with:
#
#   docker compose exec codeframe cat db/publish-log.jsonl
ENV PORT=4556

# Origin serving the public /f/<html>/<js>.html artifacts, stamped into the
# editor page at request time. Unset means "same origin as the editor", which
# is the single-host behavior. Set it to the public artifact host so that
# student JavaScript previewed in the editor never runs on the editor's origin.
ENV CODEFRAME_ARTIFACT_ORIGIN=""

EXPOSE 4556

ENTRYPOINT [ "npm", "start" ]
