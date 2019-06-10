FROM centos:7
ENV GOSU_VERSION=1.11

RUN yum install -y make git gcc libcurl-devel sqlite-devel pkg-config && \
    rm -rf /var/cache/yum/ && \
    curl -fsS -o install.sh https://dlang.org/install.sh && \
    bash install.sh dmd && \
    # gosu installation
    gpg --keyserver ha.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 \
    && curl -o /usr/local/bin/gosu -SL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64" \
    && curl -o /usr/local/bin/gosu.asc -SL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64.asc" \
    && gpg --verify /usr/local/bin/gosu.asc \
    && rm /usr/local/bin/gosu.asc \
    && rm -r /root/.gnupg/ \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true
RUN mkdir -p /onedrive/conf /onedrive/data
COPY . /usr/src/onedrive
RUN . "$(bash install.sh -a)" && \
    cd /usr/src/onedrive/ && \
    ./configure && \
    make clean && \
    make && \
    make install
COPY entrypoint.sh /entrypoint.sh
VOLUME ["/onedrive/conf"]

ENTRYPOINT ["/entrypoint.sh"]
