#!/bin/sh
# vim:set tabstop=4 expandtab shiftwidth=4 smarttab
# Source environment variables
set -a
. ./.env
set +a

docker volume create --name=yelukerest-letsencrypt || echo "Skipping creation of yelukerest-letsencrypt volume"

get_cert_with_dns_challenge() {
    docker run -it \
        -e AWS_ACCESS_KEY_ID=$CERTBOT_AWS_ACCESS_KEY_ID \
        -e AWS_SECRET_ACCESS_KEY=$CERTBOT_AWS_SECRET_ACCESS_KEY \
        -v yelukerest-letsencrypt:/etc/letsencrypt \
        certbot/dns-route53:v1.12.0 \
        certonly \
        --dns-route53 \
        --dns-route53-propagation-seconds 30 \
        -d $1
}
get_cert_with_http_challenge() {
    docker run -p 80:80 -it \
        -v yelukerest-letsencrypt:/etc/letsencrypt \
         certbot/dns-route53:v1.12.0 \
        certonly \
         --standalone \
         --preferred-challenges http \
         -d $1
}

get_cert() {
if [ -n "$CERTBOT_AWS_ACCESS_KEY_ID" ] && [ -n "$CERTBOT_AWS_SECRET_ACCESS_KEY" ]; then
    get_cert_with_dns_challenge $1
else
    get_cert_with_http_challenge $1
fi
}

for domain in "$NAKED_FQDN" "$FDQN" "$1"
do
    if [ -n "$domain" ]; then
        get_cert $domain
    fi
done

