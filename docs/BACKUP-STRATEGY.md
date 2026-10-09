# Backup Strategy (v1.0.0 — auto-discovery)

## Core principle

The truth about services lives in Docker (containers, mounts, env) — not in the repo. The dispatcher discovers running containers automatically:

- **Find a mount, back it up** (bind mounts = file backup via rsync).
- **Running database? Dump it** (Postgres/MariaDB/MySQL detected from container env; root dump because of RELOAD/FLUSH privileges).
- **Default excludes**: logs, caches, tmp — rebuildable data is not backed up (compute at restore time is fine).
- **Thumbnails: no by default** (rebuildable via library scan). Case-by-case overrides via policies.d.

## Architecture

- `backup.sh` — dispatcher with auto-discovery, filters (`--service`, `--project`, `--dry-run`, `--discover`), PARTIAL counter.
- `lib/discovery.sh` — container inventory (mounts, env credentials, labels).
- `lib/db.sh` — DB dumps (postgres/mysql/mariadb/sqlite/forgejo/surreal).
- `lib/common.sh` — logging (with version stamp), locking, rotation, rsync/restic.
- `policy.conf` — global defaults (IGNORE_PATH_PREFIXES, DEFAULT_FILE_EXCLUDES).
- `policies.d/<project>.env` / `policies.d/<container>.env` — exceptions; the container policy wins.
- `restore.sh <container>` — uses the same discovery + policies; restore per container.
- `test-restore.sh` — dump quality test in throwaway containers (Postgres + MariaDB); without an argument all DB services are tested, a single service can be passed as argument.

## Rotation & retention

rsnapshot-style `v.0..v.N` (`KEEP_VERSIONS`, default 14), no timestamps in paths — restore and cron stay stable. Hardlink deduplication against the previous version (`--link-dest`).

## Policies: defaults & configuration levels

Backup behavior is configurable on three levels — later levels win:

1. **Global defaults** — `tools/backup/policy.conf`:
   - `ALLOW_PATH_PREFIXES=( "/opt/docker" )` — allowlist of backup sources; everything outside (NAS `/mnt`, downloads, OS runtime) is never backed up.
   - `DEFAULT_FILE_EXCLUDES=( "logs/" "log/" "*.log" "tmp/" "cache/" "Cache/" "cache_*/" )` — rebuildable data (logs, caches, tmp) is never transferred.
   - `SKIP_MOUNT_BASENAMES=( "logs" "log" )` — mounts that are only logger directories are skipped as sources.
   - `THUMBNAILS=false` — thumbnails are not backed up by default (rebuildable via library scan).
2. **Host configuration** — `/etc/backup.conf` (overrides defaults): `STACKS_DIR` (source), `BACKUP_ROOT` (NAS target), `POLICY_DIR` (policy home), `KEEP_VERSIONS` (rotation depth, default 14), `USE_RESTIC` (optional, currently off).
3. **Service/stack overlays** — `policies.d/<project>.env` (stack defaults) and `policies.d/<container>.env` (container-specific, wins):

| Policy | Effect |
|---|---|
| `SVC_IGNORE=true` | Exclude the container from backup entirely |
| `EXTRA_FILE_PATHS=( ... )` | Back up additional paths (beyond the discovered mounts) |
| `EXTRA_FILE_EXCLUDES=( ... )` | Additional excludes (e.g. cover caches, Plex metadata caches) |
| `STOP_SELF=true` | Stop window: stop the container during file backup (consistent SQLite/files) |
| `KEEP_FILES=true` | Additionally back up DB container raw data as files |
| `DB_DUMP_ALL=true` | `pg_dumpall` instead of `pg_dump` (whole cluster, e.g. immich) |
| `DB_TYPE=sqlite\|forgejo` | Special dump type instead of standard DB detection |
| `SQLITE_FILES=( "host:container" )` | SQLite paths (host:container) for online backup |

Order: `policy.conf` (defaults) → `/etc/backup.conf` (host) → `policies.d/<project>.env` (stack) → `policies.d/<container>.env` (container). See also `tools/backup/policies.d/README.md`.
