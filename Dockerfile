FROM php:7-apache-buster

RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libdbd-mysql-perl \
        libnet-snmp-perl \
        libnet-telnet-perl \
        libsocket6-perl \
        librrds-perl \
        libalgorithm-diff-perl \
        libcrypt-rijndael-perl \
        libcrypt-hcesha-perl \
        libcrypt-des-perl \
        libdigest-hmac-perl \
        libio-pty-perl \
        libwww-perl \
        libnet-ntp-perl \
        libnet-dns-perl \
        libzip-dev \
        libpng-dev \
        libsnmp-dev \
        libldap2-dev \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        perl-doc \
        mariadb-client \
        net-tools \
        snmp \
        rrdtool \
        nginx \
        openssl \
        iputils-ping \
        fping \
        wget \
        busybox-static \
        supervisor; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*

# TODO: check if --with-freetype --with-jpeg is required
RUN set -ex; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j "$(nproc)" gd snmp ldap mysqli

COPY apache-nedi.conf /etc/apache2/sites-available/nedi.conf
RUN set -ex; \
    rm /etc/apache2/sites-enabled/000-default.conf; \
    ln -s /etc/apache2/sites-available/nedi.conf /etc/apache2/sites-enabled/nedi.conf

# Enabling SNMP latency measurement. Taken from nebuntu.sh
RUN set -ex; \
    sed -i '23 i use Time::HiRes;' /usr/share/perl5/Net/SNMP/Message.pm; \
    sed -i '687 i \ \ \ $this->{_transport}->{_send_time} = Time::HiRes::time;' /usr/share/perl5/Net/SNMP/Message.pm

COPY supervisord/* /etc/supervisor/conf.d/
COPY entrypoint.sh /entrypoint.sh

ARG NEDI_VERSION="1.9C"

RUN set -ex; \
    install -o www-data -g www-data -d /var/nedi; \
    install -o www-data -g www-data -d /etc/nedi; \
    install -o www-data -g www-data -d /var/log/nedi; \
    wget http://www.nedi.ch/pub/nedi-${NEDI_VERSION}.pkg -O /tmp/nedi-${NEDI_VERSION}.pkg; \
    tar -xzf /tmp/nedi-${NEDI_VERSION}.pkg -C /var/nedi; \
    chown -R www-data:www-data /var/nedi; \
    rm /tmp/nedi-${NEDI_VERSION}.pkg; \
    mv /var/nedi/nedi.conf /var/nedi/nedi.conf.orig; \
    mv /var/nedi/seedlist /var/nedi/seedlist.orig; \
    ln -s /etc/nedi/nedi.conf /var/nedi/nedi.conf; \
    ln -s /etc/nedi/seedlist /var/nedi/seedlist; \
    chmod +x /entrypoint.sh; \
    install -d  /var/spool/cron/crontabs; \
    echo "15 */4 * * * cd /var/nedi && ./nedi.pl -pob" > /var/spool/cron/crontabs/www-data

WORKDIR /var/nedi

EXPOSE 80 1514

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
