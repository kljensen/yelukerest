#!/bin/sh
VOLUMES=yelukerest-letsencrypt:/etc/letsencrypt
IMAGE=debian:stretch
docker run -i -v $VOLUMES $IMAGE /bin/bash <<-EOF
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openssl
    mkdir -p /etc/letsencrypt/live/localhost
    cd /etc/letsencrypt/live/localhost
    openssl req -x509 -out fullchain.pem -keyout privkey.pem -newkey rsa:2048 -nodes -sha256 -subj '/CN=localhost' -extensions EXT -config <( \\
        printf "[dn]\nCN=localhost\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=DNS:localhost\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth")
EOF