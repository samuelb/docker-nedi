# NeDi Docker

Runs [NeDi](https://www.nedi.ch) – network discovery, inventory and monitoring –
with Docker Compose.

- NeDi 2.4C on Debian 13 (trixie), all dependencies from Debian's repositories
  (nfdump from Debian forky, see [NetFlow](#netflow))
- Web GUI with nginx and PHP-FPM 8.4
- NeDi's monitoring (`moni.pl`), syslog collector (`syslog.pl`), SNMP trap
  receiver (`snmptrapd` → `trap.pl`) and NetFlow collector (`nfcapd` for `flowi.pl`)
- Discovery schedule managed in the GUI (cron)
- MariaDB 11.8 as database

## Quick start

```sh
cp .env.example .env    # then set your own passwords in .env
docker compose up -d --build
```

Open <http://localhost:8080> and log in with **admin / admin**. Change the
password right away (User > Profile).

Then add your devices' SNMP communities and seeds in System > Files
(`nedi.conf`, `seedlist`) and start a discovery in System > NeDi. Scheduled
discoveries are configured in System > Setup > Schedule (`inc/crontab`).

To use the image built by GitHub Actions instead of building locally, run
`docker compose pull` before `docker compose up -d`.

## Ports

| Host port (default) | Container | Purpose                         |
|---------------------|-----------|---------------------------------|
| 8080/tcp            | 80/tcp    | Web GUI                         |
| 514/udp             | 1514/udp  | Syslog                          |
| 162/udp             | 1162/udp  | SNMP traps                      |
| 2055/udp            | 2055/udp  | NetFlow/IPFIX                   |

The host ports can be changed in `.env`. The GUI is plain HTTP, so put a
reverse proxy with TLS in front of it when exposing it.

NeDi matches syslog messages, traps and flows to devices by their source IP
address. Docker keeps the source address for published ports on Linux hosts
(iptables/nftables), but not when the userland proxy is used (e.g. for IPv6,
Docker Desktop or Colima). Use `network_mode: host` in such setups.

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
`nedi.conf` itself.

## Data

| Volume   | Path in container | Content                                             |
|----------|-------------------|-----------------------------------------------------|
| `nedi`   | `/var/nedi`       | NeDi installation, `nedi.conf`, seedlist, RRDs, config backups, custom device definitions, uploaded maps |
| `nfdump` | `/var/nfdump`     | NetFlow data                                        |
| `db`     | `/var/lib/mysql`  | MariaDB database                                    |

NeDi edits its own files from the GUI, so the whole NeDi directory is a volume.
On the first start the container copies NeDi into it and creates the database
tables. When a newer image is started, the NeDi files are updated the same way
NeDi's GUI updater does it: `nedi.conf`, `nodi.conf`, `seedlist`, `agentlist`,
`inc/crontab` and the customized `html/log` files are kept, then the database
schema is updated with `nedi.pl -i updatedb`. Updating NeDi through its GUI
works too, but is undone when a newer image is started.

An existing database is never reset. A database that isn't empty but lacks
NeDi's tables (or is from NeDi older than 2.1) stops the container with an
error.

## NetFlow

`nfcapd` stores flows per exporter below `/var/nfdump` and expires old data
once `NEDI_NETFLOW_MAXSIZE` is reached. NeDi's `flowi.pl` (run every 5 minutes
by the default crontab) and the Nodes > Traffic GUI need nfdump 1.7.6 or newer,
because they aggregate flows with custom output formats. Debian trixie ships
1.7.5, so the image installs nfdump alone from Debian forky; apt pinning
(`docker/apt/preferences.d/nfdump`) blocks every other package from forky.

## Running NeDi commands

Run NeDi's scripts as `www-data`, so files stay writable for the GUI:

```sh
docker compose exec -u www-data nedi ./nedi.pl -v -a 192.0.2.1
docker compose exec nedi supervisorctl -c /etc/supervisor/nedi.conf status
```

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
