FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

ENV NIX_CONFIG="experimental-features = nix-command flakes"

RUN bash -lc "sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon" \
    && . /etc/profile.d/nix.sh \
    && nix --version

ENV PATH="${PATH}:/nix/var/nix/profiles/default/bin"

WORKDIR /app

COPY scripts ./scripts

ARG REMOTE_REPO_URL=https://github.com/rainlanguage/rain.orderbook
ARG REMOTE_REPO_COMMIT=07a94259de218dd58de34fe3a5289c965cf277b6

RUN git clone "$REMOTE_REPO_URL" /app/rain.orderbook
WORKDIR /app/rain.orderbook
RUN git checkout "$REMOTE_REPO_COMMIT"
RUN cp .env.example .env
RUN git submodule update --init --recursive
RUN bash ./prep-base.sh
RUN nix run .#rainix-ob-cli-artifact
RUN tar -xzf crates/cli/bin/rain-orderbook-cli.tar.gz -C /app
RUN mv /app/rain-orderbook-cli /app/rain_orderbook_cli
RUN chmod +x /app/rain_orderbook_cli

WORKDIR /app

ENV CLI_BIN=/app/rain_orderbook_cli

ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
