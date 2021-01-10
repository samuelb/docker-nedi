#!/bin/bash

# Copy config files if they not exists in case /etc/nedi is an empty volume
if [[ ! -f /etc/nedi/nedi.conf ]]; then
  cp /var/nedi/nedi.conf.orig /etc/nedi/nedi.conf
fi

if [[ ! -f /etc/nedi/seedlist ]]; then
  cp /var/nedi/seedlist.orig /etc/nedi/seedlist
fi

# Update config files according to the environment variables given
update_config() {
  if [[ -n "${2+x}" ]]; then
    SEARCH="$1" \
    REPLACE="$2" \
    perl -i -p -e 's/^;?($ENV{SEARCH}\s+).*/$1$ENV{REPLACE}/' /etc/nedi/nedi.conf
  fi
}

update_config dbname "${MYSQL_DATABASE}"
update_config dbuser "${MYSQL_USER}"
update_config dbpass "${MYSQL_PASSWORD}"
update_config dbhost "${MYSQL_HOST}"


# Initialise or update database
dbname=`awk '/^dbname/ { print $2 }'`
dbuser=`awk '/^dbuser/ { print $2 }'`
dbpass=`awk '/^dbpass/ { print $2 }'`
dbhost=`awk '/^dbhost/ { print $2 }'`

if [[ `mysql -h $dbhost -u "$dbuser" -p$dbpass $dbname -sse "show tables like 'system';"` ]]; then
  echo $HOSTNAME | /var/nedi/nedi.pl -i updatedb
else
  echo $HOSTNAME | /var/nedi/nedi.pl -i nodrop
fi


exec "$@"
