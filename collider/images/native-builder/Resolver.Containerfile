FROM docker.io/library/ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

COPY --chmod=0755 resolve-apt-packages.sh /usr/local/bin/resolve-nucleus-apt-packages
