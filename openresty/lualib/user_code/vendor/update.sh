#!/bin/sh
echo "Updating vendored lua dependencies"

# Exit on error
set -e

GITHUB_URL="https://github.com"
DOWNLOAD="curl -L -O"

# The location of this script
MY_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_DIR=`mktemp -d -t 'yeluke-lua-vendor-update'`
echo "Created tmp dir: $TMP_DIR"

cd $TMP_DIR

# https://github.com/ledgetech/lua-resty-http/releases
RESTY_HTTP_RELEASE_NUMBER="0.15"
RESTY_HTTP_RELEASE="v$RESTY_HTTP_RELEASE_NUMBER"
RESTY_HTTP_URL="$GITHUB_URL/ledgetech/lua-resty-http"

# https://github.com/bungle/lua-resty-session/releases
RESTY_SESSION_RELEASE_NUMBER="3.4"
RESTY_SESSION_RELEASE="v$RESTY_SESSION_RELEASE_NUMBER"
RESTY_SESSION_URL="$GITHUB_URL/bungle/lua-resty-session"

$DOWNLOAD "$RESTY_HTTP_URL/archive/$RESTY_HTTP_RELEASE.tar.gz"
# e.g. https://github.com/bungle/lua-resty-session/archive/v3.4.tar.gz
tar -zxvf $RESTY_HTTP_RELEASE.tar.gz

$DOWNLOAD "$RESTY_SESSION_URL/archive/$RESTY_SESSION_RELEASE.tar.gz"
# e.gc. https://github.com/bungle/lua-resty-session/archive/v3.4.tar.gz
tar -zxvf $RESTY_SESSION_RELEASE.tar.gz

cd $MY_DIR
cp -r $TMP_DIR/lua-resty-http-$RESTY_HTTP_RELEASE_NUMBER/lib lua-resty-http
cp -r $TMP_DIR/lua-resty-session-$RESTY_SESSION_RELEASE_NUMBER/lib lua-resty-session

echo "Removing tmp dir: $TMP_DIR"
rm -rf $TMP_DIR
exit