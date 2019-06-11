# -*-Dockerfile-*-
FROM golang:alpine
RUN apk add alpine-sdk bash llvm5 gnupg xz jq curl-dev sqlite-dev binutils-gold
ARG LDC_VERSION=1.13.0
ENV LDC_VERSION=${LDC_VERSION}
RUN curl -fsSL "https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/ldc2-${LDC_VERSION}-alpine-linux-x86_64.tar.xz" |\
    tar xJf - -C / && \
    mv "/ldc2-${LDC_VERSION}-alpine-linux-x86_64" "/ldc"
ENV PATH="/ldc/bin:${PATH}" \
    LD_LIBRARY_PATH="/ldc/lib:/usr/lib:/lib:${LD_LIBRARY_PATH}" \
    LIBRARY_PATH="/ldc/lib:/usr/lib:/lib:${LD_LIBRARY_PATH}"
RUN go get github.com/tianon/gosu
COPY . /usr/src/onedrive
RUN cd /usr/src/onedrive/ && \
    DC=ldmd2 ./configure && \
    make clean && \
    make && \
    make install

FROM alpine
ENTRYPOINT ["/entrypoint.sh"]
RUN apk add --no-cache bash libcurl libgcc shadow sqlite-libs && \
    mkdir -p /onedrive/conf /onedrive/data
COPY contrib/docker/entrypoint.sh /
COPY --from=0 /go/bin/gosu /usr/local/bin/onedrive /usr/local/bin/
