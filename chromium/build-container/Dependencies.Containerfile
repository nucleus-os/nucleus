FROM docker.io/library/ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

ARG DEBIAN_FRONTEND=noninteractive

# Collider resolves this exact package closure from pinned Ubuntu indexes and
# downloads it on the host. Image construction is deliberately offline.
COPY inputs/apt/install/ /tmp/nucleus-apt/install/
RUN test "$(dpkg --print-architecture)" = arm64 \
    && dpkg --add-architecture amd64 \
    && mkdir -p /tmp/nucleus-empty-apt-sources \
    && apt-get --yes --no-install-recommends \
        -o Acquire::Retries=0 \
        -o Dir::Etc::sourcelist=/dev/null \
        -o Dir::Etc::sourceparts=/tmp/nucleus-empty-apt-sources \
        install /tmp/nucleus-apt/install/*.deb \
    && rm -rf /tmp/nucleus-apt /tmp/nucleus-empty-apt-sources

RUN usermod \
        --login nucleus-build \
        --home /home/nucleus-build \
        --move-home \
        --shell /bin/bash \
        ubuntu \
    && groupmod --new-name nucleus-build ubuntu \
    && usermod \
        --groups '' \
        --comment 'Nucleus Chromium Build' \
        nucleus-build

USER nucleus-build
WORKDIR /source/chromium/src

ENV HOME=/tmp/nucleus-home \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/source/chromium/src/third_party/llvm-build/Linux_x64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=UTC
