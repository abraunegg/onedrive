# -*-Dockerfile-*-

ARG FEDORA_VERSION=36
ARG DEBIAN_VERSION=bullseye
ARG GO_VERSION=1.17
ARG YASU_VERSION=1.19.0

FROM crazymax/yasu:${YASU_VERSION} AS yasu

FROM fedora:${FEDORA_VERSION} AS builder-onedrive
RUN dnf install -y ldc pkgconf libcurl-devel sqlite-devel git

ENV PKG_CONFIG=/usr/bin/pkgconf
COPY . /usr/src/onedrive
WORKDIR /usr/src/onedrive

RUN ./configure \
 && make clean \
 && make \
 && make install

FROM fedora:${FEDORA_VERSION}
COPY --from=yasu /usr/local/bin/yasu /usr/local/bin/gosu
COPY --from=builder-onedrive /usr/local/bin/onedrive /usr/local/bin/

COPY contrib/docker/entrypoint.sh /
RUN chmod +x /entrypoint.sh

RUN dnf install -y libcurl sqlite ldc-libs \
 && dnf clean all \
 && mkdir -p /onedrive/conf /onedrive/data

ENTRYPOINT ["/entrypoint.sh"]
