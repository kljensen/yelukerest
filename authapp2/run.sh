#!/bin/sh
if [[ -z "${DEVELOPMENT}" ]]; then
    echo "Running in production!"
else
    systemfd --no-pid -s http::0.0.0.0:${PORT} -- cargo watch -x run
fi