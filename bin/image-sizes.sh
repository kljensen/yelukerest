#!/bin/sh

set -eu

default_images="
yelukerest-authapp:latest
yelukerest-backup:latest
yelukerest-caddy:latest
yelukerest-elmclient:latest
yelukerest-elmclient-test:latest
yelukerest-postgres:18.4-pgbackrest
yelukerest-postgres-dev:18.4-pgtap
postgrest/postgrest:v14.14
"

if [ "$#" -gt 0 ]; then
    images="$*"
else
    images=${IMAGES:-$default_images}
fi

printf "%-42s %14s %10s\n" "IMAGE" "BYTES" "MIB"
printf "%-42s %14s %10s\n" "-----" "-----" "---"

for image in $images; do
    if size=$(docker image inspect "$image" --format '{{.Size}}' 2>/dev/null); then
        mib=$(awk "BEGIN { printf \"%.1f\", $size / 1024 / 1024 }")
        printf "%-42s %14s %10s\n" "$image" "$size" "$mib"
    else
        printf "%-42s %14s %10s\n" "$image" "missing" "-"
    fi
done
