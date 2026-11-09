# kcov with git, jq, procps and openssh-client, which the plugin suites need (the pinned kcov image, Debian 12, has
# none of them; bats enforces BATS_TEST_TIMEOUT with ps). BASE is tools/coverage.sh --pinned-image.
# Packages come from a dated snapshot of the Debian archive, so the build is the same every run; apt checks the archive signatures.
# Each apt-get retries a failed fetch (5 times) and gives each fetch 30 seconds, so a stalled or overloaded mirror
# (snapshot.debian.org did both, three runs in a row) fails fast and retries instead of using up the job's limit.
# Built by CI's coverage job and by tools/linux-gate.sh --build-images.
ARG BASE
FROM $BASE
RUN rm -f /etc/apt/sources.list.d/* \
 && echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/20260401T000000Z bookworm main' > /etc/apt/sources.list \
 && echo 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/20260401T000000Z bookworm-security main' >> /etc/apt/sources.list \
 && apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update \
 && apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends git jq procps openssh-client \
 && rm -rf /var/lib/apt/lists/*
