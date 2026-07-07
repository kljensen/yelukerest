#!/bin/sh

# Source environment variables
set -a
. ./.env
set +a

VOLUMES=yelukerest-letsencrypt:/etc/letsencrypt
IMAGE=alpine:3.24.1

make_cert() {
    domain=$1
    printf "%s\n" "Making cert for domain $domain"
    docker run -i -e CERT_DOMAIN="$domain" -v "$VOLUMES" "$IMAGE" /bin/sh <<-'EOF'
        apk add --no-cache openssl
        mkdir -p "/etc/letsencrypt/live/$CERT_DOMAIN"
        cd "/etc/letsencrypt/live/$CERT_DOMAIN"
        cat > /tmp/openssl.cnf <<OPENSSL_CONFIG
[dn]
CN=$CERT_DOMAIN
[req]
distinguished_name = dn
[EXT]
subjectAltName=DNS:$CERT_DOMAIN
keyUsage=digitalSignature
extendedKeyUsage=serverAuth
OPENSSL_CONFIG
        openssl req -x509 -out fullchain.pem -keyout privkey.pem -newkey rsa:2048 -nodes -sha256 -subj "/CN=$CERT_DOMAIN" -extensions EXT -config /tmp/openssl.cnf
EOF
}

for domain in "$NAKED_FQDN" "$FQDN" "$1"
do
   if [ -n "$domain" ]; then
       make_cert $domain
   fi
done
