# Deployment on the Docker host

Guide to bring the backup system up on the Ubuntu Docker host and run a test.

## Architecture: what lives where?

```
/opt/docker/arcane/            repo (compose stacks + .env — the SOURCE)
└── projects/<stack>/compose.yaml + .env
/opt/docker/tools/             home of all host tools (the INSTALLATION)
├── backup/                    backup system (installed via tools/install.sh)
│   ├── backup.sh              dispatcher
│   ├── restore.sh             restore per service
│   ├── test-restore.sh         dump restore test
│   ├── install.sh              (installation only; the copier)
│   ├── lib/                    common.sh, db.sh
│   ├── policies.d/*.env        policy overlays (installed copy)
│   └── docs/                   reference documentation
└── maintenance/               docker-maintenance.sh (prune, incl. volumes)
/opt/docker/compose/compose.yml   Arcane bootstrap (maintained by hand, NOT by the installer — secrets!)
/etc/backup.conf               configuration: source, target, restic (chmod 600)
/mnt/systems/backups/<host>/   TARGET on the NAS (db/ + files/ + logs/)
```

The host tools deliberately do **not** live in the repo checkout (`/opt/docker/arcane`): the installer copies **all tools** (backup system + maintenance) to `/opt/docker/tools` (configurable via `--home`). Repo updates do not overwrite the installation; re-running `install.sh` updates it (policies in `policies.d/`/`policy.conf` may remain individually adjusted, `rsync` without `--delete`).

**Where do source and target come from?** Explicitly from `/etc/backup.conf`:

- `STACKS_DIR` — where compose stacks and their `.env` live (e.g. `/opt/docker/arcane/projects`). Declarations use the placeholder `%STACKS_DIR%` (e.g. `ENV_FILE=%STACKS_DIR%/ghost/.env`), which the dispatcher resolves. This keeps declarations host-agnostic.
- `BACKUP_ROOT` — target on the NAS (`/mnt/systems/backups/<host>`).
- `POLICY_DIR` — policy home (when installed: `/opt/docker/tools/backup/policies.d`).

## Step 1: Prerequisites

- Ubuntu host with root access, Docker running
- Repo checkout under `/opt/docker/arcane` (update: `sudo git pull`)
- NAS mount `/mnt/systems` in place: `findmnt /mnt/systems`

## Step 2: Arcane bootstrap (once, by hand)

**Arcane does not run from the repo project directory.** Arcane cannot host itself (bootstrap problem: the management UI cannot manage the compose stack that starts it). The Arcane container therefore runs from a host-side compose file: `/opt/docker/compose/compose.yml` (repo template: `bootstrap/compose.yml`; compose project name `base`, image `ghcr.io/getarcaneapp/arcane:latest`, mounts on `/opt/docker/arcane/data` and `/opt/docker/arcane/projects`).

**Important:** The installer deliberately never touches this compose file — it contains secrets (`ENCRYPTION_KEY`, `JWT_SECRET`) that must not be overwritten. Set it up once by hand:

```bash
sudo mkdir -p /opt/docker/compose
sudo cp bootstrap/compose.yml /opt/docker/compose/compose.yml
sudo vi /opt/docker/compose/compose.yml   # replace REPLACE_ME values: openssl rand -hex 32
cd /opt/docker/compose && docker compose up -d
```

Later updates:

```bash
cd /opt/docker/compose
docker compose pull && docker compose up -d   # update Arcane (base project)
```

All **other** stacks are managed as projects by Arcane (`/opt/docker/arcane/projects`).

## Step 3: Installation

```bash
cd /opt/docker/arcane
sudo git pull
sudo tools/install.sh \
  --home /opt/docker/tools \
  --stacks-dir /opt/docker/arcane/projects \
  --backup-root /mnt/systems/backups/<host>
```

The installer:

1. copies `backup.sh`, `restore.sh`, `test-restore.sh`, `lib/`, `policies.d/`, `policy.conf` to `/opt/docker/tools/backup`
2. copies `maintenance/` to `/opt/docker/tools/maintenance` and `docs/` to `/opt/docker/tools/docs`
3. creates `/etc/backup.conf` (with `chmod 600`) or adds missing entries to an existing file

Alternatively without parameters — the installer asks interactively for the source path.

## Step 4: Check the configuration

```bash
sudo cat /etc/backup.conf
```

Minimum content:

```bash
STACKS_DIR=/opt/docker/arcane/projects      # source: compose + .env
BACKUP_ROOT=/mnt/systems/backups/<host>      # target: NAS (one subdirectory per host)
POLICY_DIR=/opt/docker/tools/backup/policies.d  # home of the policy overlays
USE_RESTIC=false
```

## Step 5: Dry run (changes nothing)

```bash
sudo /opt/docker/tools/backup/backup.sh --dry-run
```

Expectation: per service `[DRY]` lines with the exact `docker exec`/rsync commands, at the end an `OK / FAIL / SKIP / PARTIAL` summary (numbers depend on the host — on the reference host e.g. `OK=39 FAIL=0 SKIP=7 PARTIAL=0`; SKIP = dedupe and ignored services). `WARN` about missing paths means: check the source.

## Step 6: Limited first real run

```bash
sudo /opt/docker/tools/backup/backup.sh --service litellm_db
sudo ls -la /mnt/systems/backups/<host>/litellm_db/db/*/
```

`--service` expects the **container name** (e.g. `litellm_db`), not the stack. For a whole stack: `--project <stack>` (e.g. `--project local-ai`).

## Step 7: Full test run

```bash
sudo /opt/docker/tools/backup/backup.sh
sudo grep FAIL /mnt/systems/backups/<host>/logs/<latest-stamp>.log
```

Individual failures do not isolate other services (error isolation per declaration). Stop-window services (e.g. media services with SQLite, Home Assistant, Kuma …) are briefly down — cron-suitable at night.

**SKIP semantics (preflight):** before every backup the dispatcher checks whether the source exists (DB containers via `docker inspect`, file paths via the filesystem). Result:

- Source fully present → normal backup.
- DB container missing/not running but files present (or vice versa) → **partial backup** with `WARN`, no FAIL.
- Source missing entirely (service not deployed, container unknown, paths wrong) → **SKIP** with `INFO`, no FAIL. The run stays green.
- Incorrectly declared services (DB category without `DB_TYPE`, empty `FILE_PATHS`) remain FAIL — that is a declaration error, not a host state.
- Docker daemon unreachable (real run) → hard abort instead of 43 SKIPs.

`SKIP` therefore means one of two things: declared as `ignore` OR "source not present on this host". The gap list at the end of the run (`WARN - DB container missing: …`) shows exactly which services are not deployed — shipping without FAIL alarms is possible.

## Step 8: Restore test

```bash
sudo /opt/docker/tools/backup/test-restore.sh          # all DB services (default)
sudo /opt/docker/tools/backup/test-restore.sh litellm_db   # only one service
```

## Step 9: Enabling cron

```bash
sudo crontab -e
```

```cron
30 2 * * * /opt/docker/tools/backup/backup.sh >> /var/log/backup-dispatcher.log 2>&1
30 4 1 * * /opt/docker/tools/maintenance/docker-maintenance.sh >> /var/log/docker-maintenance.log 2>&1
```

The maintenance line (monthly, 1st of the month at 04:30) deliberately prunes volumes too (the `--volumes` behavior is the default; `--no-volumes` disables it). It never runs in parallel with backups — the script aborts by itself if a backup/restore process is running (stop-window containers would otherwise be loss candidates).

`flock` is built into the dispatcher (parallel runs are blocked) — **do not add an external `flock` wrapper**: the same lockfile used externally and internally blocks itself and makes every cron run abort immediately. After the test run, check the cron times against the actual runtime (large rsync targets like `/mnt/immich` — consider a weekly cadence for the immich file share if needed).

## Versioning & retention (rsnapshot style)

Target paths contain **no timestamps**. Every service has rotating versions:

```text
/mnt/systems/<host>/backups/<service>/db/v.0     <- latest state
                                                 v.1 ... v.KEEP_VERSIONS-1
```

- Before every backup the dispatcher shifts per service `v.0 -> v.1 -> ... -> v.N-1`; the oldest version (`rm -rf v.$((KEEP_VERSIONS-1))`) is dropped.
- `KEEP_VERSIONS` (default: **14**) is configurable in `/etc/backup.conf` — e.g. `KEEP_VERSIONS=30`.
- rsync uses `--link-dest=v.1`: unchanged files are hardlinks to the previous day — only real changes per version, storage demand stays flat (NFS supports hardlinks; on CIFS it runs without linking and then uses more space).
- Timestamps are not in the path but in the log: every stdout and log line starts with `YYYY-MM-DD HH:MM:SS` — step durations are directly readable.
- Restore by version instead of date: `restore.sh <service>` (latest version = `v.0`) or `restore.sh <service> --version v.3`.
- At the end of each run the **consistency check** verifies all target states: does `v.0` exist, is it non-empty, do DB states contain at least one dump > 0 bytes. Problems appear as `WARN` in the log.
- Old timestamp-based states (before this change) remain readable via the `latest_dir` fallback in the restore.

## Step 10: Restic (optional)

```bash
sudo apt-get install -y restic
sudo sh -c 'openssl rand -base64 32 > /etc/restic-password && chmod 600 /etc/restic-password'
# in /etc/backup.conf: USE_RESTIC=true
```

## Monitoring & operations

- Last run: `cat /mnt/systems/backups/<host>/logs/last-run-summary.txt`
- Logs: `ls -t /mnt/systems/backups/<host>/logs/ | head -1`
- Catch up a service: `sudo /opt/docker/tools/backup/backup.sh --service <container-name>` (whole stack: `--project <stack>`)
- Restore: `docs/RESTORE.md`, start with `--dry-run`

## Updating the backup system

Apply repo changes (new declarations, fixes):

```bash
cd /opt/docker/arcane && sudo git pull
sudo tools/install.sh --stacks-dir /opt/docker/arcane/projects --backup-root /mnt/systems/backups/<host>
```

`install.sh` updates the installation (rsync without `--delete`: locally adjusted declarations are preserved).

## Security notes

- The dispatcher runs as root (Docker socket, stop windows). `/etc/backup.conf` with `chmod 600`.
- Passwords never on process command lines (`MYSQL_PWD` via `docker exec -e`), dumps unencrypted on the NAS — enable restic if needed.
- With the NAS unmounted the dispatcher refuses to start (`require_mounted_target`) instead of writing locally.
