ARG JDK_VERSION="25"
ARG UBUNTU_VERSION="26.04"

FROM ubuntu:${UBUNTU_VERSION} AS builder

RUN apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends locales binutils; \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential tar curl

RUN LOCATION=$(curl -s https://api.github.com/repos/zlib-ng/zlib-ng/releases/latest \
    | grep "tarball_url" \
    | awk '{ print $2 }' \
    | sed 's/,$//'       \
    | sed 's/"//g' )     \
    ; curl -L -o /tmp/zlib-ng.tar $LOCATION; \
    mkdir -p /tmp/; \
    tar --extract \
	      --file /tmp/zlib-ng.tar \
	      --directory "/tmp/"

RUN cd /tmp/zlib-ng-zlib-ng-*; \
    CFLAGS="-O3 -flto=auto" LDFLAGS="-flto=auto" ./configure --zlib-compat; \
    make -j$(nproc); make install

FROM ubuntu:${UBUNTU_VERSION}
ARG JDK_VERSION

LABEL author="Zoë Gidiere" maintainer="duplexsys@protonmail.com"

LABEL org.opencontainers.image.source="https://github.com/duplexsystem/optimized-java-yolk"
LABEL org.opencontainers.image.licenses=MIT

ENV JAVA_HOME=/opt/java/graalvm
ENV PATH=$JAVA_HOME/bin:$PATH

# Default to UTF-8 file.encoding
ENV  LANG='en_US.UTF-8' LANGUAGE='en_US:en' LC_ALL='en_US.UTF-8'

RUN set -eux; \
    DEBIAN_FRONTEND=noninteractive apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tzdata curl wget ca-certificates fontconfig locales binutils lsof curl openssl git tar sqlite3 libfreetype6 iproute2 libstdc++6 libmimalloc3 libnuma1 git-lfs tini zip unzip jq valkey-tools qatengine; \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; \
    rm -rf /var/lib/apt/lists/* /usr/share/i18n /usr/share/doc /var/cache/debconf/*

RUN --mount=type=bind,from=builder,source=/usr/local,target=/zlib-ng \
    set -eux; \
    rm /lib/x86_64-linux-gnu/libz.*; \
    cp -a /zlib-ng/lib/libz.* /lib/x86_64-linux-gnu/; \
    cp /zlib-ng/include/zlib.h /zlib-ng/include/zconf.h /zlib-ng/include/zlib_name_mangling.h /usr/include/; \
    mkdir -p /usr/lib64/pkgconfig; \
    cp /zlib-ng/lib/pkgconfig/zlib.pc /usr/lib64/pkgconfig/

RUN set -eux; \
    wget -O /tmp/graalvm.tar.gz https://download.oracle.com/graalvm/${JDK_VERSION}/latest/graalvm-jdk-${JDK_VERSION}_linux-x64_bin.tar.gz; \
    wget -O /tmp/graalvm.tar.gz.sha256 https://download.oracle.com/graalvm/${JDK_VERSION}/latest/graalvm-jdk-${JDK_VERSION}_linux-x64_bin.tar.gz.sha256; \
    ESUM=$(cat /tmp/graalvm.tar.gz.sha256); \
    echo "${ESUM} */tmp/graalvm.tar.gz" | sha256sum -c -; \
    mkdir -p "$JAVA_HOME"; \
    tar --extract \
        --file /tmp/graalvm.tar.gz \
        --directory "$JAVA_HOME" \
        --strip-components 1 \
        --no-same-owner \
    ; \
    rm -f /tmp/graalvm.tar.gz /tmp/graalvm.tar.gz.sha256 ${JAVA_HOME}/lib/src.zip; \
    rm -rf ${JAVA_HOME}/jmods ${JAVA_HOME}/lib/svm ${JAVA_HOME}/bin/native-image* ${JAVA_HOME}/man; \
# https://github.com/docker-library/openjdk/issues/331#issuecomment-498834472
    find "$JAVA_HOME/lib" -name '*.so' -exec dirname '{}' ';' | sort -u > /etc/ld.so.conf.d/docker-openjdk.conf; \
    ldconfig; \
# https://github.com/docker-library/openjdk/issues/212#issuecomment-420979840
# https://openjdk.java.net/jeps/341
    java -Xshare:dump; \
# Create QAT OpenSSL config
    echo 'openssl_conf = openssl_init\n\
\n\
[ openssl_init ]\n\
providers = provider_section\n\
\n\
[ provider_section ]\n\
qat = qat_section\n\
default = default_section\n\
\n\
[ qat_section ]\n\
module = /usr/lib/x86_64-linux-gnu/ossl-modules/qatprovider.so\n\
activate = 1\n\
enable_external_polling = 0\n\
enable_heuristic_polling = 0\n\
enable_sw_fallback = 1\n\
enable_inline_polling = 0\n\
qat_poll_interval = 10000\n\
qat_epoll_timeout = 1000\n\
enable_event_driven_polling = 1\n\
enable_instance_for_thread = 0\n\
qat_max_retry_count = 5\n\
\n\
[ default_section ]\n\
activate = 1' > /etc/ssl/openssl_qat.cnf

## Setup user and working directory
RUN         useradd -m -d /home/container -s /bin/bash container
USER        container
ENV         USER=container HOME=/home/container LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libmimalloc.so.3 MIMALLOC_ALLOW_LARGE_OS_PAGES=1 MIMALLOC_PURGE_DELAY=100 QAT_POLICY=1 OPENSSL_CONF=/etc/ssl/openssl_qat.cnf
WORKDIR     /home/container

RUN set -eux; \
    echo Verifying install ...; \
    fileEncoding="$(echo 'System.out.println(System.getProperty("file.encoding"))' | jshell -s -)"; [ "$fileEncoding" = 'UTF-8' ]; rm -rf ~/.java; \
    echo javac --version; \
    javac --version; \
    echo java --version; \
    java --version; \
    echo openssl version; \
    openssl version; \
    echo openssl list -providers; \
    openssl list -providers | grep -A 3 qat; \
    echo Complete.

STOPSIGNAL SIGINT

COPY        --chown=container:container --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT    ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
