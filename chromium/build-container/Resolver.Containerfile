FROM docker.io/library/ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

COPY --chmod=0755 resolve-apt-packages.sh /usr/local/bin/resolve-chromium-apt-packages
