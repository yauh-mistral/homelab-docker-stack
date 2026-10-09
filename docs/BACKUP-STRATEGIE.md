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

## Policies: Defaults & Konfigurationsebenen

Das Backup-Verhalten ist drei Ebenen konfigurierbar — spätere Ebenen gewinnen:

1. **Globale Defaults** — `tools/backup/policy.conf`:
   - `ALLOW_PATH_PREFIXES=( "/opt/docker" )` — Allowlist der Backup-Quellen; alles außerhalb (NAS `/mnt`, Downloads, OS-Runtime) wird nie gesichert.
   - `DEFAULT_FILE_EXCLUDES=( "logs/" "log/" "*.log" "tmp/" "cache/" "Cache/" "cache_*/" )` — Rebuildbares (Logs, Caches, tmp) wird nie übertragen.
   - `SKIP_MOUNT_BASENAMES=( "logs" "log" )` — Mounts, die nur Logger-Verzeichnisse sind, werden als Quelle übersprungen.
   - `THUMBNAILS=false` — Thumbnails standardmäßig nicht sichern (rebuildbar via Library-Scan).
2. **Host-Konfiguration** — `/etc/backup.conf` (überschreibt Defaults): `STACKS_DIR` (Quelle), `BACKUP_ROOT` (NAS-Ziel), `POLICY_DIR` (Policy-Heimat), `KEEP_VERSIONS` (Rotationstiefe, Default 14), `USE_RESTIC` (optional, heute aus).
3. **Service-/Stack-Overlays** — `policies.d/<project>.env` (Stack-Defaults) und `policies.d/<container>.env` (Container-spezifisch, gewinnt):

| Policy | Wirkung |
|---|---|
| `SVC_IGNORE=true` | Container komplett aus dem Backup ausschließen |
| `EXTRA_FILE_PATHS=( ... )` | Zusätzliche Pfade sichern (über die entdeckten Mounts hinaus) |
| `EXTRA_FILE_EXCLUDES=( ... )` | Zusätzliche Excludes (z.B. `MediaCover/ Backups/` bei arr-Services, Plex-Caches) |
| `STOP_SELF=true` | Stop-Fenster: Container während des Datei-Backups stoppen (konsistente SQLite/Dateien) |
| `KEEP_FILES=true` | DB-Container-Rohdaten zusätzlich als Dateien sichern |
| `DB_DUMP_ALL=true` | `pg_dumpall` statt `pg_dump` (ganzer Cluster, z.B. immich) |
| `DB_TYPE=sqlite\|forgejo` | Spezial-Dump-Typ statt Standard-DB-Erkennung |
| `SQLITE_FILES=( "host:container" )` | SQLite-Pfade (host:container) für Online-Backup |

Reihenfolge: `policy.conf` (Defaults) → `/etc/backup.conf` (Host) → `policies.d/<project>.env` (Stack) → `policies.d/<container>.env` (Container). Siehe auch `tools/backup/policies.d/README.md`.
