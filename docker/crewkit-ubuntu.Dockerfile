# The Linux gate's image (tools/linux-gate.sh): ubuntu 24.04 by digest, as GitHub's
# ubuntu-latest, with the tools the suites need and an en_US.UTF-8 locale (install.bats'
# locale test skips without it, and its mutant would survive falsely).
# Build: tools/linux-gate.sh --build-images (BASE: docker/bases.txt's ubuntu digest)
ARG BASE
FROM $BASE
RUN apt-get update \
 && apt-get install -y --no-install-recommends git jq python3 util-linux procps ca-certificates xz-utils locales openssh-client \
 && sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*
