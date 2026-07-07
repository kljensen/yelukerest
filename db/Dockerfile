FROM postgres:18.4-alpine3.24 AS base

RUN apk add --no-cache pgbackrest

COPY pgbackrest-archive-push.sh /usr/local/bin/pgbackrest-archive-push.sh
RUN chmod 755 /usr/local/bin/pgbackrest-archive-push.sh

FROM base AS prod

FROM base AS dev

ENV PGTAP_VERSION=1.3.4

RUN set -eux; \
    apk add --no-cache --virtual .pgtap-build-deps build-base curl perl tar; \
    curl -fsSL -o /tmp/pgtap.tar.gz "https://github.com/theory/pgtap/archive/refs/tags/v${PGTAP_VERSION}.tar.gz"; \
    mkdir -p /tmp/pgtap; \
    tar -xzf /tmp/pgtap.tar.gz -C /tmp/pgtap --strip-components=1; \
    make -C /tmp/pgtap; \
    make -C /tmp/pgtap install; \
    rm -rf /tmp/pgtap /tmp/pgtap.tar.gz; \
    apk del .pgtap-build-deps
