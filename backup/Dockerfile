FROM alpine:3.24.1

COPY install.sh install.sh
RUN sh install.sh && rm install.sh

ENV POSTGRES_DATA_PATH=/var/lib/postgresql/18/docker
ENV POSTGRES_PORT=5432
ENV POSTGRES_SOCKET_PATH=/var/run/postgresql
ENV POSTGRES_USER=**None**
ENV PGBACKREST_STANZA=yelukerest
# How stale the newest full backup may be before backup.sh takes a full instead
# of an incremental. Weekly keeps at least two independent full backups alive
# under repo1-retention-full=2 for a database whose full compresses to a few MB.
ENV BACKUP_FULL_INTERVAL_DAYS=7
ENV PGBACKREST_REPO1_PATH=/pgbackrest
ENV PGBACKREST_REPO1_RETENTION_FULL=2
ENV PGBACKREST_REPO1_TYPE=s3
ENV PGBACKREST_REPO1_S3_URI_STYLE=host
ENV PGBACKREST_REPO1_STORAGE_PORT=443
ENV PGBACKREST_REPO1_STORAGE_VERIFY_TLS=y
# Where docker-compose.prod.yaml mounts the codeframe_db volume, read-only.
# The pages students publish there are graded artifacts and pgBackRest does not
# cover them (issue #369); backup.sh copies this directory to S3 after each
# database backup.
ENV CODEFRAME_DATA_PATH=/codeframe/db
# Archives kept in S3. Only changed contents are uploaded, so this counts
# distinct states of the volume, not scheduled runs.
ENV CODEFRAME_RETAIN=14
ENV S3_BUCKET=**None**
ENV S3_ENDPOINT=**None**
ENV S3_PREFIX=pgbackrest
ENV S3_REGION=us-east-1
ENV SCHEDULE=**None**

COPY run.sh run.sh
COPY backup.sh backup.sh
COPY codeframe.sh /codeframe.sh

CMD ["sh", "run.sh"]
