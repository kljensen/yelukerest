#!/bin/sh
# Source environment variables
set -a
. ./.env
set +a

docker run -p 80:80 -it \
	-v yelukerest-letsencrypt:/etc/letsencrypt \
	certbot/certbot \
	certonly \
	 --standalone \
	 --preferred-challenges http \
	 -d $FQDN
