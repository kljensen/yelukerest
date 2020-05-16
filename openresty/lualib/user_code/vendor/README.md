
This directory contains dependencies for some of the
lua code. There is an `update.sh` shell script that
downloads the dependencies. I chose to write a shell
script instead of using OPM (the openresty package
manager) or luarocks because I didn't want to write
a custom Dockerfile for OpenResty. OPM requires an
installation of Perl and the openresty "fat" docker
images are over 2x the normal size.

To update the dependences to newer versions, update.sh
will need to be updated and run.
