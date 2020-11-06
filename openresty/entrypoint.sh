#!/bin/sh
set -e

# nginx cannot use domain names to connect to upstread services but
# instead needs IP addresses (unless you provide a resolver). Instead,
# I'm going to overwrite each domain (host) with its IP address by looking
# it up with getent once. Obviously then, these can't change! We do this
# once on startup.
DB_HOST=`getent hosts $DB_HOST | awk '{ print $1 }'`
POSTGREST_HOST=`getent hosts $POSTGREST_HOST | awk '{ print $1 }'`
SSE_HOST=`getent hosts $SSE_HOST | awk '{ print $1 }'`
SHAREDTERMINAL_HOST=`getent hosts $SHAREDTERMINAL_HOST | awk '{ print $1 }'`
ELMCLIENT_HOST=`getent hosts $ELMCLIENT_HOST | awk '{ print $1 }'`
CERTBOT_HOST=`getent hosts $CERTBOT_HOST | awk '{ print $1 }'`

# If we're in development, we're going to load some
# extra nginx locations, e.g. a mockcas server.
#
if [ -z "${DEVELOPMENT}" ]
then
    export NGINX_HTTP_DEV_INCLUDES=""
    export NGINX_SERVER_DEV_INCLUDES=""
else
    export NGINX_HTTP_DEV_INCLUDES="include includes/dev/http/*.conf;"
    export NGINX_SERVER_DEV_INCLUDES="include includes/dev/http/server/*.conf;"
fi

env_vars='$NGINX_HTTP_DEV_INCLUDES$NGINX_SERVER_DEV_INCLUDES$FQDN$OPENRESTY_DEVELOPMENT$OPENRESTY_CACHE_BYPASS$REDIS_PASSWORD$OPENRESTY_SESSION_SECRET'
envsubst $env_vars </usr/local/openresty/nginx/conf/nginx.conf.tmpl |tee /usr/local/openresty/nginx/conf/nginx.conf

(
old_hash=$(find /etc/letsencrypt/live/ -type f,l  -print0 -exec sha1sum "{}" \;|sha1sum -|cut -f1 -d' ')
while true
do
    sleep 10
    new_hash=$(find /etc/letsencrypt/live/ -type f,l  -print0 -exec sha1sum "{}" \;|sha1sum -|cut -f1 -d' ')
    if [ "$new_hash" != "$old_hash" ]; then
        echo "Detected change in letsencrypt directory. Reloading openresty."
        old_hash="$new_hash"
        /usr/local/openresty/bin/openresty -s reload
    fi
done
)&

exec /usr/local/openresty/bin/openresty -g "daemon off; error_log /dev/stderr info;"
