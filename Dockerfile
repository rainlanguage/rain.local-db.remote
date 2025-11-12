FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        findutils \
        gzip \
        tar \
        awscli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY scripts ./scripts

ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
