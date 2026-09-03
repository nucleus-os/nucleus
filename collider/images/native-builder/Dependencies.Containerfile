FROM docker.io/library/ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

ARG DEBIAN_FRONTEND=noninteractive

# Ubuntu's libgudev development package is not co-installable across arm64 and
# amd64 because its shared GIR differs between the two package instances.
# Install the architecture-neutral libinput headers from the native package,
# then expose the amd64 runtime SONAME through the normal linker development
# name without pulling in the conflicting amd64 development package.
# LLVM's libc++ runtime packages also install architecture-colliding versioned
# paths and cannot be co-installed. Extract only the current amd64 runtime
# objects into the multiarch directory used when translated x86_64 products run.
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
    && test -x /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
    && test -e /usr/lib/aarch64-linux-gnu/libxkbcommon.so.0 \
    && test -x /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
    && test -e /usr/lib/x86_64-linux-gnu/libxkbcommon.so.0 \
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
COPY inputs/archives/swift-libicu74-arm64.deb /tmp/swift-libicu74-arm64.deb
RUN echo 'f833e07c5dffb9f7a26084522ef58854c4297982439a2affc94e20dbb495c696  /tmp/swift-libxml2-arm64.deb' \
        | sha256sum --check --strict \
    && echo '041df33ab32c57287a62ba141890a82512bf092854be455259c8034ab7ae9fbc  /tmp/swift-libicu74-arm64.deb' \
        | sha256sum --check --strict \
    && mkdir -p \
        /tmp/swift-compat-arm64 \
        /opt/swift-compat/arm64 \
    && dpkg-deb --extract /tmp/swift-libxml2-arm64.deb /tmp/swift-compat-arm64 \
    && dpkg-deb --extract /tmp/swift-libicu74-arm64.deb /tmp/swift-compat-arm64 \
    && cp -a /tmp/swift-compat-arm64/usr/lib/aarch64-linux-gnu/libxml2.so.2* \
        /tmp/swift-compat-arm64/usr/lib/aarch64-linux-gnu/libicu*.so.74* \
        /opt/swift-compat/arm64/ \
    && printf '%s\n' /opt/swift-compat/arm64 \
        > /etc/ld.so.conf.d/nucleus-swift-compat-arm64.conf \
    && ldconfig \
    && rm -rf \
        /tmp/swift-compat-arm64 \
        /tmp/swift-libxml2-arm64.deb \
        /tmp/swift-libicu74-arm64.deb

COPY inputs/archives/swift-arm64.tar.gz /tmp/swift.tar.gz
RUN echo '040c5d553abed9591db318bdf04688e7361eaba192acc787bb836fb1a28a092f  /tmp/swift.tar.gz' \
        | sha256sum --check --strict \
    && mkdir -p /opt/swift \
    && tar --extract --gzip \
        --file /tmp/swift.tar.gz \
        --directory /opt/swift \
        --strip-components=1 \
    && rm -f /tmp/swift.tar.gz \
    && test -x /opt/swift/usr/bin/swift-package \
    && readelf --file-header /opt/swift/usr/bin/swift-package \
        | grep --fixed-strings AArch64 \
    && LD_LIBRARY_PATH=/opt/swift-compat/arm64 \
        /opt/swift/usr/bin/swift --version \
        | grep --fixed-strings 'Swift version 6.4-dev' \
    && LD_LIBRARY_PATH=/opt/swift/usr/lib/swift/linux:/opt/swift-compat/arm64 \
        /opt/swift/usr/bin/swift-package --version \
    && /opt/swift/usr/bin/swiftc -print-target-info \
        | grep --fixed-strings 'aarch64-unknown-linux-gnu'

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
RUN echo '23c1b4d19e2f12a7d06fe8aa3d6e0e4923cf77a47e13c5ccdf32fadaa33960f2  /tmp/node.tar.xz' \
        | sha256sum --check --strict \
    && mkdir -p /opt/node \
    && tar --extract --xz --file /tmp/node.tar.xz \
        --directory /opt/node --strip-components=1 \
    && rm -f /tmp/node.tar.xz \
    && /opt/node/bin/node --version | grep --fixed-strings 'v26.8.1'

COPY inputs/archives/bun-arm64.zip /tmp/bun.zip
RUN echo '4b1a332ee861983eb93bcfe6f770fff94e3e31b2c388bdaea3c8ed35e58eed0e  /tmp/bun.zip' \
        | sha256sum --check --strict \
    && unzip /tmp/bun.zip -d /tmp/bun \
    && install --directory --mode=0755 /opt/bun/bin \
    && install --mode=0755 /tmp/bun/bun-linux-aarch64/bun /opt/bun/bin/bun \
    && rm -rf /tmp/bun /tmp/bun.zip \
    && /opt/bun/bin/bun --version | grep --fixed-strings '1.4.0'

# Android's NDK host tools remain x86_64. The ARM guest executes them through
# the same explicit Intel-translation policy used by the Linux amd64 test lane.
COPY inputs/archives/android-ndk-r30-beta3-linux.zip /tmp/android-ndk.zip
RUN echo '2698cca1e9f161048ecd84e1e70a556e1aa00b78409473d4c1e87969d40c3efc  /tmp/android-ndk.zip' \
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

COPY --chmod=0755 entrypoint.sh /usr/local/bin/nucleus-build

USER nucleus-build
WORKDIR /src

ENV ANDROID_NDK_HOME=/opt/android-ndk-r30-beta3 \
    CCACHE_COMPILERCHECK=content \
    CCACHE_DIR=/ccache \
    HOME=/home/nucleus-build \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/bun/bin:/opt/node/bin:/opt/cmake/bin:/opt/swift/usr/bin:/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TZ=UTC

ENTRYPOINT ["/usr/local/bin/nucleus-build"]
