# Inventar — Backup-relevante Services auf dem Docker-Host

Stand: 2026-10-08 (Quellen: `projects/*/compose.yaml`, `projects/*/.env.example`)

## Legende

- **Backup-Kategorie**
  - `DB-Dump` — Datenbank wird konsistent über `docker exec` gedumpt (`pg_dump`/`mysqldump`/`mariadb-dump`/SQLite `.backup`); DB-Rohdaten im Datei-Backup sind ausgeschlossen.
  - `Datei-Rsync-Restic` — Dateidaten (Bind-Mounts) werden per `rsync` auf das NAS gestempelt und optional per `restic` versioniert.
  - `Config-only` — nur kleine Konfigurations-/Anwendungsdaten (SQLite im App-Verzeichnis, YAML, INI); mit Stop-Fenster oder SQLite-Online-Backup.
  - `ignorieren` — reproduzierbar (Media-Library, Caches, Downloads, Ephemeres).
- **Größe**: historische Angaben aus Host-Snapshot (Ebene 1 = `/opt/docker/<service>`). Bei NAS-Pfaden (`/mnt/...`) liegt keine Größe vor.

## Wichtig: Anzahl der Services

Das Repository enthält **14 Compose-Stacks** (`projects/`), die zusammen **30 backup-relevante Services** ergeben (plus Hilfscontainer). Die Zuordnung „30 Services" wird wie folgt gebildet: die 14 Stacks, wobei `arr-stack` zu 7 eigenständigen Services (sonarr, lidarr, bazarr, radarr, prowlarr, sabnzbd, overseerr), `smarthome` zu 4 Services (homeassistant, music-assistant, mosquitto, matter-server) und `media` zu 7 Services (plex, tautulli, audiobookshelf, metube, calibre-web, codex, tdarr), `content` zu 2 Services (homepage, 5etools), `infra` zu 2 Services (omada-controller, crowdsec), `local-ai` zu 4 Services (litellm, crawl4ai, valkey, searxng) und `monitoring` zu 5 Services (dashdot, uptime-kuma, grafana, shynet-db, shynet-server) aufgeteilt wird; reine Netzwerk/Proxy-Helper (cert-Container) werden nicht als eigener Service gezählt. Details und Annahmen: siehe `docs/TODOS.md`.

## Inventartabelle

| # | Service (Stack) | Datenbank(en) | Bind-Mount-Pfade (Host) | Datentyp | Größe (Snapshot) | Backup-Kategorie |
|---|---|---|---|---|---|---|
| 1 | shynet (monitoring) | PostgreSQL 15 (`shynet-db`, `/opt/docker/shynet/postgres`) | `/opt/docker/shynet/data` (App-Daten) | Web-Analytics (DB + statische Daten) | 12K (nur postgres-dir gelistet) | DB-Dump + Datei-Rsync-Restic |
| 2 | sonarr (arr-stack) | SQLite (`sonarr.db` in `/config`) | `/opt/docker/sonarr` (Config+DB); `/mnt/media/video/tv`, `/opt/downloads/completed` (Media, ignoriert) | PVR TV | 754M (137M sonarr.db) | Config-only (Stop-Fenster) |
| 3 | lidarr (arr-stack) | SQLite (`lidarr.db` in `/config`) | `/opt/docker/lidarr`; `/mnt/media/music/lidarr`, `/opt/downloads/completed` (Media, ignoriert) | PVR Musik | 8.5G (1.2G lidarr.db) | Config-only (Stop-Fenster) |
| 4 | bazarr (arr-stack) | SQLite in `/config` | `/opt/docker/bazarr`; `/mnt/media/video/*` (Subtitle-Quelle, ignoriert) | Subtitle-Manager | 58M | Config-only (Stop-Fenster) |
| 5 | radarr (arr-stack) | SQLite (`radarr.db` in `/config`) | `/opt/docker/radarr`; `/mnt/media/video/movies`, `/opt/downloads/completed` (Media, ignoriert) | PVR Filme | 2.7G (2.5G MediaCover) | Config-only (Stop-Fenster) |
| 6 | prowlarr (arr-stack) | SQLite (`prowlarr.db` in `/config`) | `/opt/docker/prowlarr` | Indexer-Manager | 88M | Config-only (Stop-Fenster) |
| 7 | sabnzbd (arr-stack) | — (INI-Konfiguration) | `/opt/docker/sabnzbd`; `/opt/downloads/*` (Downloads, ignoriert) | Usenet-Downloader | 29M | Config-only (Stop-Fenster) |
| 8 | overseerr (arr-stack) | SQLite in `/app/config` | `/opt/docker/overseerr` | Request-Manager | 8.3M | Config-only (Stop-Fenster) |
| 9 | castopod (castopod) | MariaDB 11.2 (`castopod_mariadb`, `/opt/docker/castopod/mariadb`); Redis (Cache) | `/opt/docker/castopod/app/media` (Podcast-Media), `/opt/docker/castopod/redis` (Cache) | Podcast-Plattform | 2.3G (2.2G app, 167M mariadb) | DB-Dump + Datei-Rsync-Restic (app/media) |
| 10 | codex (media) | — | `/opt/docker/codex/config`; `/mnt/media/library/comics` (Media, nur lesend, ignoriert) | Comic-Reader | 20M | Config-only |
| 11 | crawl4ai (local-ai) | — | keine persistenten Bind-Mounts | Crawler | — | ignorieren |
| 12 | 5etools (content) | — | `/opt/docker/5etools` (statische Site) | Statische Website | 6.9G (6.8G img) | Config-only (Datei-Rsync-Restic, statisch) |
| 14 | firecrawl (firecrawl) | Redis (Queue/Crawl-State) | Named Volume `redis-data` (kein Bind-Mount) | Crawler-API | n/a | ignorieren (Queue-Status reproduzierbar) |
| 15 | forgejo (forgejo) | SQLite/interne DB in `/data` (Standard-Setup, kein separater DB-Container) | `/opt/docker/forgejo/data` (Repos+DB), `/opt/docker/forgejo/runner` | Git-Hosting + CI | 15G (15G data, 655M runner) | DB-Dump (forgejo dump) + Datei-Rsync-Restic |
| 16 | ghost (ghost) | MySQL 9 (`ghost-mysql`, `/opt/docker/ghost/mysql`); ActivityPub nutzt dieselbe MySQL-Instanz | `/opt/docker/ghost/ghost` (Content: Images, Themes) | Blog | 671M (411M mysql, 261M content) | DB-Dump (mysqldump beider Schemas) + Datei-Rsync-Restic (content) |
| 17 | crowdsec (infra) | SQLite intern (`/var/lib/crowdsec/data`) | `/opt/docker/crowdsec/config`, `/opt/docker/crowdsec/data` | IPS/IDS | 37M | Config-only |
| 18 | homepage (content) | — | `/opt/docker/homepage` (YAML-Konfiguration) | Dashboard | 68K | Config-only |
| 19 | immich (immich) | PostgreSQL 14 (`immich_postgres`, `/opt/docker/immich/postgres`) | `/mnt/immich` (UPLOAD_LOCATION — Fotos/Videos) | Foto-Management | n/a (NAS-Pfad; DB-dir 8K) | DB-Dump (pg_dump) + Datei-Rsync-Restic (/mnt/immich) |
| 20 | litellm (local-ai) | PostgreSQL 16 (`litellm_db`, `/opt/docker/litellm/postgres_data`) | `/opt/docker/litellm/config.yaml` (Config-Datei) | LLM-Proxy | 12K | DB-Dump + Config-only |
| 22 | plex (media) | — (DBs in `/config`) | `/opt/docker/plex/conf`; `/mnt/media/**` (Media, ignoriert) | Mediaserver | 53G (conf) | Config-only |
| 23 | tautulli (media) | SQLite (`tautulli.db` in `/config`) | `/opt/docker/tautulli`; `/mnt/media/**` (ignoriert) | Plex-Stats | 1.1G (897M cache!) | Config-only (Stop-Fenster; cache ausschließen) |
| 24 | audiobookshelf (media) | SQLite in `/config` | `/opt/docker/audiobookshelf/config`, `/opt/docker/audiobookshelf/metadata`; `/mnt/media/audiobooks` (Media, ignoriert) | Hörbuch-Server | 45G (45G metadata!) | Config-only (Stop-Fenster) — metadata prüfen (siehe TODOS) |
| 25 | metube (media) | — | `/mnt/media/video/youtube` (Downloads direkt in Media) | YouTube-Downloader | n/a | ignorieren (Downloads liegen in Media-Library) |
| 26 | calibre-web (media) | SQLite (`app.db` in `/config`) | `/opt/docker/calibre-web`; `/mnt/media/library/calibre` (Bücher, ignoriert) | E-Book-Server | 368K | Config-only (Stop-Fenster) |
| 27 | dashdot + uptime-kuma + grafana (monitoring) | SQLite `kuma.db` (uptime-kuma); Grafana: internes SQLite/DB in `/var/lib/grafana` | `/opt/docker/uptime-kuma`, `/opt/docker/grafana/data`, `/opt/docker/grafana/logs` | Monitoring | 226M (kuma 222M), 662M (grafana) | Config-only (Stop-Fenster für kuma.db); dashdot ignorieren |
| 28 | n8n (n8n) | PostgreSQL 16 (`n8n-db`, `/opt/docker/n8n/postgres`) | `/opt/docker/n8n/data` (`.n8n`-Ordner mit Encryption-Key!) | Workflow-Automation | n/a | DB-Dump (pg_dump) + Datei-Rsync-Restic (.n8n) |
| 29 | omada-controller (infra) | — (interne DB in `data`) | `/opt/docker/omada/data`, `/opt/docker/omada/work` | Netzwerk-Controller | 391M (123M data) | Config-only (Stop-Fenster) |
| 30 | node-red (node-red) | — (Flows in JSON-Dateien in `/data`) | `/opt/docker/node-red` | Flow-Editor | n/a | Config-only (Datei-Rsync-Restic) |
| 32 | opencloud (opencloud) | — (kein DB-Server; Metadaten im Dateisystem, inkl. BoltDB in `/var/lib/opencloud`) | `/mnt/opencloud` (OC_DATA_DIR — Dateien+Metadaten), `/opt/docker/opencloud` (Config mit Secrets!) | Cloud-Storage | n/a (NAS) | Datei-Rsync-Restic (/mnt/opencloud) + Config-only (/etc-Konfig); Hersteller empfiehlt Stop-Fenster |
| 33 | paperless (paperless) | PostgreSQL 15 (`paperless-db`, `${DOCKER_DATA_PATH}/paperless/db`); Redis (Broker, Cache) | `${NAS_DATA_PATH}/data`, `${NAS_DATA_PATH}/media`, `${NAS_DATA_PATH}/export` (= `/mnt/paperless/*`); `/opt/docker/paperless-ai` | DMS | n/a (NAS) | DB-Dump (pg_dump) + Datei-Rsync-Restic (data+media) + document_exporter optional |
| 34 | searxng (local-ai) | Valkey/Redis (Cache) | `/opt/docker/searxng/etc` (Config), `/opt/docker/searxng/data` (Cache) | Meta-Suchmaschine | 204K | Config-only (etc); data ignorieren |
| 35 | homeassistant (smarthome) | SQLite (`home-assistant_v2.db`, `zigbee.db` in `/config`) | `/opt/docker/homeassistant` (Config inkl. YAML + SQLite) | Smart Home | 766M (671M DB) | Config-only (Stop-Fenster) — YAML-Konfig ist der eigentliche Schatz, DB groß |
| 36 | music-assistant (smarthome) | SQLite (`library.db`, `auth.db` in `/data`) | `/opt/docker/music-assistant` | Musik-Server | 1.3G (215M library.db) | Config-only (Stop-Fenster) |
| 37 | mosquitto (smarthome) | — | `/opt/docker/mosquitto/config`, `/opt/docker/mosquitto/data` (Retained Messages) | MQTT-Broker | 4.6M | Config-only |
| 38 | matter-server (smarthome) | — (SQLite/Matter-State in `/data`) | `/opt/docker/python-matter-server/data` | Matter-Bridge | 2.0M | Config-only (Stop-Fenster) |
| 40 | tdarr (media) | — (Library-DB in `/app/server`) | `/opt/docker/tdarr/server`, `/opt/docker/tdarr/configs`; `/mnt/media/video` (Media, ignoriert), `/mnt/media/cache` (Temp, ignoriert) | Transcoder | 1.2G (2.2G server) | Config-only (Stop-Fenster) |
| 41 | vaultwarden (vaultwarden) | SQLite (`db.sqlite3` in `/data`, WAL-Modus!) | `/opt/docker/vaultwarden` (attachments, sends, rsa_key.pem, db.sqlite3) | Passwort-Manager | 5.2M | DB-Dump (sqlite3 .backup) + Datei-Rsync-Restic (attachments, sends, rsa_key) |
| 42 | wanderer (wanderer) | PocketBase (`flomp/wanderer-db`, `/opt/docker/wanderer/db`); Meilisearch (`search`, `/opt/docker/wanderer/search` — rekonstruierbar) | `/opt/docker/wanderer/db`, `/opt/docker/wanderer/uploads`, `/opt/docker/wanderer/plugins` | Wander-Plattform | 354M (347M db) | Datei-Rsync-Restic (db mit Stop-Fenster, uploads, plugins); search ignorieren |
| 43 | web-proxy (web-proxy) | — | `/opt/docker/nginx` (conf, vhost, certs, htpasswd), `/opt/docker/acme` (ACME-State); logs ignorieren | Reverse Proxy + TLS | 2.5G (2.4G logs — ausschließen) | Config-only (conf, certs, vhost, htpasswd; logs/ignorieren); `/opt/docker/yauh` statische Site |

## Zusätzlich im Snapshot vorhanden, aber nicht in `projects/` (Komplettierungs-Hinweis)

Der Host-Snapshot zeigt weitere Verzeichnisse unter `/opt/docker/`, die **nicht** durch `projects/` abgedeckt sind: `omada` (network-Stack, abgedeckt), `calibre-web` (abgedeckt), aber auch `delete-influxdb2` (Stilllegung), `delete-postgres` (Stilllegung), `mosquitto`/`python-matter-server`/`homeassistant`/`music-assistant` (smarthome), `redis`, `valkey` (Einzel-Instanzen), `tautulli`, `plex`, `metube` (media), `yauh` (web-proxy), `acme`, `5etools`, `crowdsec`, `forgejo`, `ghost`, `litellm`, `shynet`, `castopod`, `audiobookshelf`, `codex`, `dockerfiles`, `compose`, `rsync-excludes.txt`. Stilllegungs-Kandidaten (`delete-*`) werden ignoriert. Einige Dienste des Snapshots (metube, plex, tautulli, …) laufen als Container, sind aber in `projects/`-Stacks anders gruppiert — die Tabelle oben folgt den `projects/`-Stacks als der vom Auftrag geforderten Struktur.

## Zusammenfassung Kategorien

- **ignorieren**: crawl4ai, firecrawl, metube (Zielverzeichnisse), Media-Libraries (`/mnt/media/**`), Downloads (`/opt/downloads`), Logs, Caches (tautulli/cache, searxng/data, MediaCover optional), Redis/Valkey-Caches, dashdot, Meilisearch-Index (wanderer/search)
