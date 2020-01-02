# -*-Dockerfile-*-
FROM golang:alpine
RUN echo http://dl-cdn.alpinelinux.org/alpine/edge/testing >>/etc/apk/repositories
RUN apk add alpine-sdk bash llvm5 gnupg xz jq curl-dev sqlite-dev binutils-gold autoconf automake ldc ldc-runtime
RUN cd /usr/lib &&\
    ln -s libdruntime-ldc-shared.so libdruntime-ldc.so &&\
    ln -s libphobos2-ldc-shared.so libphobos2-ldc.so
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
RUN apk add --no-cache bash libcurl libgcc shadow sqlite-libs && \
    mkdir -p /onedrive/conf /onedrive/data
COPY contrib/docker/entrypoint.sh /
COPY --from=0 /go/bin/gosu /usr/local/bin/onedrive /usr/local/bin/