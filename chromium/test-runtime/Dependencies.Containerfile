FROM localhost/nucleus-chromium-build-dependencies

USER root

# The target test runtime is a separate image layer so changing a runtime
# dependency never changes the image that compiles Chromium products.
COPY inputs/apt/install/ /tmp/nucleus-test-runtime-apt/install/
RUN mkdir -p /tmp/nucleus-empty-apt-sources \
    && apt-get --yes --no-install-recommends \
        -o Acquire::Retries=0 \
        -o Dir::Etc::sourcelist=/dev/null \
        -o Dir::Etc::sourceparts=/tmp/nucleus-empty-apt-sources \
        install /tmp/nucleus-test-runtime-apt/install/*.deb \
    && test -x /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
    && test -e /usr/lib/aarch64-linux-gnu/libxkbcommon.so.0 \
    && test -x /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
    && test -e /usr/lib/x86_64-linux-gnu/libxkbcommon.so.0 \
    && rm -rf \
        /tmp/nucleus-empty-apt-sources \
        /tmp/nucleus-test-runtime-apt

USER nucleus-build
