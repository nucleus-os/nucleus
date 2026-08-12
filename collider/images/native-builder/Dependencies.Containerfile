FROM docker.io/library/ubuntu:26.04@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb

ARG DEBIAN_FRONTEND=noninteractive

# Ubuntu's libgudev development package is not co-installable across arm64 and
# amd64 because its shared GIR differs between the two package instances.
# Install the architecture-neutral libinput headers from the native package,
# then expose the amd64 runtime SONAME through the normal linker development
# name without pulling in the conflicting amd64 development package.
# LLVM's libc++ runtime packages also install architecture-colliding versioned
# paths and cannot be co-installed. Extract only the current amd64 runtime
# objects into the multiarch directory used by translated SwiftPM host tools.
# Collider resolves and downloads this exact package closure on the host. The
# image build never contacts an Ubuntu mirror.
COPY inputs/apt/install/ /tmp/nucleus-apt/install/
COPY inputs/apt/extract/ /tmp/nucleus-apt/extract/
RUN test "$(dpkg --print-architecture)" = arm64 \
    && dpkg --add-architecture amd64 \
    && mkdir -p /tmp/nucleus-empty-apt-sources \
    && apt-get --yes --no-install-recommends \
        -o Acquire::Retries=0 \
        -o Dir::Etc::sourcelist=/dev/null \
        -o Dir::Etc::sourceparts=/tmp/nucleus-empty-apt-sources \
        install /tmp/nucleus-apt/install/*.deb \
    && dpkg --compare-versions "$(pkg-config --modversion vulkan)" ge 1.4 \
    && dpkg --compare-versions \
        "$(PKG_CONFIG_LIBDIR=/usr/lib/x86_64-linux-gnu/pkgconfig pkg-config --modversion vulkan)" \
        ge 1.4 \
    && mkdir -p /tmp/nucleus-amd64-libcxx \
    && for package in \
        /tmp/nucleus-apt/extract/*.deb; do \
        dpkg-deb --extract "$package" /tmp/nucleus-amd64-libcxx; \
    done \
    && libcxx=$(find /tmp/nucleus-amd64-libcxx -type f -name libc++.so.1.0 -print -quit) \
    && libcxxabi=$(find /tmp/nucleus-amd64-libcxx -type f -name libc++abi.so.1.0 -print -quit) \
    && libunwind=$(find /tmp/nucleus-amd64-libcxx -type f -name libunwind.so.1.0 -print -quit) \
    && test -n "$libcxx" \
    && test -n "$libcxxabi" \
    && test -n "$libunwind" \
    && install --mode=0644 "$libcxx" /usr/lib/x86_64-linux-gnu/libc++.so.1.0 \
    && install --mode=0644 "$libcxxabi" /usr/lib/x86_64-linux-gnu/libc++abi.so.1.0 \
    && install --mode=0644 "$libunwind" /usr/lib/x86_64-linux-gnu/libunwind.so.1.0 \
    && ln -s libc++.so.1.0 /usr/lib/x86_64-linux-gnu/libc++.so.1 \
    && ln -s libc++abi.so.1.0 /usr/lib/x86_64-linux-gnu/libc++abi.so.1 \
    && ln -s libunwind.so.1.0 /usr/lib/x86_64-linux-gnu/libunwind.so.1 \
    && ln -s libinput.so.10 /usr/lib/x86_64-linux-gnu/libinput.so \
    && rm -rf \
        /tmp/nucleus-amd64-libcxx \
        /tmp/nucleus-apt \
        /tmp/nucleus-empty-apt-sources

# Apple Container VMs can begin a few hundred milliseconds behind the host
# clock. Meson's 1 ms tolerance then rejects files it just wrote to a host bind
# mount. One second still detects clock errors large enough to cause perpetual
# regeneration while admitting the measured VM startup skew.
RUN sed -i 's/if delta > 0\.001:/if delta > 1.0:/' \
        /usr/lib/python3/dist-packages/mesonbuild/backend/backends.py \
    && grep -Fq 'if delta > 1.0:' \
        /usr/lib/python3/dist-packages/mesonbuild/backend/backends.py

# Swift.org's Ubuntu 24.04 compiler requires the libxml2.so.2 ABI, while the
# Ubuntu 26.04 build environment intentionally provides libxml2.so.16. Keep the
# exact older runtime closure isolated from the system multiarch directories so
# it cannot replace the target SDK or the builder's native libraries.
COPY inputs/archives/swift-libxml2-arm64.deb /tmp/swift-libxml2-arm64.deb
COPY inputs/archives/swift-libxml2-amd64.deb /tmp/swift-libxml2-amd64.deb
COPY inputs/archives/swift-libicu74-arm64.deb /tmp/swift-libicu74-arm64.deb
COPY inputs/archives/swift-libicu74-amd64.deb /tmp/swift-libicu74-amd64.deb
RUN echo 'f833e07c5dffb9f7a26084522ef58854c4297982439a2affc94e20dbb495c696  /tmp/swift-libxml2-arm64.deb' \
        | sha256sum --check --strict \
    && echo 'bfd07c01d6e5ab3e327f3ca5819409b1914bbfb3f1a016d53e4dabd5f96143bb  /tmp/swift-libxml2-amd64.deb' \
        | sha256sum --check --strict \
    && echo '041df33ab32c57287a62ba141890a82512bf092854be455259c8034ab7ae9fbc  /tmp/swift-libicu74-arm64.deb' \
        | sha256sum --check --strict \
    && echo 'd29c97a21a3e3254731cfac186e4d4e611e5e67d2c9a0430f6acfbd9acaefa2e  /tmp/swift-libicu74-amd64.deb' \
        | sha256sum --check --strict \
    && mkdir -p \
        /tmp/swift-compat-arm64 \
        /tmp/swift-compat-amd64 \
        /opt/swift-compat/arm64 \
        /opt/swift-compat/amd64 \
    && dpkg-deb --extract /tmp/swift-libxml2-arm64.deb /tmp/swift-compat-arm64 \
    && dpkg-deb --extract /tmp/swift-libicu74-arm64.deb /tmp/swift-compat-arm64 \
    && dpkg-deb --extract /tmp/swift-libxml2-amd64.deb /tmp/swift-compat-amd64 \
    && dpkg-deb --extract /tmp/swift-libicu74-amd64.deb /tmp/swift-compat-amd64 \
    && cp -a /tmp/swift-compat-arm64/usr/lib/aarch64-linux-gnu/libxml2.so.2* \
        /tmp/swift-compat-arm64/usr/lib/aarch64-linux-gnu/libicu*.so.74* \
        /opt/swift-compat/arm64/ \
    && cp -a /tmp/swift-compat-amd64/usr/lib/x86_64-linux-gnu/libxml2.so.2* \
        /tmp/swift-compat-amd64/usr/lib/x86_64-linux-gnu/libicu*.so.74* \
        /opt/swift-compat/amd64/ \
    && rm -rf \
        /tmp/swift-compat-arm64 \
        /tmp/swift-compat-amd64 \
        /tmp/swift-libxml2-arm64.deb \
        /tmp/swift-libxml2-amd64.deb \
        /tmp/swift-libicu74-arm64.deb \
        /tmp/swift-libicu74-amd64.deb

COPY inputs/archives/swift-arm64.tar.gz /tmp/swift.tar.gz
RUN echo 'd0d2aa2a243bf33d038da02611055bf13e48fe0e20a41a8443faa731884a03de  /tmp/swift.tar.gz' \
        | sha256sum --check --strict \
    && mkdir -p /opt/swift \
    && tar --extract --gzip \
        --file /tmp/swift.tar.gz \
        --directory /opt/swift \
        --strip-components=1 \
    && rm -f /tmp/swift.tar.gz \
    && LD_LIBRARY_PATH=/opt/swift-compat/arm64 \
        /opt/swift/usr/bin/swift --version \
        | grep --fixed-strings 'Swift version 6.4-dev' \
    && LD_LIBRARY_PATH=/opt/swift-compat/arm64 \
        /opt/swift/usr/bin/swift-build --version \
    && /opt/swift/usr/bin/swiftc -print-target-info \
        | grep --fixed-strings 'aarch64-unknown-linux-gnu'

# SwiftPM builds macro and plugin executables for the compiler's host
# architecture. Give the translated amd64 lane a matching official compiler
# so its host tools and target SDK share one architecture.
COPY inputs/archives/swift-amd64.tar.gz /tmp/swift-x86_64.tar.gz
RUN echo 'fa3f1d9517068ead03518d6c9936814c2e1b588cb6e89c4c0284283d274f5d73  /tmp/swift-x86_64.tar.gz' \
        | sha256sum --check --strict \
    && mkdir -p /opt/swift-x86_64 \
    && tar --extract --gzip \
        --file /tmp/swift-x86_64.tar.gz \
        --directory /opt/swift-x86_64 \
        --strip-components=1 \
    && rm -f /tmp/swift-x86_64.tar.gz \
    && test ! -e /opt/swift-x86_64/usr/bin/ld \
    && ln -s lld /opt/swift-x86_64/usr/bin/ld \
    && LD_LIBRARY_PATH=/opt/swift-compat/amd64 \
        /opt/swift-x86_64/usr/bin/swift --version \
        | grep --fixed-strings 'Swift version 6.4-dev' \
    && LD_LIBRARY_PATH=/opt/swift-compat/amd64 \
        /opt/swift-x86_64/usr/bin/swift-build --version \
    && test "$(readlink /opt/swift-x86_64/usr/bin/ld)" = lld \
    && /opt/swift-x86_64/usr/bin/swiftc -print-target-info \
        | grep --fixed-strings 'x86_64-unknown-linux-gnu'

COPY inputs/archives/cmake-arm64.tar.gz /tmp/cmake.tar.gz
RUN echo 'd18f50f01b001303d21f53c6c16ff12ee3aa45df5da1899c2fe95be7426aa026  /tmp/cmake.tar.gz' \
        | sha256sum --check --strict \
    && mkdir -p /opt/cmake \
    && tar --extract --gzip \
        --file /tmp/cmake.tar.gz \
        --directory /opt/cmake \
        --strip-components=1 \
    && rm -f /tmp/cmake.tar.gz \
    && /opt/cmake/bin/cmake --version \
        | grep --fixed-strings 'cmake version 3.30.2'

ENV PATH=/opt/bun/bin:/opt/node/bin:/opt/cmake/bin:/opt/swift/usr/bin:/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY inputs/archives/node-arm64.tar.xz /tmp/node.tar.xz
RUN echo '974e6f0332fb26179b34d49c57f35339e089a89faf8b82a81e44c0e1164b7923  /tmp/node.tar.xz' \
        | sha256sum --check --strict \
    && mkdir -p /opt/node \
    && tar --extract --xz --file /tmp/node.tar.xz \
        --directory /opt/node --strip-components=1 \
    && rm -f /tmp/node.tar.xz \
    && /opt/node/bin/node --version | grep --fixed-strings 'v26.6.0'

COPY inputs/archives/bun-arm64.zip /tmp/bun.zip
RUN echo 'a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b  /tmp/bun.zip' \
        | sha256sum --check --strict \
    && unzip /tmp/bun.zip -d /tmp/bun \
    && install --directory --mode=0755 /opt/bun/bin \
    && install --mode=0755 /tmp/bun/bun-linux-aarch64/bun /opt/bun/bin/bun \
    && rm -rf /tmp/bun /tmp/bun.zip \
    && /opt/bun/bin/bun --version | grep --fixed-strings '1.3.14'

# Android's NDK host tools remain x86_64. The ARM guest executes them through
# the same explicit Intel-translation policy used by the Linux amd64 test lane.
COPY inputs/archives/android-ndk-r30-beta2-linux.zip /tmp/android-ndk.zip
RUN echo '3827b0acab65a4559d92bc07b05a409d57d1925c835b8e6fd741cda08ca41515  /tmp/android-ndk.zip' \
        | sha256sum --check --strict \
    && unzip -q /tmp/android-ndk.zip -d /opt \
    && rm -f /tmp/android-ndk.zip

RUN usermod \
        --login nucleus-build \
        --home /home/nucleus-build \
        --move-home \
        --shell /bin/bash \
        ubuntu \
    && groupmod --new-name nucleus-build ubuntu \
    && usermod \
        --groups '' \
        --comment 'Nucleus Linux Build' \
        nucleus-build

USER nucleus-build
WORKDIR /src

ENV ANDROID_NDK_HOME=/opt/android-ndk-r30-beta2 \
    CCACHE_COMPILERCHECK=content \
    CCACHE_DIR=/ccache \
    HOME=/home/nucleus-build \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/bun/bin:/opt/node/bin:/opt/cmake/bin:/opt/swift/usr/bin:/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TZ=UTC
