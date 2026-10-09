# Backup-Strategie (v1.0.0 — Auto-Discovery)

## Grundprinzip

Die Wahrheit der Services lebt in Docker (Container, Mounts, ENV) — nicht im Repo. Der Dispatcher entdeckt laufende Container automatisch:

- **Findest du einen Mount, sicher ihn** (Bind-Mounts = Datei-Backup per rsync).
- **Laeuft eine DB, dump sie** (Postgres/MariaDB/MySQL aus Container-ENV erkannt; Root-Dump wegen RELOAD/FLUSH-Privilegien).
- **Default-Excludes**: logs, caches, tmp — Rebuildbares wird nicht gesichert (Compute beim Restore ist ok).
- **Thumbnails: Default nein** (rebuildbar via Library-Scan). Einzelfall-Overrides via policies.d.

## Architektur

- `backup.sh` — Dispatcher mit Auto-Discovery, Filtern (`--service`, `--project`, `--dry-run`, `--discover`), PARTIAL-Zaehler.
- `lib/discovery.sh` — Container-Inventarisierung (Mounts, ENV-Credentials, Labels).
- `lib/db.sh` — DB-Dumps (postgres/mysql/mariadb/sqlite/forgejo/surreal).
- `lib/common.sh` — Logging (mit Versionsstempel), Locking, Rotation, rsync/Restic.
- `policy.conf` — globale Defaults (IGNORE_PATH_PREFIXES, DEFAULT_FILE_EXCLUDES).
- `policies.d/<project>.env` / `policies.d/<container>.env` — Ausnahmen; Container-Policy gewinnt.
- `restore.sh <container>` — nutzt dieselbe Discovery+Policy; Restore pro Container.
- `test-restore.sh` — Dump-Qualitaetstest in Wegwerf-Containern (Postgres + MariaDB); ohne Argument werden alle DB-Services getestet, einzelner Service als Argument.

## Rotation & Retention

rsnapshot-artig `v.0..v.N` (`KEEP_VERSIONS`, Default 14), kein Timestamp im Pfad — Restore und Cron bleiben stabil. Hardlink-Dedupe gegen Vortagesversion (`--link-dest`).

## Policies (policies.d/)

- `SVC_IGNORE=true` — Container ausschliessen
- `EXTRA_FILE_PATHS=( ... )` — zusaetzliche Pfade
- `EXTRA_FILE_EXCLUDES=( ... )` — zusaetzliche Excludes
- `STOP_SELF=true` — Stop-Fenster (konsistente SQLite/Dateien)
- `KEEP_FILES=true` — DB-Container-Rohdaten trotzdem sichern
- `DB_DUMP_ALL=true` — pg_dumpall (immich)
- `DB_TYPE=sqlite|forgejo`, `SQLITE_FILES=( "host:container" )`

Siehe `tools/backup/policies.d/README.md`.
