#!/bin/bash
set -euo pipefail

NEDI_DIR=/var/nedi
NEDI_DIST=/usr/src/nedi
NEDI_CONF="$NEDI_DIR/nedi.conf"

# Files kept on upgrades, same list as NeDi's own GUI updater (System > Files)
PRESERVE=(
    nedi.conf nodi.conf seedlist agentlist inc/crontab
    html/log/msg.txt html/log/devtools.php html/log/snmptools.php
    html/log/iftools.php html/log/nodetools.php
)

log() { echo "entrypoint: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

as_nedi() { setpriv --reuid=www-data --regid=www-data --init-groups env HOME="$NEDI_DIR" USER=www-data "$@"; }

# Support Docker secrets: VAR_FILE=/run/secrets/... sets VAR from the file
file_env() {
    local var="$1" file_var="${1}_FILE"
    if [[ -n "${!file_var:-}" ]]; then
        [[ -z "${!var:-}" ]] || die "both $var and $file_var are set"
        export "$var"="$(<"${!file_var}")"
    fi
}

# Install NeDi into the volume, or update it when the image changed.
# User data (rrd, conf, cli, sysobj additions, topo, ...) stays untouched.
install_nedi() {
    local dist_ver cur_ver
    dist_ver="$(<"$NEDI_DIST/.image-version")"
    cur_ver="$(cat "$NEDI_DIR/.image-version" 2>/dev/null || true)"
    [[ "$dist_ver" == "$cur_ver" ]] && return

    if [[ -e "$NEDI_DIR/nedi.pl" ]]; then
        log "updating NeDi files in $NEDI_DIR (keeping configuration)"
    else
        log "installing NeDi into $NEDI_DIR"
    fi

    local excludes=(--exclude=./.image-version) f
    for f in "${PRESERVE[@]}"; do
        [[ -e "$NEDI_DIR/$f" ]] && excludes+=("--exclude=./$f")
    done
    tar -C "$NEDI_DIST" --anchored "${excludes[@]}" -cf - . | tar -C "$NEDI_DIR" -xpf -
    echo "$dist_ver" >"$NEDI_DIR/.image-version"
}

# Set "key value" in nedi.conf
set_conf() {
    local key="$1" value="$2"
    [[ -n "$value" ]] || return 0
    if grep -qE "^${key}([[:blank:]]|\$)" "$NEDI_CONF"; then
        KEY="$key" VALUE="$value" perl -i -pe \
            's/^\Q$ENV{KEY}\E(?:([ \t]+).*)?$/$ENV{KEY} . ($1 || "\t\t") . $ENV{VALUE}/e' "$NEDI_CONF"
    else
        printf '%s\t\t%s\n' "$key" "$value" >>"$NEDI_CONF"
    fi
}

get_conf() { awk -v k="$1" '$1 == k { print $2; exit }' "$NEDI_CONF"; }

configure() {
    file_env NEDI_DB_PASSWORD
    set_conf dbhost "${NEDI_DB_HOST:-}"
    set_conf dbname "${NEDI_DB_NAME:-}"
    set_conf dbuser "${NEDI_DB_USER:-}"
    set_conf dbpass "${NEDI_DB_PASSWORD:-}"

    # Timezone for NeDi (Perl), cron and PHP
    local tz="${TZ:-UTC}"
    [[ -e "/usr/share/zoneinfo/$tz" ]] || die "unknown timezone TZ=$tz"
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    echo "$tz" >/etc/timezone
    local d
    for d in /etc/php/*/fpm/conf.d /etc/php/*/cli/conf.d; do
        echo "date.timezone = \"$tz\"" >"$d/91-timezone.ini"
    done

    # snmptrapd.conf lives in the volume, so changes made in the GUI persist
    [[ -e "$NEDI_DIR/snmptrapd.conf" ]] || cp /etc/snmp/snmptrapd.conf.dist "$NEDI_DIR/snmptrapd.conf"
    ln -sf "$NEDI_DIR/snmptrapd.conf" /etc/snmp/snmptrapd.conf

    install -d -o www-data -g www-data "$NEDI_DIR/.ssh" /var/log/nedi
    # NeDi needs to be able to write to its whole tree (GUI updates, defs, ...)
    find "$NEDI_DIR" /var/nfdump /var/log/nedi \! -user www-data -exec chown -h www-data:www-data {} +
}

db() {
    local host port pass
    host="$(get_conf dbhost)"
    port=3306
    if [[ "$host" == *";"* ]]; then
        port="${host#*;}"
        host="${host%%;*}"
    fi
    # Pass the password in an option file, so it is neither visible in the
    # process list nor disables the client's TLS certificate verification
    pass="$(get_conf dbpass)"
    pass="${pass//\\/\\\\}"
    pass="${pass//\"/\\\"}"
    mariadb --defaults-extra-file=<(printf '[client]\npassword="%s"\n' "$pass") \
        --connect-timeout=5 -h "$host" -P "$port" \
        -u "$(get_conf dbuser)" -D "$(get_conf dbname)" -N -B "$@"
}

wait_for_db() {
    local timeout="${NEDI_DB_WAIT_TIMEOUT:-300}" start=$SECONDS err
    log "waiting for database $(get_conf dbname) on $(get_conf dbhost)"
    until err="$(db -e 'SELECT 1' 2>&1 >/dev/null)"; do
        (( SECONDS - start < timeout )) || die "database not reachable after ${timeout}s: $err"
        sleep 3
    done
}

# Create NeDi's tables in an empty database or update the schema after an upgrade.
init_db() {
    local tables dbver codever
    tables="$(db -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")"
    codever="$(perl -ne 'if (/^our \$VERSION = "([^"]+)"/) { print $1; exit }' "$NEDI_DIR/nedi.pl")"

    if [[ "$tables" == 0 ]]; then
        log "initializing empty database for NeDi $codever"
        # "nodrop" creates the tables without needing DB admin rights; the
        # NeDi host prompt (only used for granting admin access) gets a dummy.
        echo localhost | as_nedi "$NEDI_DIR/nedi.pl" -i nodrop || die "database initialization failed"
        return
    fi

    tables="$(db -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'sysvars'")"
    [[ "$tables" == 1 ]] || die "database is not empty but has no NeDi sysvars table (NeDi < 2.1?). Upgrade it manually or use an empty database."

    dbver="$(db -e "SELECT value FROM sysvars WHERE name = 'version'")"
    if [[ "$dbver" != "$codever" ]]; then
        log "updating database schema from NeDi $dbver to $codever"
        echo localhost | as_nedi "$NEDI_DIR/nedi.pl" -i updatedb || die "database update from $dbver to $codever failed"
    fi
}

# Install the crontab managed by NeDi's GUI (it lives in the volume)
install_crontab() {
    crontab -u www-data "$NEDI_DIR/inc/crontab" || log "WARNING: could not install $NEDI_DIR/inc/crontab"
}

# Limit the disk space used by NetFlow data (like NeDi's nedian.sh does)
setup_nfdump() {
    [[ -e /var/nfdump/.nfstat ]] && return
    as_nedi nfexpire -u /var/nfdump -s "${NEDI_NETFLOW_MAXSIZE:-8G}" >/dev/null || log "WARNING: nfexpire failed"
}

install_nedi
configure

if [[ "${1:-}" == supervisord || "${1:-}" == */supervisord ]]; then
    wait_for_db
    if [[ "${NEDI_DB_INIT:-1}" == 1 ]]; then
        init_db
    fi
    install_crontab
    setup_nfdump
fi

exec "$@"
