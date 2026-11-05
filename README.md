# NeDi Docker

Runs [NeDi](https://www.nedi.ch) – network discovery, inventory and monitoring –
with Docker Compose.

This is an unofficial image, not affiliated with or endorsed by the NeDi
project, and it comes without any warranty (see [License](#license)). If NeDi
is useful to you, consider supporting its development with
[NeDi+](https://www.nedi.ch/download/).

- NeDi 2.4C on Debian 13 (trixie), all dependencies from Debian's repositories
  (nfdump from Debian forky, see [NetFlow](#netflow))
- Web GUI with nginx and PHP-FPM 8.4
- NeDi's monitoring (`moni.pl`), syslog collector (`syslog.pl`), SNMP trap
  receiver (`snmptrapd` → `trap.pl`) and NetFlow collector (`nfcapd` for `flowi.pl`)
- Discovery schedule managed in the GUI (cron)
- MariaDB 11.8 as database
- Runs on amd64 and arm64, e.g. a Raspberry Pi (see [Platforms](#platforms))

## Quick start

```sh
cp .env.example .env    # then set your own passwords in .env
docker compose up -d --build
```

Building needs BuildKit, which Docker's own packages include (the
`docker-buildx` package when using Debian's `docker.io`).

Open <http://localhost:8080> and log in with **admin / admin**. Change the
password right away (User > Profile).

Then add your devices' SNMP communities and seeds in System > Files
(`nedi.conf`, `seedlist`) and start a discovery in System > NeDi. Scheduled
discoveries are configured in System > Setup > Schedule (`inc/crontab`).

To use the image built by GitHub Actions instead of building locally, run
`docker compose pull` before `docker compose up -d`.

## Platforms

The image runs on `linux/amd64` and `linux/arm64`, and CI tests the compose
stack natively on both. Building and pulling (see [Images](#images)) pick the
host's platform automatically, so the quick start is the same on a 64-bit ARM
board like the Raspberry Pi 3, 4 or 5.

On a Raspberry Pi, use a 64-bit OS (Raspberry Pi OS 64-bit, Debian or Ubuntu
arm64). There is no 32-bit ARM image; MariaDB doesn't publish one either. The
binaries in both images are aligned for the 16 KiB memory pages of the Pi 5's
default kernel and don't use jemalloc, so no 4 KiB page kernel is needed.
An idle stack with a new database uses about 250 MB of RAM.

## Ports

| Host port (default) | Container | Purpose                         |
|---------------------|-----------|---------------------------------|
| 8080/tcp            | 80/tcp    | Web GUI                         |
| 514/udp             | 1514/udp  | Syslog                          |
| 162/udp             | 1162/udp  | SNMP traps                      |
| 2055/udp            | 2055/udp  | NetFlow/IPFIX                   |

The host ports can be changed in `.env`, including the address they listen on
(e.g. `NEDI_HTTP_PORT=127.0.0.1:8080`). The GUI is plain HTTP, so put a
reverse proxy with TLS in front of it when exposing it.

NeDi matches syslog messages, traps and flows to devices by their source IP
address. Docker keeps the source address for published ports on Linux hosts
(iptables/nftables), but not when the userland proxy is used (e.g. for IPv6,
Docker Desktop or Colima). Use `network_mode: host` in such setups.

Rootless Docker can't publish ports below 1024 unless
`net.ipv4.ip_unprivileged_port_start` is lowered, and with its default port
driver NeDi doesn't see the devices' source addresses either.

## Security

- Syslog, SNMP traps and NetFlow are unauthenticated UDP: anyone who can reach
  these ports can feed events into NeDi. Limit access with a firewall or bind
  the ports to an internal address in `.env` (e.g.
  `NEDI_SYSLOG_PORT=192.0.2.10:514`).
- `snmptrapd` accepts traps with any community (`disableAuthorization yes`).
  Its configuration is kept in the `nedi` volume and can be edited in
  System > Files.
- SSH from the container allows legacy algorithms (SHA-1 key exchange,
  `ssh-rsa` host keys, CBC ciphers), so NeDi's CLI access works with old
  network devices, see `docker/ssh_config`.
- Only discover and monitor networks you are authorized to.

## Configuration

| Variable                 | Default | Description                                         |
|--------------------------|---------|-----------------------------------------------------|
| `NEDI_DB_PASSWORD`       |         | Password of the `nedi` database user (required)     |
| `MARIADB_ROOT_PASSWORD`  |         | MariaDB root password, e.g. for GUI DB snapshots    |
| `TZ`                     | `UTC`   | Timezone for NeDi, cron and PHP                     |
| `NEDI_HTTP_PORT` etc.    |         | Host ports, see `.env.example`                      |

The NeDi container additionally understands:

| Variable                 | Default | Description                                         |
|--------------------------|---------|-----------------------------------------------------|
| `NEDI_DB_HOST`           |         | Sets `dbhost` in `nedi.conf` (`host` or `host;port`) |
| `NEDI_DB_NAME`           |         | Sets `dbname` in `nedi.conf`                        |
| `NEDI_DB_USER`           |         | Sets `dbuser` in `nedi.conf`                        |
| `NEDI_DB_PASSWORD`       |         | Sets `dbpass` in `nedi.conf`                        |
| `NEDI_DB_PASSWORD_FILE`  |         | Read the password from a file (Docker secrets)      |
| `NEDI_DB_INIT`           | `1`     | Set to `0` to skip creating/updating NeDi's tables  |
| `NEDI_DB_WAIT_TIMEOUT`   | `300`   | Seconds to wait for the database at startup         |
| `NEDI_NETFLOW_MAXSIZE`   | `8G`    | Disk space limit for NetFlow data (set on first start) |

Unset variables leave `nedi.conf` untouched; everything else is configured in
`nedi.conf` itself. To set these variables, add them to the `nedi` service,
e.g. in a `docker-compose.override.yaml`, which Docker Compose reads
automatically:

```yaml
services:
  nedi:
    environment:
      NEDI_NETFLOW_MAXSIZE: 20G
```

### Changing passwords

MariaDB only uses `NEDI_DB_PASSWORD` and `MARIADB_ROOT_PASSWORD` when it
creates the database, but the NeDi container writes `NEDI_DB_PASSWORD` into
`nedi.conf` on every start. So change the password in the database first, then
in `.env`, or NeDi can't connect and the container stops after
`NEDI_DB_WAIT_TIMEOUT`:

```sh
docker compose exec db mariadb -uroot -p -e "ALTER USER 'nedi'@'%' IDENTIFIED BY 'new-password'"
# now set NEDI_DB_PASSWORD=new-password in .env
docker compose up -d
```

The root password is changed the same way, for `'root'@'%'` and
`'root'@'localhost'`.

## Data

| Volume   | Path in container | Content                                             |
|----------|-------------------|-----------------------------------------------------|
| `nedi`   | `/var/nedi`       | NeDi installation, `nedi.conf`, seedlist, RRDs, config backups, custom device definitions, uploaded maps |
| `nfdump` | `/var/nfdump`     | NetFlow data                                        |
| `db`     | `/var/lib/mysql`  | MariaDB database                                    |

NeDi edits its own files from the GUI, so the whole NeDi directory is a volume.
On the first start the container copies NeDi into it and creates the database
tables.

An existing database is never reset. A database that isn't empty but lacks
NeDi's tables (or is from NeDi older than 2.1) stops the container with an
error.

## Upgrading

```sh
docker compose pull && docker compose up -d    # published image
git pull && docker compose up -d --build       # local build
```

When a newer image is started, the NeDi files are updated the same way NeDi's
GUI updater does it: `nedi.conf`, `nodi.conf`, `seedlist`, `agentlist`,
`inc/crontab` and the customized `html/log` files are kept, then the database
schema is updated with `nedi.pl -i updatedb`. Updating NeDi through its GUI
works too, but is undone when a newer image is started. MariaDB upgrades its
own system tables (`MARIADB_AUTO_UPGRADE`).

## Backup

Back up the database and the `nedi` volume, e.g.:

```sh
docker compose exec -T db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction nedi' > nedi.sql
docker compose exec -T nedi tar -C /var/nedi -czf - . > nedi.tar.gz
```

To restore them, start the stack with empty volumes, then:

```sh
docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" nedi' < nedi.sql
docker compose exec -T nedi tar -C /var/nedi -xzf - < nedi.tar.gz
docker compose restart nedi
```

The `nfdump` volume only holds NetFlow data and can be saved the same way if
needed.

## NetFlow

`nfcapd` stores flows per exporter below `/var/nfdump` and expires old data
once `NEDI_NETFLOW_MAXSIZE` is reached. NeDi's `flowi.pl` (run every 5 minutes
by the default crontab) and the Nodes > Traffic GUI need nfdump 1.7.6 or newer,
because they aggregate flows with custom output formats. Debian trixie ships
1.7.5, so the image installs nfdump alone from Debian forky; apt pinning
(`docker/apt/preferences.d/nfdump`) blocks every other package from forky.

`NEDI_NETFLOW_MAXSIZE` only applies to a new `nfdump` volume. To change the
limit later, run:

```sh
docker compose exec -u www-data nedi nfexpire -u /var/nfdump -s 20G
```

## Running NeDi commands

Run NeDi's scripts as `www-data`, so files stay writable for the GUI:

```sh
docker compose exec -u www-data nedi ./nedi.pl -v -a 192.0.2.1
docker compose exec nedi supervisorctl -c /etc/supervisor/nedi.conf status
```

All services log to the container output:

```sh
docker compose logs -f nedi
```

## Images

GitHub Actions publishes the image for `linux/amd64` and `linux/arm64` (see
[Platforms](#platforms)) to `ghcr.io/samuelb/nedi`:

| Tag            | Built from            |
|----------------|-----------------------|
| `latest`       | the `master` branch   |
| `1.2.3`, `1.2` | the Git tag `v1.2.3`  |

The tags are versions of this repository, not of NeDi.

Every day, GitHub Actions checks `latest` and the newest release for Debian
package updates and rebuilds the outdated ones, so `docker compose pull` also
brings Debian's security updates. Tags of older releases are not rebuilt.

## Building

The NeDi release and its checksum are build arguments:

```sh
docker build \
  --build-arg NEDI_VERSION=2.4C \
  --build-arg NEDI_ZIP_PASSWORD=RR4JC \
  --build-arg NEDI_SHA1=10c6aa998ff7cf3b6cd9f7e4c720f495d6801578 \
  .
```

The values are published on <https://www.nedi.ch/download/>.

## Changes to NeDi

Apart from the database settings it writes into `nedi.conf` (see
[Configuration](#configuration)), the image changes two files:

- `html/inc/header.php` hides PHP's `E_DEPRECATED` messages as well, because
  NeDi's PHP 7 era code floods the log with them on PHP 8.4.
- Debian's Net::SNMP (`/usr/share/perl5/Net/SNMP/Message.pm`) records the send
  time of SNMP requests for NeDi's latency measurement, the same patch NeDi's
  installer `nedian.sh` applies.

Both files carry a notice of the change.

## License

Copyright 2021–2026 Samuel Barabas

The files in this repository are free software: you can redistribute them
and/or modify them under the terms of the GNU General Public License as
published by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version (GPL-3.0-or-later). They are distributed
WITHOUT ANY WARRANTY, see [LICENSE](LICENSE).

NeDi is free software by Remo Rickli & NeDi Community, also licensed under
GPL-3.0-or-later. It bundles JavaScript and PHP libraries under their own
licenses (Chart.js, D3, Leaflet, PHP QR Code and others, see `html/inc`). The
image also contains Debian packages, each under its own license; their source
code is available from Debian. The copyright and license notices are included
in the image in `/usr/share/doc/*/copyright`, NeDi's in
`/usr/share/doc/nedi/copyright`.

As with all Docker images, it is your responsibility to make sure your use of
the image complies with the licenses of all software it contains.
