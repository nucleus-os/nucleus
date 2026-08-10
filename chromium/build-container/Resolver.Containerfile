FROM docker.io/library/ubuntu:26.04@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb

COPY --chmod=0755 resolve-apt-packages.sh /usr/local/bin/resolve-chromium-apt-packages
