# Backup-Strategie für Host `ovi` (33 Services)

Ziel: konsistente, testbare, pseudo-mechanische Sicherung aller 33 Services aus `projects/` auf das NAS-Verzeichnis `/mnt/systems` mit einer Dispatcher-Architektur. Details zum Datenbestand: `docs/INVENTAR.md`.

## Grundprinzipien (nach Hersteller-Recherche)

1. **Konsistente DB-Dumps sind Pflicht, Datei-Kopien laufender DBs sind verboten** (AGENTS.md-Regel).
   - PostgreSQL → `docker exec <c> pg_dump -U <user> -d <db> --clean --if-exists` (Immich: `pg_dump` der Immich-DB bzw. `pg_dumpall`; Immich-Doku: „back up the database first, and the filesystem second").
   - MySQL/MariaDB → `docker exec <c> mysqldump --single-transaction --routines --triggers` bzw. `mariadb-dump` (Ghost-Doku: mysqldump für `ghost_prod` + `ghost_activitypub`).
   - SQLite (Vaultwarden) → `sqlite3 <db> ".backup <ziel>"` (Vaultwarden-Wiki: nie `db.sqlite3` im laufenden Betrieb kopieren, WAL-Dateien nicht mitkopieren; beim Restore zuerst `db.sqlite3-wal` löschen).
   - SQLite in *arr-/Home-Assistant-/Mealie-/Kuma-/Wanderer-/Audiobookshelf-Config-Verzeichnissen → Stop-Fenster des App-Containers vor rsync, Start danach (Sonarr-Wiki: "Stop Sonarr — This will prevent the database from being corrupted"). WAL/journal-Dateien aus dem Backup ausgeschlossen, wo Stop-Fenster nicht möglich ist; andernfalls im Stop-Fenster geschlossen (checkpoint beim sauberen Stop).
2. **OpenCloud** (Hersteller): konsistentes Backup nur im gestoppten Zustand; Metadaten liegen im Dateisystem unter `/mnt/opencloud` (kein DB-Server). Strategie: Stop-Fenster um `rsync` von `/mnt/opencloud` + `/opt/docker/opencloud` (Config mit Secrets).
3. **n8n**: `.n8n`-Ordner (enthält Encryption-Key) + pg_dump — beides gehört zusammen (n8n-Doku).
4. **Immich**: DB-Dump zuerst, danach Datei-Backup von `UPLOAD_LOCATION` — so zeigt die DB schlimmstenfalls auf Dateien, die (re-)hochgeladen werden können, nicht umgekehrt (Immich-Doku).
5. **Paperless**: pg_dump + Rsync von `data`+`media`; `document_exporter` als alternative, herstellerempfohlene Exportmethode (optionaler Hook im Dispatcher, siehe QUESTIONS).
6. **Forgejo**: `forgejo dump` als konsistenter Gesamt-Dump (DB+Config) via `docker exec`, zusätzlich rsync des `/data`-Baums für die Repos (Git-Objekte sind robust gegen Inkonsistenzen; der `forgejo dump` deckt DB+Config konsistent ab).

## Dispatcher-Architektur

```
/etc/backup.conf (Host: Pfade, Rhythmus)
        │
backup/backup.sh            ← Dispatcher (ein Skript, alle Services)
        │ 1..n je Service-Deklaration:
        ├─ backup/services.d/<service>.env     ← deklariert DB + Dateipfade + Kategorie + Optionen
        │      (Quelle der Wahrheit pro Service, wird vom Dispatcher eingelesen)
        │
        ├─ backup/lib/common.sh    ← Logging, Locking, Pfad-Handling, Stop/Start-Fenster, Restic-Wrapper
        ├─ backup/lib/db.sh        ← DB-Dump-Helfer (pg_dump, mysqldump, mariadb-dump, sqlite .backup, forgejo dump, surreal export)
        └─ backup/restic.snapshots.md  ← siehe "Retention" (Erklärung des Restic-Modells)
```

- **Ein Dispatcher, viele Deklarationen.** Der Dispatcher kennt keine Service-Logik; alle Service-Eigenheiten (Containername, DB-Typ, Pfade, Ausschlüsse, Stop-Fenster) stehen in `backup/services.d/<service>.env`. Er liest alle Deklarationen und führt Backup + Restore generisch aus. Service-spezifische Befehle (z.B. `forgejo dump`) sind als HOOK-Variablen in der Deklaration hinterlegt.
- **Dry-Run ist First-Class**: `backup.sh --dry-run` listet alle deklarierten Aktionen mit allen Parametern auf, ohne etwas anzufassen. Jede deklarierte Aktion wird auf Existenz von Quellpfaden/Containern geprüft; fehlende Quellen werden als Lücke protokolliert, nicht als Fehler abgebrochen (idempotent, defensiv).
- **Idempotenz**: Backups erzeugen keine Duplikate bei Re-Lauf (Zeitstempel-Verzeichnisse + rsync-update; Restic-Repository prüft Duplikate selbst). Fehlgeschlagene Teil-Backups stoppen nicht den Gesamtlauf (ein Service-Fehler ≠ Abbruch), werden aber rot markiert und im Exit-Code gezählt.
- **Restore ist symmetrisch**: `backup/restore.sh <service>` nutzt dieselbe Deklaration, um DB-Dump zurückzuspielen (`psql`/`mysql`/`sqlite .restore`) und Dateien per rsync zurückzukopieren. Pro Kategorie existiert eine Restore-Anleitung (`docs/RESTORE.md`).

## Deklarationsformat pro Service (`backup/services.d/<service>.env`)

Alle Deklarationen folgen demselben Format (KEY=VALUE, Bash-Sourcebar):

```bash
# --- Identität ---
SVC_NAME=immich                       # eindeutig, = Dateiname ohne .env
SVC_CATEGORY=db_and_files             # db_only | files_only | config_only | db_and_files | ignore
SVC_STACK=projects/immich             # Compose-Projekt (Projektion in repo, Info)

# --- Datenbank (nur bei db_*) ---
DB_TYPE=postgres                      # postgres | mysql | mariadb | sqlite | forgejo | surreal
DB_CONTAINER=immich_postgres          # Containername für docker exec
DB_USER=postgres
DB_NAME=immich
DB_DUMP_ALL=false                     # pg_dumpall statt pg_dump (Immich-Variante möglich)
DB_DUMP_EXTRA=--clean --if-exists

# --- Dateien (nur bei *_files / config_only) ---
FILE_PATHS=(
  "/mnt/immich"
)                                     # Host-Pfade, die per rsync gesichert werden
FILE_EXCLUDES=(
  "thumbs/" "encoded-video/"
)                                     # rsync-Exclude-Muster, relativ oder absolut
SQLITE_FILES=(
  "/opt/docker/vaultwarden/db.sqlite3:/data/db.sqlite3"
)                                     # host:container-Paare für sqlite3 .backup via docker exec

# --- Stop-Fenster (optional, für Datei-Backups laufender SQLite-Apps) ---
STOP_CONTAINERS=( homeassistant )     # Container, die vor FILE-Backup gestoppt und danach gestartet werden

# --- Haken für Spezialfälle ---
PRE_DUMP_HOOK=""                      # beliebige Bash-Zeile, wird vor DB-Dump ausgeführt
POST_DUMP_HOOK=""                     # z.B. document_exporter für paperless
```

Der Dispatcher validiert beim Start jede Deklaration (Pfad-Existenz, Container-Existenz im Dry-Run, Variablen-Typprüfung) und protokolliert Verstöße in `docs/QUESTIONS.md`-Form (Lauf-Log).

## Ziel-Layout unter `/mnt/systems`

```
/mnt/systems/
└── backups/
    ├── ovi/
    │   ├── <service>/
    │   │   ├── db/                    # DB-Dumps (nur db_*)
    │   │   │   └── 2026-10-04_0230/   # ein Verzeichnis pro Lauf (Zeitstempel YYYY-MM-DD_HHMM)
    │   │   │       ├── immich.sql.gz  # komprimierter konsistenter Dump
    │   │   │       └── .ok            # Marker: Dump erfolgreich (Größe>0, Exit 0)
    │   │   └── files/                 # Datei-Backups (rsync-Spiegel)
    │   │       └── 2026-10-04_0230/
    │   │           └── <rsync-Baum>
    │   ├── _meta/
    │   │   ├── last-run.log           # Dispatcher-Log des letzten Laufs
    │   │   └── inventory.md           # kopiertes Inventar (Selbstbeschreibung)
    │   └── restic/                    # Restic-Repo (optional, siehe Retention)
    │       └── <service>/             # ein Repo pro Service (Feingranular, Restore einfach)
    └── (andere Hosts folgen später nach demselben Schema)
```

- `_meta` wird pro Lauf geschrieben (idempotent überschrieben; `last-run.log` zusätzlich mit Zeitstempel archiviert: `runs/2026-10-04_0230.log`).
- Pro Service ein Unterverzeichnis; DB und Dateien getrennt — Restore kann each einzeln gespielt werden.
- Restic repos sind pro Service getrennt, damit ein Restore nur den Ziel-Service anfasst und Passwörter/Volumen pro Service bleiben.

## Rhythmus

- **DB-Dumps**: täglich 02:00 Uhr (Cron: `0 2 * * * /opt/docker/arcane/backup/backup.sh --only-db`).
  - Begründung: DB-Änderungen sind häufig (Immich-Uploads, Ghost-Posts, n8n-Ausführungen); Immich-Admin-Panel eigene Dumps laufen ebenfalls nachts — Dispatcher läuft 30 min versetzt (02:30), um Immich-Interne nicht zu kollidieren.
- **Datei-Backups (Datei-Rsync-Restic)**: täglich 02:30 (im selben Lauf nach den DB-Dumps; Immich-Reihenfolge DB→Dateien bleibt gewahrt).
- **Config-only**: wöchentlich Sonntag 03:00 (Cron: `0 3 * * 0 ... --only-config`). Konfigurationen ändern sich selten; Stop-Fenster (z.B. Sonarr) belasten Wochentage nicht.
- **Übergreifender Inventar-Abgleich**: monatlich 1. des Monats — Dry-Run gegen `projects/` und Abgleich mit `docs/INVENTAR.md` (`backup.sh --dry-run` Ausgabe diff mit letztem Inventar; Differenzen → `docs/QUESTIONS.md`).

Alle Zeiten Europe/Berlin. Der Dispatcher läuft unter root (Zugriff auf /opt/docker und /mnt), Cron-Eintrag in root-Crontab, Ausführung mit `flock` gegen Parallel-Läufe.

## Retention

- **DB-Dumps**: 30 Tage (Verzeichnisse älter als 30 Tage löschen; Behalte-Monatsfirst: Dump vom 1. des Monats 12 Monate). Implementierung im Dispatcher: `find <db> -mindepth 1 -maxdepth 1 -type d -mtime +30 ! -name "$(date +%Y-%m-01)*" -exec rm -rf` — einfacher: Dump-Verzeichnisse mit Datum älter 30 Tage entfernen, außer Erster des Monats (per Datumsmuster erkennbar) → 12 Monatsversionen.
- **Datei-Backups (rsync-Spiegel)**: 14 tägliche Versionen + 8 wöchentliche (Hardlink-Farm via `cp -al` auf dem NAS oder `rsync --backup --backup-dir`) — siehe QUESTIONS für NAS-Fähigkeit (Hardlinks). Fallback ohne Hardlinks: rsync-Spiegel zeigt immer „aktueller Stand", Restic übernimmt Historie.
- **Restic (falls aktiviert)**: `restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune` pro Service-Repo. Restic ist optional zugeschaltet über `USE_RESTIC=true` in `/etc/backup.conf`; ohne Restic gilt die rsync+Zeitstempel-Retention oben.

## Logging

- Jeder Lauf schreibt nach `/mnt/systems/backups/ovi/_meta/runs/<timestamp>.log` und stdout.
- Pro Service eine Zeile: `[OK] immich db 412MB in 38s`, `[FAIL] ghost db (mysql exit 1)`, `[DRY] n8n files (would rsync 5 paths)`.
- Ende des Laufs: Zusammenfassung `OK=31 FAIL=2 SKIP=1`, Exit-Code = Anzahl FAILs (max 1 als Fehlersignal).
- `--dry-run` schreibt ausschließlich stdout (kein Logfile, kein NAS-Schreibzugriff) — für den Inventar-Abgleich verwendbar.

## Restore-Konzept

- `backup/restore.sh <service> [--date YYYY-MM-DD_HHMM] [--dry-run]`
  - Liest dieselbe `services.d/<service>.env`.
  - DB-Kategorie: entpackt den Dump (per Default: letzten; sonst `--date`), spielt ihn ein:
    - Postgres: `docker exec -i <c> psql -U <user> -d <db> --single-transaction`
    - MySQL/MariaDB: `docker exec -i <c> mysql -u<user> -p... <db>`
    - SQLite: Container stoppen, `db.sqlite3-wal`/`-shm` löschen, Dump-Datei an Ort und Stelle kopieren, Container starten (Vaultwarden-Restore-Prozedur aus dem Wiki).
  - Datei-Kategorie: `rsync` vom NAS-Zeitstempel-Verzeichnis zurück zum Zielpfad ( Stop-Fenster wie beim Backup).
  - `--dry-run` zeigt nur, welche Dump-/rsync-Aktionen anstünden.
- Pro Backup-Kategorie existiert eine Restore-Anleitung in `docs/RESTORE.md` (DB-Dump, Datei-Rsync-Restic, Config-only, inkl. Checkliste „Service nach Restore verifizieren").
- **Restore-Test**: `backup/test-restore.sh` — halbautomatischer Test: nimmt einen Service (default: kleinster DB-Service, z.B. litellm), erzeugt einen Dump, spielt ihn in einen Wegwerf-Container (`docker run --rm postgres:16-alpine`) ein und prüft, ob Tabellen angelegt wurden (`psql -c "\dt" | wc -l > 0`). Testet, dass der Dump-Ansatz funktioniert, nicht die Produktivdaten.
