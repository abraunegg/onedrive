# -*-Dockerfile-*-
FROM debian:stretch
RUN apt update && \
    apt install -y build-essential curl libcurl4-openssl-dev libsqlite3-dev pkg-config git
RUN curl -fsS -o install.sh https://dlang.org/install.sh && \
    bash install.sh dmd
COPY . /usr/src/onedrive
RUN . "$(bash install.sh -a)" && \
    cd /usr/src/onedrive/ && \
    ./configure && \
    make clean && \
    make && \
    make install

FROM debian:stretch-slim
ENTRYPOINT ["/entrypoint.sh"]
RUN apt update && \
    apt install -y gosu libcurl3 libsqlite3-0 && \
    rm -rf /var/*/apt && \
    mkdir -p /onedrive/conf /onedrive/data
COPY contrib/docker/entrypoint.sh /
COPY --from=0 /usr/local/bin/onedrive /usr/local/bin/
