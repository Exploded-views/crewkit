# The registry holder image (docs/holder.md): the crewkit tree, ntfy and tailscale from their
# pinned releases, and the tools the entrypoint needs. No agent CLI, no herdr. It runs as a
# non-root user and holds no secret: the keys and tokens are mounted at run time.
#
# Build with tools/holder-image-build.sh, which passes the pins in as build arguments; the
# arguments have no defaults, so a bare `docker build` fails closed.
FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3

ARG TARGETARCH
ARG NTFY_URL
ARG NTFY_TAG
ARG NTFY_SHA256_linux_amd64
ARG NTFY_SHA256_linux_arm64
ARG TAILSCALE_URL
ARG TAILSCALE_TAG
ARG TAILSCALE_SHA256_linux_amd64
ARG TAILSCALE_SHA256_linux_arm64

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq openssh-client tini \
 && rm -rf /var/lib/apt/lists/*

# Each download is checked against the sha256 in pins/ (computed from the published file).
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) ntfy_sha=$NTFY_SHA256_linux_amd64; ts_sha=$TAILSCALE_SHA256_linux_amd64 ;; \
      arm64) ntfy_sha=$NTFY_SHA256_linux_arm64; ts_sha=$TAILSCALE_SHA256_linux_arm64 ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    ntfy_v=${NTFY_TAG#v}; ts_v=${TAILSCALE_TAG#v}; \
    mkdir /opt/dl; cd /opt/dl; \
    curl -fsSL --proto '=https' --tlsv1.2 -o ntfy.tgz "$NTFY_URL/$NTFY_TAG/ntfy_${ntfy_v}_linux_${TARGETARCH}.tar.gz"; \
    echo "$ntfy_sha  ntfy.tgz" | sha256sum -c -; \
    tar -xzf ntfy.tgz "ntfy_${ntfy_v}_linux_${TARGETARCH}/ntfy"; \
    install -m 755 "ntfy_${ntfy_v}_linux_${TARGETARCH}/ntfy" /usr/local/bin/ntfy; \
    curl -fsSL --proto '=https' --tlsv1.2 -o ts.tgz "$TAILSCALE_URL/tailscale_${ts_v}_${TARGETARCH}.tgz"; \
    echo "$ts_sha  ts.tgz" | sha256sum -c -; \
    tar -xzf ts.tgz "tailscale_${ts_v}_${TARGETARCH}/tailscale" "tailscale_${ts_v}_${TARGETARCH}/tailscaled"; \
    install -m 755 "tailscale_${ts_v}_${TARGETARCH}/tailscale" "tailscale_${ts_v}_${TARGETARCH}/tailscaled" /usr/local/bin/; \
    cd /; rm -rf /opt/dl

RUN useradd --create-home --uid 10001 crewkit \
 && install -d -o crewkit -g crewkit -m 700 /var/lib/crewkit-holder

# The crewkit tree (holder/Dockerfile.dockerignore keeps everything else out of the context).
COPY bin /opt/crewkit/bin
COPY libexec /opt/crewkit/libexec
COPY lib /opt/crewkit/lib
COPY templates /opt/crewkit/templates
COPY holder/ntfy-server.yml /opt/crewkit/holder/ntfy-server.yml

USER crewkit
ENV CK_ROOT=/opt/crewkit \
    CK_HOLDER_STATE=/var/lib/crewkit-holder \
    CK_SECRETS_DIR=/run/secrets
# tini is PID 1: it reaps what the entrypoint's children leave behind and passes signals on.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/crewkit/libexec/crewkit-holder-run"]
