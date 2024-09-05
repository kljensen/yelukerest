FROM rust:1.80.1-slim-bookworm AS builder

WORKDIR /usr/src/pg-amqp-bridge
COPY . .
RUN cargo install --path .


FROM debian:bookworm-slim

COPY --from=builder /usr/local/cargo/bin/pg-amqp-bridge /usr/local/bin/pg-amqp-bridge


CMD ["pg-amqp-bridge"]
