# policies.d — policy overlays

The dispatcher discovers services automatically from the running containers
(bind mounts = file backup, DB image/env = DB dump). These policies
supplement/override per project (`<project>.project.env`) or container
(`<container>.env`, wins) only what cannot be derived:

- `SVC_IGNORE=true` — exclude the container entirely
- `EXTRA_FILE_PATHS=( ... )` — additional paths (e.g. app data in a DB container mount)
- `EXTRA_FILE_EXCLUDES=( ... )` — in addition to DEFAULT_FILE_EXCLUDES
- `STOP_SELF=true` — stop window around the file backup (consistent SQLite)
- `KEEP_FILES=true` — DB containers: still back up raw data
- `DB_DUMP_ALL=true` — pg_dumpall instead of pg_dump (e.g. immich)
- `DB_TYPE=sqlite|forgejo` — DB types that cannot be derived
- `SQLITE_FILES=( "host:container" )` — SQLite online backup targets

Paths, containers, and credentials come from Docker — never duplicate them here.
