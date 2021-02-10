#!/usr/bin/env sh

if [ "$#" -ne 1 ] ; then
  echo "Usage: $0 JSON" >&2
  exit 1
fi

# Source environment variables
set -a
. ./.env
set +a

# Run the node script for creating a jwt
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

create_openssl_jwt() {
    # From
    # https://stackoverflow.com/questions/59002949/how-to-create-a-json-web-token-jwt-using-openssl-shell-commands

    # Construct the header
    jwt_header=$(printf "%s" '{"alg":"HS256","typ":"JWT"}' | base64 | sed s/\+/-/g | sed 's/\//_/g' | sed -E s/=+$//)

    # Construct the payload
    payload=$(printf "%s" "$@" | base64 | sed s/\+/-/g |sed 's/\//_/g' |  sed -E s/=+$//)

    # Convert secret to hex (not base64)
    hexsecret=$(printf "%s" "$JWT_SECRET" | xxd -p | tr -d '\n')

    # Calculate hmac signature -- note option to pass in the key as hex bytes
    hmac_signature=$(printf "%s" "${jwt_header}.${payload}" |  openssl dgst -sha256 -mac HMAC -macopt hexkey:$hexsecret -binary | base64  | sed s/\+/-/g | sed 's/\//_/g' | sed -E s/=+$//)

    # Create the full token
    jwt="${jwt_header}.${payload}.${hmac_signature}"
    printf "%s\n" "$jwt"
}


# Try https://github.com/mike-engel/jwt-cli, then openssl, then nodejs
# Note that jwt-cli will add an exp automatically. I'm only using this
# script for JWTs with no expiration, so I'm setting a long, 5 year expiration.
jwt encode --secret=$JWT_SECRET --exp "5 years" "$@" || \
    create_openssl_jwt "$@" || \
    node $dir/_jwt.js "$@" 
