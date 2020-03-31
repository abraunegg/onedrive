# -*-Dockerfile-*-
FROM golang:alpine
RUN apk add -X http://dl-cdn.alpinelinux.org/alpine/edge/community \
     -X http://dl-cdn.alpinelinux.org/alpine/edge/main \
    alpine-sdk gnupg xz curl-dev sqlite-dev binutils-gold \
    autoconf automake ldc
RUN go get github.com/tianon/gosu
COPY . /usr/src/onedrive
RUN cd /usr/src/onedrive/ && \
    autoreconf -fiv && \
    ./configure && \
    make clean && \
    make && \
    make install

FROM alpine
ENTRYPOINT ["/entrypoint.sh"]
RUN apk add --no-cache -X http://dl-cdn.alpinelinux.org/alpine/edge/community \
     -X http://dl-cdn.alpinelinux.org/alpine/edge/main \
    bash libcurl libgcc shadow sqlite-libs ldc-runtime && \
    mkdir -p /onedrive/conf /onedrive/data
COPY contrib/docker/entrypoint.sh /
COPY --from=0 /go/bin/gosu /usr/local/bin/onedrive /usr/local/bin/
