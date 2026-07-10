FROM postgres:18.4-alpine3.24 AS base

RUN apk add --no-cache pgbackrest

COPY pgbackrest-archive-push.sh /usr/local/bin/pgbackrest-archive-push.sh
RUN chmod 755 /usr/local/bin/pgbackrest-archive-push.sh

FROM base AS prod
