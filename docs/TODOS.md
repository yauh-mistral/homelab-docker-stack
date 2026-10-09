# Todos & dokumentierte Entscheidungen

Offene Punkte als klare Todos; historische Annahmen sind zu Entscheidungen verdichtet (ehemalige `QUESTIONS.md`, nummerierte Referenzen in Klammern).

## Offene Todos

- [ ] **restore.sh testen & verifizieren** — wurde bisher nie getestet. Nur `test-restore.sh` (DB-Dumps in Wegwerf-Postgres) läuft grün; der echte Datei-/DB-Restore über `restore.sh` ist unverifiziert. Geplant: Restore einzelner Services in eine isolated Umgebung (Wegwerf-Container, eigenes Zielverzeichnis), nie gegen das Live-System.
- [ ] **Mermaid-Diagramm auf GitHub verifizieren** — nach Merge des Entity/Link-Fixes prüfen, dass das README-Diagramm rendert.
- [ ] **SemVer-Übergang (Phase 2)** — E2E-Kriterium ist erfüllt (Discovery → Dry-Run → echter Lauf → `test-restore.sh --all` alles grün). Übergang von `v1.0.0` auf Semantic Versioning ist ein User-Entscheid; vermutlich `v1.1.0` beim nächsten inhaltlichen PR.
- [ ] **Cron auf dem Docker-Host bestätigen** — Cron-Zeile ist geliefert und im README dokumentiert; Eintrag in der root-Crontab noch unbestätigt.

## Erledigt / entschieden (compact)

### Backup-Architektur (v1.0.0, E2E-getestet)

- Auto-Discovery aus laufenden Containern ersetzt statische Deklarationen; Stacks als Projekte unter Arcane; Quelle der Wahrheit ist Docker, nicht das Repo (#1, #2).
- Zielpfad `/mnt/systems/<host>/backups` (Freiraum für weitere Hosts); NAS-Mounts sind nie Backup-Quelle (#3, #57).
- Rotation rsnapshot-artig `v.0..v.13` mit Hardlink-Dedupe (`--link-dest=v.1`); KEEP_VERSIONS ersetzt alte Zeitstempel-/Monatslogik (#48–#50, #26).
- Restore-Testskript deckt Postgres ab (testet v.0, pg_dumpall-Dumps in Original-DB); MySQL/MariaDB-Test analog ergänzbar, Bedarf klären (#23).

### Ghost / ActivityPub (compact — historische Fragen #9, #34, #54, #62)

- **Dump als root (bewusste Entscheidung)**: mysqldump 9.x führt auch mit `--single-transaction --skip-lock-tables` initial `FLUSH TABLES` aus und braucht dafür RELOAD — das `ghost_user` fehlt (Fehler 1227). Fix: Dump als root (`DB_ROOT_PASSWORD` aus Container-ENV). Bewusst verworfen: `GRANT RELOAD` an den App-User (Rechte nicht für Backup-Zwecke aufweichen) und Exit-Code-Toleranz (würde echte Fehler verschlucken).
- **ActivityPub-Schema ist mitgesichert**: Der Root-Dump über die gesamte Instanz deckt `ghost_prod` + `ghost_activitypub` ab — Frage #9 ist geschlossen, kein separater Dump pro Schema nötig.
- `DB_DUMP_EXTRA="--set-gtid-purged=OFF"` in `policies.d/ghost-mysql.env` ist rein kosmetisch (unterdrückt die GTID-Warnung auf dem Nicht-Replications-Host; `--single-transaction` + `--skip-lock-tables` ist die empfohlene InnoDB-Snapshot-Konfiguration, #54).

### Exclude-Grundsätze (Entscheidungen)

- Rebuild-Daten nicht sichern: Caches, Thumbnails, Logs, Transcodes, MediaCover, Plex-DB-Backups/datierte Kopien (#44).
- Audiobookshelf `metadata/` und Medien-Quellen gelten als wiederbeschaffbar; bei Bedarf erweitern (#46, #16).
- 5etools-htdocs füllt der Container selbst aus den in Forgejo gesicherten Git-Repos — kein Datei-Backup (#47, #19).
- Forgejo: `forgejo dump --skip-repository` (DB+Config) + rsync der Repos — keine Doppel-Sicherung; Mirror-Repos bleiben bewusst drin (7G sind ok), Hardlink-Dedupe macht Folgeläufe günstig (#59, #60, #61).
- NAS-Regel: alles unter `/mnt/*` ist vom NAS-eigenen Backup abgedeckt, Dispatcher-Guard lehnt `/mnt/*`-Pfade ab (#57).

### Robustheit (umgesetzt, auf dem Docker-Host verifiziert)

- Preflight-Checks, Docker-Daemon-Guard, Teil-Backup als WARN statt FAIL, SKIP bei nicht deploytem Service (#40–#42).
- Vaultwarden: kein sqlite3 im Image → Hilfscontainer-Fallback (`keinos/sqlite3`) liest die DB aus dem aufgelösten Bind-Mount (#55, #10).
- Immich: `DB_DUMP_ALL` nutzt `pg_dumpall` (Cluster inkl. Rollen/Rechte) (#53).
- Timestamps in Logs, Consistency-Check am Laufende, Mount-Guard, Stop-Fenster-Rollback (#51, #52, #32, #33).

### Abgeschlossen ohne weiteren Bedarf

- Restic bleibt optional/deaktiviert (`USE_RESTIC`), rsync+Rotation ist die produktive Strategie (#5, #27).
- Benachrichtigungen (E-Mail/Healthchecks) nicht gefordert; bei Bedarf als Hook nachrüsten (#28).
- DB-Passwörter: Auto-Discovery liest Credentials aus Container-ENV; kein `source` der Stack-.env mehr nötig (#29, #31).
