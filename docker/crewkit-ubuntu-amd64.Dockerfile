# The Linux gate's coverage.py image: linux/amd64, because the pinned coverage wheel
# (tools/requirements-coverage.txt) is the cp312 manylinux x86_64 build.
# Build: tools/linux-gate.sh --build-images (BASE: docker/bases.txt's ubuntu digest)
ARG BASE
FROM --platform=linux/amd64 $BASE
RUN apt-get update \
 && apt-get install -y --no-install-recommends git jq python3 python3-venv util-linux procps ca-certificates openssh-client \
 && rm -rf /var/lib/apt/lists/*
