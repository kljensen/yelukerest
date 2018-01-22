FROM alpine:3.7
ENV LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    LANGUAGE="en_US.UTF-8" \
    TERM="xterm"

EXPOSE 8080

RUN apk -U upgrade  && \
    apk --update add \
    bash bash-completion bash-doc \
    curl \
    man \
    tar \
    tmux \
    vim \
    jq \
    musl-dev \
    go \
    git && \
    # Install gotty
    mkdir -p /tmp/gotty && \
    GOPATH=/tmp/gotty go get github.com/yudai/gotty && \
    mv /tmp/gotty/bin/gotty /usr/local/bin/ && \
    apk del go git && \
    rm -rf /tmp/gotty /var/cache/apk/* && \
    # Create faculty user
    addgroup -S faculty && \
    adduser -S -s /bin/bash -g faculty faculty

ADD dot-gotty /home/faculty/.gotty
ADD dot-tmux.conf /home/faculty/.tmux.conf
ADD dot-bashrc /home/faculty/.bashrc



CMD exec /bin/bash -c "trap : TERM INT; while sleep 3600; do :; done"