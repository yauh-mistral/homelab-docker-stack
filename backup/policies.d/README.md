# policies.d — Policy-Overlays

Der Dispatcher entdeckt Services automatisch aus den laufenden Containern
(Bind-Mounts = Datei-Backup, DB-Image/ENV = DB-Dump). Diese Policies
ergänzen/überschreiben pro Projekt (`<project>.env`) oder Container
(`<container>.env`, gewinnt) nur das nicht Ableitbare:

- `SVC_IGNORE=true` — Container komplett ausschließen
- `EXTRA_FILE_PATHS=( ... )` — zusätzliche Pfade (z.B. App-Daten im DB-Container-Mount)
- `EXTRA_FILE_EXCLUDES=( ... )` — zusätzlich zu DEFAULT_FILE_EXCLUDES
- `STOP_SELF=true` — Stop-Fenster um das Datei-Backup (konsistente SQLite)
- `KEEP_FILES=true` — DB-Container: Rohdaten trotzdem sichern
- `DB_DUMP_ALL=true` — pg_dumpall statt pg_dump (z.B. immich)
- `DB_TYPE=sqlite|forgejo` — nicht ableitbare DB-Arten
- `SQLITE_FILES=( "host:container" )` — SQLite-Online-Backup-Ziele

Pfade, Container, Credentials kommen aus Docker — nie hier duplizieren.
