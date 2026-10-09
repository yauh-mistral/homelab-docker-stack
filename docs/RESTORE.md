# Restore guide per backup category

> ⚠️ **UNTESTED — WORK IN PROGRESS.** `restore.sh` has never been executed against a real target system. The procedures described here are plausible but unverified. Before any production restore: check the instructions step by step against the current code, run `--dry-run` first, and if possible test against a throwaway target. Until verified: restore guide `docs/RESTORE.md` = reference, `restore.sh` = experimental.

General: `backup/restore.sh <service> [--version v.N] [--dry-run] [--db-only] [--files-only]`

List of services: `backup/backup.sh --discover`. Backup states: `/mnt/systems/backups/<host>/<service>/db|files/v.N` (`v.0` = latest state).

**Before every restore**: run `backup/backup.sh --service <name>` (fresh state) or deliberately use the last state. Let `--dry-run` show first what would happen.

## Category: DB dump (postgres / mysql / mariadb)

Services (currently): analytics-db, castopod_mariadb, ghost-mysql, immich_postgres, litellm_db

1. If needed, stop the service's stack (the app container, NOT the DB): `docker stop <app-container>` — otherwise apps write during the restore.
2. `backup/restore.sh <service> --db-only`
   - Postgres: `gunzip -c dump.sql.gz | docker exec -i <db> psql -U <user> -d <db> --single-transaction --set ON_ERROR_STOP=on`
   - MySQL/MariaDB: analogously with `mysql -u<user> <db>` (password via env).
3. Start the app container again.
4. **Verify**: test login, sanity-check object counts (e.g. immich: count photos).

Special cases:

- **Immich**: restore into an *empty* DB (docs: fresh install, `docker compose create`, start only the DB container, replay the dump, then start the rest). The dump contains `--clean --if-exists` respectively the pg_dumpall form and can be replayed over existing structures.
- **Ghost**: both schemas (`ghost_prod`, `ghost_activitypub`) are contained in the dump (the dump was created through the instance); start the ActivityPub container after the restore as well.
- **Forgejo** (`DB_TYPE=forgejo`): the `forgejo dump` is a ZIP. Manual restore (Forgejo/Gitea docs):
  1. Stop the stack. 2. Unpack the ZIP. 3. Move `data/*` to `/data/gitea`, `repos/*` to `/data/git/gitea-repositories/`. 4. `chown -R git:git /data`. 5. Run `forgejo admin regenerate hooks` (or `gitea admin regenerate hooks`). 6. Start the stack.
- **Open-Notebook** (`DB_TYPE=surreal`): `docker exec <c> surreal import --conn rocksdb:/mydata -f export.surql` (export file from the backup state).

## Category: DB dump (sqlite) — Vaultwarden

Vendor procedure (Vaultwarden wiki):

1. Stop the container: `docker stop vaultwarden`
2. **Delete `db.sqlite3-wal` and `db.sqlite3-shm`** (otherwise corruption from stale WAL!)
3. Copy the dump file (`db.sqlite3.sqlite3` from the backup state) to `/opt/docker/vaultwarden/db.sqlite3`.
4. `docker start vaultwarden`
5. Verify: login, spot-check vault contents.

`restore.sh vaultwarden` performs steps 1–4 automatically (stop → delete WAL → copy → start).

## Category: file rsync/restic (and config_only with stop window)

Services (currently): immich (files), castopod (media), vaultwarden, wanderer, forgejo (repos), ghost (content) plus all config-only services.

1. `backup/restore.sh <service> --files-only [--version v.N]`
   - The script automatically opens the stop window (declared `STOP_CONTAINERS`), rsyncs the files back, and restarts the containers.
2. **Verify** per service:
   - Immich: photos visible, thumbnails rebuild.
   - Media services: open the UI, library present, no DB errors in the log.
3. **Mind the restore direction**: `restore_files` overwrites the current state of the target path with the backup state (`rsync -a` without `--delete` — files not in the backup stay in place; for exact mirroring run `rsync -a --delete` manually afterwards).

## Category: config_only without stop window (homepage, searxng, web-proxy, mosquitto, codex)

1. `backup/restore.sh <service> --files-only`
2. Usually restart the container (`docker restart <c>`) so the config is re-read.
3. Verify: page/flow reachable, proxy routes work (web-proxy: `docker exec web-proxy-nginx nginx -t` before the reload!).

## Category: ignored

For services declared `ignore` (crawl4ai, firecrawl, metube, media libraries — see `policies.d/`) there is no restore — they can be rebuilt from the compose stack, or the data lives in other systems' media backups.

## Restore test (semi-automatic)

`backup/test-restore.sh` — replays the dumps of all DB services (Postgres and MariaDB) into throwaway containers and verifies that tables are created. Single service as argument; `--dry-run` shows the test list. Recommendation: run monthly; document the result in the run log.

## Checklist after every restore

- [ ] Service containers running (`docker ps`)
- [ ] Logs free of DB errors (`docker logs --tail 50 <c>`)
- [ ] Functional check via UI/API
- [ ] Re-enable the backup schedule (if disabled) and trigger one manual run
