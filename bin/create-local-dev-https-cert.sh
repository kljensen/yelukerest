#!/bin/sh

# Source environment variables
set -a
. ./.env
set +a

VOLUMES=yelukerest-letsencrypt:/etc/letsencrypt
IMAGE=debian:stretch

make_cert() {
    domain=$1
    printf "%s\n" "Making cert for domain $domain"
    docker run -i -v $VOLUMES $IMAGE /bin/bash <<-EOF
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y openssl
        mkdir -p /etc/letsencrypt/live/$domain
        cd /etc/letsencrypt/live/$domain
        openssl req -x509 -out fullchain.pem -keyout privkey.pem -newkey rsa:2048 -nodes -sha256 -subj '/CN=$domain' -extensions EXT -config <( \\
            printf "[dn]\nCN=$domain\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=DNS:$domain\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth")
EOF
}

for domain in "$NAKED_FQDN" "$FQDN" "$1"
do
   if [ -n "$domain" ]; then
       make_cert $domain
   fi
done

