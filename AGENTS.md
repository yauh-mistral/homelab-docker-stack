# AGENTS.md — Collaboration guidelines for homelab-docker-stack

## Repo purpose & documentation layout

- This repo covers the **host's entire Docker landscape**: compose stacks (`projects/`), the host tools (`tools/`: `backup/` backup system, `maintenance/` Docker housekeeping/prune; the installer installs all tools to `/opt/docker/tools/`), the Arcane bootstrap (`bootstrap/compose.yml` — maintained by hand, contains secrets, never touched by the installer), and the in-depth documentation (`docs/`). The centerpiece is **Arcane** as the management UI under which all stacks run as projects. Tool installation path on the host: `/opt/docker/tools/` (backup system under `/opt/docker/tools/backup`).
- **README.md** = overview: components, stacks, relationships (including Mermaid diagram), short summaries linking to docs/. **No step-by-step guides in the README.**
- **docs/** = in-depth: DEPLOYMENT.md (installation/bring-up/cron), BACKUP-STRATEGY.md (strategy/policy reference), RESTORE.md (restore), TODOS.md (open todos).
- **Redundancy rule**: every topic has exactly one detailed home; the other place links with a short summary. Never maintain content in two places — when changing, check both locations or deliberately keep the summary generic.

## Docker projects (`projects/`)

- **Creating stacks**: every stack lives in `projects/<stack>/` with a `compose.yaml` (plus optional `.env.example`). No `.env` in the repo (see .env conventions below).
- **Arcane as management**: stacks are managed as projects in Arcane. The repo is the declaration source; deployment status is determined at runtime (discovery uses `docker ps`, not the repo).
- **Adding/removing services**: edit the stack's `compose.yaml` (or create a new stack), maintain `.env.example`, fill in the real `.env` on the host, then `docker compose up -d`. The backup dispatcher must handle removed services gracefully (SKIP).
- **Bind-mount convention**: persistent data under `/opt/docker/<service>/`. Docker volumes are never used for data that needs backing up. NAS mounts (`/mnt/...`) are never a backup source.
- **Backup integration**: new services with a running database or mounts are detected and backed up automatically by auto-discovery. Only for special cases (rebuildable data, caches, DB tool adjustments) create a policy in `tools/backup/policies.d/` — with a justification comment so the exception remains comprehensible later.

## Target & environment

- **Target system**: Ubuntu 26.04 with Docker (Docker host). Services can be deployed, started, stopped, or removed at any time — the backup dispatcher must cope with this (SKIP for undeployed services, partial backup when half the source is missing, never a silent fake success).
- **Data storage**: persistent data lives in bind mounts on the host filesystem (`/opt/docker/...`), including databases. **Docker volumes are never used for data that needs backing up.** NAS mounts (`/mnt/...`) are never a backup source — the NAS has its own backup.
- **Restore philosophy**: a restore must work with minimal data. Fully backed up: user data (media etc.), configuration, metadata, permissions. **Not backed up**: thumbnails, logs, temporary files — anything the container regenerates on start. **Compute/time during restore is acceptable if it makes the backup shorter and smaller.**
- **No duplicate backups**: if data exists both on disk and in a database and can be reconstructed from either, back up only one (example: Forgejo repos vs. `forgejo dump --skip-repository`).

## Git/PR workflow (important!)

- **Before every new PR**: check whether an open PR already exists that could be extended — update the existing PR (push to its branch) instead of opening a new one. Check the branch head; use `--force-with-lease` on rewrites.
- **Never assume a change is automatically integrated into an open PR** — check merge status and branch divergence (this has already happened three times: fixes were at risk of disappearing behind a merge).
- **Hard rule — no push to a branch whose PR is already merged.** Before EVERY push: check `gh pr list --state all` or the PR status of the branch. If the PR was merged (even seconds ago), every new change belongs on a **fresh branch from current `origin/main`** with its own PR. A push to a dead branch effectively discards the change — it will never reach main on its own.
- Branches: `vibe/<slug>-5f329e`, draft PRs as the default, no pushes to `main`.
- Commits focused and descriptive; PR body with summary + verification.

## Versioning

- **Release v1.0.0 (stable, E2E verified).** The first complete end-to-end test passed (discovery → dry run → real run → restore test of all DB services, Postgres + MariaDB). `SCRIPT_VERSION="v1.0.0"` in `tools/backup/lib/common.sh` is the stable release state, marked as tag `v1.0.0` on GitHub.
- **Semantic versioning mode (active).** From v1.0.0, SemVer applies: MAJOR = breaking (config/declaration format/CLI), MINOR = feature, PATCH = fix. Every substantive change bumps `SCRIPT_VERSION` accordingly; `SCRIPT_BUILD` (PR number) continues alongside as a patch-level identifier.
- **`SCRIPT_BUILD`** (PR number) is appended automatically by the GitHub Action `.github/workflows/build-number.yml` after every merge (reads `(#N)` from the merge commit subject). No manual maintenance required.
- `SCRIPT_VERSION` applies **only** to `tools/backup/` (`backup.sh`, `restore.sh`, `test-restore.sh`; the installer lives one level up as `tools/install.sh`) — helper scripts like `tools/maintenance/docker-maintenance.sh` get **no** version number.
- `install.sh` stamps the installed copy with the installation time (`INSTALL_STAMP`, `YYYY-MM-DD HH:MM`) and `SCRIPT_BUILD`. Every log starts with the version line (`vX.Y.Z+#<PR> <stamp>`) — outdated states are immediately recognizable.

## .env conventions

- **`.env` files are never shipped** — always only `.env.example` with masked values (`REPLACE_ME`).
- **The truth lives on the host** in `/opt/docker/arcane/projects/<project>/.env` (or `STACKS_DIR`). The repo never duplicates credentials.
- **Same purpose = same name**: DB credentials are named uniformly after the DB system (`POSTGRES_PASSWORD`, `MARIADB_ROOT_PASSWORD`, ...); compose `environment:` names may be service-specific (compose maps them).
- Secret masking with **sensible generation hints**: passwords `openssl rand -base64 24`, secrets/keys `openssl rand -hex 32`, salts `-hex 32`; **SMTP passwords come from the mail provider** (do not generate); **self-hosted tokens** (vaultwarden `ADMIN_TOKEN`) set once manually; external API keys are created at the provider. Do not duplicate existing comment explanations above the variable.

## Backup system design (v1.0.0)

- **Auto-discovery (v1.0.0)**: the dispatcher reads running containers (`docker ps`), derives bind mounts (file backup) and DB type/credentials from container env (`POSTGRES_*`/`MYSQL_*`/`MARIADB_*`). Static `services.d/` declarations are REMOVED. rsnapshot-style rotation (`v.0..v.N`), no timestamps in paths.
- Policies only for exceptions: `tools/backup/policy.conf` (global defaults: IGNORE_PATH_PREFIXES=/mnt,/tmp,/var/tmp; DEFAULT_FILE_EXCLUDES for logs/caches) + `tools/backup/policies.d/<project|container>.env` (container policy wins): EXTRA_FILE_PATHS/EXCLUDES, STOP_SELF, KEEP_FILES, DB_DUMP_ALL, DB_TYPE=sqlite|forgejo, SQLITE_FILES, SVC_IGNORE.
- **Resolved construction sites (v1.0.0)**: PARTIAL counter in summary, rsync exit code + output in log, vaultwarden SQLite bind-mount resolution, ghost root dump (root credentials from container env), `--list`/`--discover` without requiring STACKS_DIR.

## Style & communication

- English as working language; concise; document version/format conventions instead of assuming them implicitly.
- Logs: uniform ISO-like timestamps, no unprefixed tool output, no selling partial backups as full OK, summary line with numbers at the end of each run.
- When unsure about a secret's status: mask conservatively and document in the PR; the owner decides.
- Scalpel, not lawnmower: no functional side changes when harmonizing format/structure (step-5 principle of the env migration).
