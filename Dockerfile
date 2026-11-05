# syntax=docker/dockerfile:1

ARG DEBIAN_RELEASE=trixie

###############################################################################
# Download and verify the NeDi release
###############################################################################
FROM debian:${DEBIAN_RELEASE}-slim AS nedi-src

# The values below are published on https://www.nedi.ch/download/
# (the release zip is password protected, the contained tgz has a SHA-1)
ARG NEDI_VERSION=2.4C
ARG NEDI_ZIP_PASSWORD=RR4JC
ARG NEDI_SHA1=10c6aa998ff7cf3b6cd9f7e4c720f495d6801578

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/nedi
RUN set -eux; \
    curl -fsSL -o nedi.zip "https://www.nedi.ch/pub/nedi-${NEDI_VERSION}.zip"; \
    unzip -q -P "${NEDI_ZIP_PASSWORD}" nedi.zip; \
    echo "${NEDI_SHA1}  nedi-${NEDI_VERSION}.tgz" | sha1sum -c -; \
    mkdir -p /usr/src/nedi; \
    tar -xzf "nedi-${NEDI_VERSION}.tgz" -C /usr/src/nedi; \
    test -x /usr/src/nedi/nedi.pl; \
    # NeDi re-enables E_DEPRECATED, which floods the log with notices about
    # its PHP 7 era syntax on PHP 8.4. Hide them like it hides warnings.
    sed -i 's/error_reporting(E_ALL & ~(E_WARNING|E_NOTICE));/error_reporting(E_ALL \& ~(E_WARNING|E_NOTICE|E_DEPRECATED));/' \
        /usr/src/nedi/html/inc/header.php; \
    test "$(grep -c 'E_NOTICE|E_DEPRECATED' /usr/src/nedi/html/inc/header.php)" -eq 2; \
    # Stamp the distribution so the entrypoint can detect image upgrades
    ( cd /usr/src/nedi && find . -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1 ) \
        > /usr/src/nedi/.image-version

###############################################################################
# Runtime image
###############################################################################
FROM debian:${DEBIAN_RELEASE}-slim

LABEL org.opencontainers.image.title="NeDi" \
      org.opencontainers.image.description="NeDi network discovery and monitoring (nedi.ch) on Debian" \
      org.opencontainers.image.source="https://github.com/samuelb/docker-nedi"

# NeDi's flowi.pl and traffic GUI aggregate flows with custom output formats
# (nfdump -A ... -o fmt:...), which needs nfdump >= 1.7.6. Trixie ships 1.7.5,
# so nfdump alone is taken from Debian forky; all other forky packages are
# blocked, a build fails instead of mixing in other packages from forky.
COPY docker/apt/ /etc/apt/

# Dependencies as listed by NeDi's own installer (nedian.sh), plus the
# tools NeDi's GUI and scripts call (ssh, ping, traceroute, whois, ps, ...)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # Perl modules
        libalgorithm-diff-perl \
        libcrypt-des-perl \
        libcrypt-hcesha-perl \
        libcrypt-rijndael-perl \
        libdbd-mysql-perl \
        libdigest-hmac-perl \
        libio-pty-perl \
        libnet-dns-perl \
        libnet-nslookup-perl \
        libnet-ntp-perl \
        libnet-snmp-perl \
        libnet-telnet-perl \
        librrds-perl \
        libsocket6-perl \
        libwww-perl \
        perl-doc \
        # Web GUI
        nginx \
        php-fpm \
        php-gd \
        php-ldap \
        php-mysql \
        php-snmp \
        php-xml \
        # Tools used by NeDi
        ca-certificates \
        fontconfig \
        fonts-dejavu-core \
        fping \
        iputils-ping \
        mariadb-client \
        net-tools \
        nfdump \
        openssh-client \
        procps \
        rrdtool \
        snmp \
        snmptrapd \
        traceroute \
        whois \
        # Container plumbing
        cron \
        supervisor \
        tzdata; \
    rm -rf /var/lib/apt/lists/*; \
    dpkg --compare-versions "$(dpkg-query -W -f '${Version}' nfdump)" ge 1.7.6; \
    # Make sure all fonts are known, so RRD graphs render quickly
    fc-cache -f

# Enable SNMP latency measurement (same patch as NeDi's nedian.sh installer)
RUN set -eux; \
    f=/usr/share/perl5/Net/SNMP/Message.pm; \
    if ! grep -q 'Time::HiRes' "$f"; then \
        sed -i '23 i use Time::HiRes;' "$f"; \
        sed -i '687 i \ \ \ $this->{_transport}->{_send_time} = Time::HiRes::time;' "$f"; \
    fi; \
    # Fail the build if the patch did not land where it is supposed to
    grep -B2 -F '$this->{_transport}->{_send_time} = Time::HiRes::time;' "$f" \
        | grep -q 'The Transport Domain object is not defined'; \
    perl -c "$f"

RUN set -eux; \
    php_ver="$(basename "$(ls -d /etc/php/*/)")"; \
    ln -s "/usr/sbin/php-fpm${php_ver}" /usr/local/sbin/php-fpm; \
    # PHP-FPM: unversioned socket, log to the container output
    sed -i \
        -e 's|^listen = .*|listen = /run/php/php-fpm.sock|' \
        -e 's|^;\?catch_workers_output = .*|catch_workers_output = yes|' \
        -e 's|^;\?decorate_workers_output = .*|decorate_workers_output = no|' \
        "/etc/php/${php_ver}/fpm/pool.d/www.conf"; \
    sed -i -e 's|^;\?error_log = .*|error_log = /proc/self/fd/2|' "/etc/php/${php_ver}/fpm/php-fpm.conf"; \
    mkdir -p /run/php; \
    # nginx: log to the container output, use our site only
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    rm -f /etc/nginx/sites-enabled/default; \
    # cron: pam_loginuid fails inside containers and would block all jobs
    sed -i 's/^\(session\s\+required\s\+pam_loginuid.so\)/# \1/' /etc/pam.d/cron; \
    # www-data runs NeDi; its home holds ~/.ssh/known_hosts used by NeDi's CLI access
    usermod -d /var/nedi www-data; \
    install -d -o www-data -g www-data /var/nedi /var/log/nedi /var/nfdump /var/lib/snmp

COPY docker/nginx.conf /etc/nginx/sites-enabled/nedi.conf
COPY docker/php.ini /tmp/nedi-php.ini
RUN set -eux; \
    for d in /etc/php/*/fpm/conf.d /etc/php/*/cli/conf.d; do cp /tmp/nedi-php.ini "$d/90-nedi.ini"; done; \
    rm /tmp/nedi-php.ini
COPY docker/ssh_config /etc/ssh/ssh_config.d/nedi.conf
COPY docker/snmptrapd.conf /etc/snmp/snmptrapd.conf.dist
COPY docker/supervisord.conf /etc/supervisor/nedi.conf
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=755 docker/healthcheck.sh /usr/local/bin/healthcheck.sh

COPY --from=nedi-src --chown=www-data:www-data /usr/src/nedi /usr/src/nedi

WORKDIR /var/nedi
VOLUME ["/var/nedi", "/var/nfdump"]

# 80: web GUI, 1514: syslog, 1162: SNMP traps, 2055: NetFlow
EXPOSE 80/tcp 1514/udp 1162/udp 2055/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=5m --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/nedi.conf"]
