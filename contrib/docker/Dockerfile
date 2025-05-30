# -*-Dockerfile-*-

ARG FEDORA_VERSION=42
ARG DEBIAN_VERSION=bullseye
ARG GO_VERSION=1.22
ARG GOSU_VERSION=1.17

FROM golang:${GO_VERSION}-${DEBIAN_VERSION} AS builder-gosu
ARG GOSU_VERSION
RUN go install -ldflags "-s -w" github.com/tianon/gosu@${GOSU_VERSION}

FROM fedora:${FEDORA_VERSION} AS builder-onedrive

RUN dnf install -y ldc pkgconf libcurl-devel sqlite-devel dbus-devel git awk

ENV PKG_CONFIG=/usr/bin/pkgconf

COPY . /usr/src/onedrive
WORKDIR /usr/src/onedrive

RUN ./configure --enable-debug\
 && make clean \
 && make \
 && make install

FROM fedora:${FEDORA_VERSION}

RUN dnf clean all \
 && dnf -y update

RUN dnf install -y libcurl sqlite ldc-libs dbus-libs \
 && dnf clean all \
 && mkdir -p /onedrive/conf /onedrive/data

COPY --from=builder-gosu /go/bin/gosu /usr/local/bin/
COPY --from=builder-onedrive /usr/local/bin/onedrive /usr/local/bin/

COPY contrib/docker/entrypoint.sh /
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
