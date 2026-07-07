FROM debian:trixie-slim

# Install Elm and elm-test-rs binaries dynamically based on architecture.
ENV ELM_VERSION=0.19.2
ENV ELM_TEST_RS_VERSION=3.1.0

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gzip inotify-tools jq nodejs tar; \
    rm -rf /var/lib/apt/lists/*; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        'amd64') \
            ELM_ARCH='x64'; \
            ELM_TEST_RS_ARCH='linux' \
            ;; \
        'arm64') \
            ELM_ARCH='arm'; \
            ELM_TEST_RS_ARCH='linux-arm-64' \
            ;; \
        *) \
            echo "Unsupported architecture: $arch"; \
            exit 1 \
            ;; \
    esac; \
    curl -fsSL -o elm.gz "https://github.com/elm/compiler/releases/download/${ELM_VERSION}/elm-${ELM_VERSION}-linux-${ELM_ARCH}.gz" \
    && gunzip elm.gz \
    && chmod a+x elm \
    && mv elm /usr/local/bin; \
    curl -fsSL -o elm-test-rs.tar.gz "https://github.com/mpizenberg/elm-test-rs/releases/download/v${ELM_TEST_RS_VERSION}/elm-test-rs_${ELM_TEST_RS_ARCH}.tar.gz" \
    && tar -xzf elm-test-rs.tar.gz \
    && chmod a+x elm-test-rs \
    && mv elm-test-rs /usr/local/bin \
    && rm elm-test-rs.tar.gz

RUN mkdir -p /opt/app
ADD elm.json /opt/app/elm.json
ADD build.sh /opt/app/build.sh
ADD run.sh /opt/app/run.sh
ADD src /opt/app/src
ADD tests /opt/app/tests

WORKDIR /opt/app
RUN mkdir -p dist && elm make src/elm/Main.elm --optimize --output=/tmp/main.js && rm /tmp/main.js
