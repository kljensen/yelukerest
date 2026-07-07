# This is from here
# https://github.com/schickling/dockerfiles/tree/master/postgres-backup-s3
# originally. 
FROM alpine:3.24.1

COPY install.sh install.sh
RUN sh install.sh && rm install.sh

ENV POSTGRES_DATABASE=**None**
ENV POSTGRES_HOST=**None**
ENV POSTGRES_PORT=5432
ENV POSTGRES_USER=**None**
ENV POSTGRES_EXTRA_OPTS=''
ENV S3_BUCKET=**None**
ENV S3_REGION=us-east-1
ENV S3_PREFIX='backup'
ENV S3_ENDPOINT=**None**
ENV S3_S3V4=no
ENV SCHEDULE=**None**

COPY run.sh run.sh
COPY backup.sh backup.sh

CMD ["sh", "run.sh"]
