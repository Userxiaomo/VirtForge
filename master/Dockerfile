FROM rust:1.88-bookworm AS builder

WORKDIR /app

COPY Cargo.toml Cargo.lock ./
COPY shared ./shared
COPY agent ./agent
COPY master ./master
COPY scripts ./scripts

RUN cargo build --release -p vps-master --bin vps-master

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --create-home --shell /usr/sbin/nologin vps

COPY --from=builder /app/target/release/vps-master /usr/local/bin/vps-master

USER vps
EXPOSE 8080

ENV MASTER_HTTP_BIND=0.0.0.0:8080
ENTRYPOINT ["/usr/local/bin/vps-master"]
