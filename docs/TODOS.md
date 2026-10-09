# Todos

Only open tasks — completed items and decisions made are not archived here (consult the PR history if needed).

- [ ] **Test & verify restore.sh** — the restore test of the DB dumps is complete (all 5 DB services, Postgres + MariaDB, in throwaway containers). What remains unverified is the real restore via `restore.sh`: files back to production paths + replaying a dump against the production DB. A fully automated test is hard to do without endangering the live system — options:
  - **Manual probe restore** (recommended): replay individual files and DB dumps by hand into an isolated sandbox or a throwaway target directory and verify (unpacking the `*.sql.gz`, structure check of the file states), without touching the live system's `docker compose`.
  - Alternatively this todo remains until an isolated test setup (second host / throwaway VM) is available.
