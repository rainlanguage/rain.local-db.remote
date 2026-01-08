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
COPY flake.nix flake.lock ./

ARG REMOTE_REPO_URL=https://github.com/rainlanguage/rain.orderbook
ARG REMOTE_REPO_COMMIT=bb325657ded8d78966e71aac0d500ad1dcdb84a3

RUN git clone "$REMOTE_REPO_URL" /app/rain.orderbook
WORKDIR /app/rain.orderbook
RUN git checkout "$REMOTE_REPO_COMMIT"
RUN cp .env.example .env
RUN git submodule update --init --recursive
RUN bash ./prep-base.sh
RUN nix develop -c rainix-ob-cli-artifact
RUN tar -xzf crates/cli/bin/rain-orderbook-cli.tar.gz -C /app
RUN chmod +x /app/rain-orderbook-cli

WORKDIR /app

ENTRYPOINT ["nix", "run", ".#local-db-pipeline"]
