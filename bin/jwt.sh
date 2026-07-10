#!/usr/bin/env sh

if [ "$#" -ne 1 ] ; then
  echo "Usage: $0 JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1 ; then
  echo "jq is required to add standard JWT claims" >&2
  exit 1
fi

# Source environment variables
set -a
. ./.env
set +a

JWT_ISSUER="${JWT_ISSUER:-yelukerest}"
JWT_AUDIENCE="${JWT_AUDIENCE:-yelukerest-postgrest}"
NOW_EPOCH="$(date +%s)"
JWT_ID="$( (uuidgen 2>/dev/null || openssl rand -hex 16) | tr '[:upper:]' '[:lower:]' )"

payload="$(printf "%s" "$1" | jq -c \
    --arg iss "$JWT_ISSUER" \
    --arg aud "$JWT_AUDIENCE" \
    --argjson now "$NOW_EPOCH" \
    --arg jti "$JWT_ID" \
    '
    . + {
        iss: (.iss // $iss),
        aud: (.aud // $aud),
        iat: (.iat // $now),
        nbf: (.nbf // $now),
        exp: (.exp // ($now + 157680000)),
        jti: (.jti // $jti)
    }
    | . + {
        sub: (
            .sub //
            if .user_id then
                "user:" + (.user_id | tostring)
            elif .app_name then
                "app:" + .app_name
            else
                "role:" + (.role // "unknown")
            end
        )
    }
    ')"

create_openssl_jwt() {
    # From
    # https://stackoverflow.com/questions/59002949/how-to-create-a-json-web-token-jwt-using-openssl-shell-commands

    # Construct the header
    jwt_header=$(printf "%s" '{"alg":"HS256","typ":"JWT"}' | base64 | sed s/\+/-/g | sed 's/\//_/g' | sed -E s/=+$//)

    # Construct the payload
    payload=$(printf "%s" "$payload" | base64 | sed s/\+/-/g |sed 's/\//_/g' |  sed -E s/=+$//)

    # Convert secret to hex (not base64)
    hexsecret=$(printf "%s" "$JWT_SECRET" | xxd -p | tr -d '\n')

    # Calculate hmac signature -- note option to pass in the key as hex bytes
    hmac_signature=$(printf "%s" "${jwt_header}.${payload}" |  openssl dgst -sha256 -mac HMAC -macopt hexkey:$hexsecret -binary | base64  | sed s/\+/-/g | sed 's/\//_/g' | sed -E s/=+$//)

    # Create the full token
    jwt="${jwt_header}.${payload}.${hmac_signature}"
    printf "%s\n" "$jwt"
}


# Try https://github.com/mike-engel/jwt-cli, then openssl.
jwt encode --secret=$JWT_SECRET "$payload" || \
    create_openssl_jwt
