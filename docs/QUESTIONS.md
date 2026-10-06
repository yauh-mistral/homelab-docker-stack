# Offene Fragen und getroffene Annahmen

Jede getroffene Annahme ist hier mit Begründung aufgelistet. Nicht schließen — nur dokumentieren.

## Zählung und Struktur

1. **„33 Services" vs. 30 Stacks**: Das Repo enthält 30 Compose-Stacks in `projects/`. Die „33" ergeben sich aus multi-Service-Stacks (arr-stack=7, smarthome=4, media=5). Ich habe 43 backup-relevante Einheiten deklariert (feiner als der Stack, weil Restore/Retention pro Service sinnvoller ist). Wer genau „33" meinte, möge die Zählabgrenzung bestätigen.
2. **Auftrag nannte `arcane/`-Verzeichnisse** (`/opt/docker/arcane/{data,projects}` tauchen im Snapshot auf), aber das Repo selbst heißt `arcane-docker-stack` mit `projects/` — ich habe `projects/` als Quelle der Wahrheit genommen.

## Ziel und Infrastruktur

3. **Zielpfad**: Auftrag sagt „Zielverzeichnis auf ovi ist `/mnt/systems`". Ich habe `/mnt/systems/backups/ovi/` als Wurzel gewählt (Freiraum für weitere Hosts und Nicht-Backup-Inhalte auf dem NAS-Mount).
4. **NAS-Mount-Eigenschaften**: Unbekannt, ob `/mnt/systems` Hardlinks (für rsync-Hardlink-Farmen) und `sync`-Semantik unterstützt. Strategie sieht deshalb rsync+Zeitstempel-Verzeichnisse vor, Hardlink-Optimierung als optional. Prüfen.
5. **Restic**: Nicht bekannt, ob Restic auf ovi installiert ist. Der Dispatcher unterstützt Restic optional (`USE_RESTIC=true`), funktioniert aber vollständig ohne (`rsync`+Zeitstempel). Entscheidung nötig: Restic aktivieren (dann `restic` installieren + Passwortdatei `/etc/restic-password` anlegen)?
6. **Cron-Einrichtung**: Der Auftrag verlangte keine laufende Automatisierung auf ovi selbst. Die Cron-Zeiten (DB täglich 02:00, Dateien 02:30, config wöchentlich So 03:00) stehen in der Strategie — Einrichtung auf ovi noch zu tun.

## Datenbank-Details (aus .env.example abgeleitet — Produktiv-.env kann abweichen)

7. **DB-Credentials**: Ich habe Benutzernamen/DB-Namen aus `.env.example` übernommen (z.B. `shynet_user`/`shynet_db`, `n8n_user`/`n8n_db`, `paperless`/`paperlessdb`). Passwörter (`DB_PASSWORD`) habe ich NICHT in Deklarationen hinterlegt — der Dispatcher liest sie bei Bedarf aus der Produktiv-`.env` des Stacks (mysql) oder nutzt `trust`/`POSTGRES_USER`-Auth im Container (pg_dump im Container läuft meist als Superuser ohne Passwort). Prüfen, ob pg_dump im Container ohne Passwort funktioniert (usu. ja, da lokale Unix-Socket-Auth).
8. **Container-Namen**: `.env.example` nutzt teils `${COMPOSE_PROJECT_NAME}-...` (z.B. `analytics-db` aus `COMPOSE_PROJECT_NAME=analytics`). Der Host-Snapshot bestätigt: `analytics-db`, `n8n-db`, `paperless-db`, `paperless-broker`, `monitoring-kuma`, `monitoring-grafana`, `wanderer_db`, `tdarr-tdarr`, `ghost-mysql`, `immich_postgres`, `castopod_mariadb`, `litellm_db`, `sparkyfitness-db` (nicht im Snapshot, aber Compose-logisch). Für open-notebook habe ich `open-notebook-surrealdb-1` deklariert (Compose-Standard-Slug; nicht im Snapshot sichtbar) — auf ovi verifizieren.
9. **Ghost-ActivityPub-Schema**: Ghost-Compose definiert `ACTIVITYPUB_DB_NAME=ghost_activitypub` in derselben MySQL-Instanz. Meine Deklaration dumpt nur `ghost_prod`. Vorschlag: `DB_NAME` auf `--databases ghost_prod ghost_activitypub` erweitern oder Dump über `mysqldump --all-databases`. Offen: Exponentiell eleganter wäre ein separater Dump pro Schema — Bedarf klären.
10. **Vaultwarden sqlite3-Binary**: Vaultwarden-Image enthält `sqlite3` im Container — der Hersteller empfiehlt `sqlite3 db.sqlite3 ".backup ..."` via Container. Falls Binary fehlt: Fallback über Host-sqlite3 mit Stop-Fenster.
11. **Forgejo DB-Typ**: Ich habe `forgejo dump` als DB-Dump gewählt (konsistent, deckt DB+Config ab). Unbekannt ist, ob Forgejo intern SQLite oder eine externe DB nutzt — `forgejo dump` ist in beiden Fällen korrekt.
12. **Redis/Valkey-Instanzen** (Redis im Snapshot, Valkey mit `dump.rdb`): Diese gehören zu Stacks (searxng=Valkey-Cache, firecrawl=Queue) und sind als Cache/Queue klassifiziert und ignoriert. Prüfen, ob wirklich keine persistenten Daten (z.B. n8n-Binary-Daten in Redis — im Compose ist Redis nur für searxng/firecrawl/castopod/paperless-Broker deklariert — nur Cache/Broker/Queue-Rollen).

## Datei-Backups

13. **`/mnt/immich` (Immich UPLOAD_LOCATION)**: Liegt auf NAS (nicht im Snapshot, Größe unbekannt — vermutlich hunderte GB Fotos). Der Rhythmus (täglich, rsync-abhängig) kann auf so große Datenmengen treffen — Backup-Fenster (Laufzeit!) auf ovi messen; ggf. Immich auf wöchentlich + DB täglich stellen.
14. **`/mnt/opencloud`**: Größe unbekannt. OpenCloud-Doku verlangt Stop-Fenster für konsistente Backups — täglicher Stop könnte unangenehm lang sein. Kompromiss: OpenCloud-Backup wöchentlich + DB-freie Struktur akzeptiert kleinere Inkonsistenzen (PosixFS) — Hersteller-Empfehlung ist aber Stop. Klären, wie lange ein Stop auf ovi tolerierbar ist.
15. **`/mnt/paperless/*`**: `data`, `media`, `export` sind als NAS_DATA_PATH deklariert — ich sichere `data`+`media` per rsync (das deckt Dokumente+Thumbnails ab); `export` lasse ich weg (dient dem `document_exporter`, der optional als Hook laufen kann). Klären, ob `document_exporter` (Hersteller-Empfehlung als Alternative) als PRE_DUMP_HOOK gewünscht ist.
16. **Audiobookshelf metadata (45G)**: Das `metadata`-Verzeichnis ist sehr groß (vermutlich Podcast-Cache + Cover). Ich habe nur `config` gesichert, `metadata` weggelassen. Prüfen, ob `metadata` Hörbuch-Cover enthält, die nicht rekonstruierbar sind — falls ja, in Deklaration aufnehmen.
17. **Tautulli cache (897M)**: Cache, ignoriert. Falls Tautulli-Historie wichtig ist: `tautulli.db` wird im Datei-Backup (Stop-Fenster) erfasst — passt.
18. **arr-Services MediaCover**: Sehr groß (6.8G bei lidarr), rekonstruierbar (aus APIs). Ich habe MediaCover NICHT ausgeschlossen (liegt in FILE_PATHS des /config) — Excludes-Verfeinerung möglich: `"MediaCover/"` würde 10+ GB sparen. Klären: Verlust akzeptieren?
19. **`/opt/docker/5etools` (dnd, 6.9G)**: Statische Website aus einem GitHub-Repo — grundsätzlich neu klonbar. Ich habe es als config_only (Datei-Backup) deklariert, da der Dockerfile-Build individuell ist. Klären: reicht die Repo-URL als Dokumentation?
20. **web-proxy `/opt/docker/nginx/mediafiles`, `staticfiles`, `html`**: Weiggelassen (statisch/vermutlich Medien- und Default-Inhalte). Nur conf/vhost/certs/htpasswd/acme/yauh gesichert. Klären.
21. **Grafana-LDAP/Cookie-Secrets**: Grafana `data` (655M im Snapshot) enthält SQLite + Dashboards. `logs` ausgeschlossen (compose-trennt `data`/`logs`). Keine weiteren Ausschlüsse vorgenommen.

## Restore

22. **Restore-Richtung ohne `--delete`**: `restore.sh` rsynct zurück ohne `--delete` — Dateien, die im Backup-Stand fehlen, bleiben auf dem Ziel zurück (bewusst defensiv, kein Datenverlust durch Restore). Für exakte Abbildung manuell `rsync -a --delete` nachziehen.
23. **Restore-Testskript deckt Postgres ab**: `test-restore.sh` testet Dump-Restores in Wegwerf-Postgres. MySQL/MariaDB-Test analog ergänzbar (Bedarf klären). Forgejo/Surreal/SQLite manuell laut docs/RESTORE.md.
24. **Immich-Restore-Prozedur**: Immich verlangt für DB-Restore eine frische Installation (Doku). restore.sh spielt den Dump gegen die laufende/leere DB — für den Katastrophenfall docs/RESTORE.md beachten.

## Selbstabnahme (Phase 5)

25. **Sandbox-Einschränkung**: `bash -n` für alle 5 Skripte bestanden. Dry-Run gegen alle 43 Deklarationen: OK=40, SKIP=3 (crawl4ai, firecrawl, metube — als `ignore` deklariert), FAIL=0. Die „Quellpfad existiert nicht"-Warnungen sind sandboxes-erwartbar (kein `/opt/docker` hier) — auf ovi verschwinden sie. **Docker-Daemon steht in der Sandbox nicht zur Verfügung** — echte Container-Interaktionen (docker exec, Stop-Fenster, test-restore) sind auf ovi zu verifizieren.
26. **`prune_dump_dirs`-Vereinfachung**: Retention für Dump-Verzeichnisse nutzt `find -mtime` — Dateisystem-mtime der Verzeichnisse, nicht das Datum im Namen. Für Monatsfirste wird das Namensmuster `YYYY-MM-01_*` geprüft. Funktion robust, aber auf ovi einmalig prüfen (ein Testlauf mit kurzem KEEP-Wert).
27. **Restic-Wrapper**: `restic forget/prune` läuft mit `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` — monatliche Behalte-Frist für Datei-Snshots weicht von der 12-Monats-Regel für DB-Dumps ab (12 monthly deckt 12 Monate ab) — konsistent genug, dokumentiert.
28. **Kein Versand von Benachrichtigungen** (E-Mail/Healthchecks): Nicht gefordert, aber für einen Produktivbetrieb sinnvoll — Hook in backup.sh nachrüsten?
29. **`.env`-Dateien des Produktsystems sind die Quelle für Passwörter** — der Dispatcher muss ggf. `source projects/<stack>/.env` vor dem Dump machen, um `DB_PASSWORD` zu haben (MySQL). Implementiert ist `DB_PASSWORD` als Variable, die aus der Deklaration ODER Umgebung kommt. Empfehlung: `/etc/backup.conf` sourced die Stack-.envs — auf ovi einrichten.
30. **Open-Notebook-Containername unsicher** (siehe #8) und `DB_CONN=rocksdb:/mydata` vom Standard abgeleitet (compose mountet `/opt/docker/open-notebook/surreal:/mydata`, surrealdb:v2 default rocksdb) — auf ovi verifizieren.

## Ergänzungen nach Review (PR 2)

31. **DB-Passwort-Lademechanismus**: Neu `ENV_FILE`/`DB_PASSWORD_VAR` in Deklarationen (implementiert in `load_declaration`); liest gezielt nur die Passwort-Variable aus der Stack-`.env`, nicht die ganze Datei (Kollisionsrisiko mit Dispatcher-Variablen ausgeschlossen).
32. **Mount-Guard**: Dispatcher verweigert Start, wenn `/mnt/systems` nicht als Mount verfügbar ist (`require_mounted_target`, `FORCE_LOCAL=true` nur für Tests).
33. **Stop-Fenster-Rollback**: `stop_containers` startet bereits gestoppte Container zurück, wenn ein späterer Stop fehlschlägt (kein Service bleibt versehentlich down).
34. **MySQL `DB_DUMP_EXTRA`**: wird jetzt auch für MySQL/MariaDB angewandt; Ghost dumpt damit `ghost_prod` + `ghost_activitypub` (schließt Frage #9).
35. **Postgres-Readiness**: `wait_for_postgres` (pg_isready, 30×2s) vor jedem pg_dump — verhindert Teil-Dumps nach Host-Reboot.

## Ergänzungen nach Struktur-Diskussion (PR 3)

36. **Heimat des Backup-Systems**: Bewusst NICHT `/opt/docker/arcane` (Repo), sondern `/opt/docker/backup` als eigene Installation via `install.sh` (`--home` konfigurierbar). Repo-Updates überschreiben die Installation nicht; Re-Run des Installers aktualisiert sie (rsync/ohne `--delete`: lokal angepasste Deklarationen bleiben).
37. **Quelle konfigurierbar**: `STACKS_DIR` in `/etc/backup.conf` zeigt auf die Compose-Stacks + `.env` (z.B. `/opt/docker/arcane/projects`). Deklarationen nutzen `%STACKS_DIR%`-Platzhalter (bislang `ghost.env: ENV_FILE`), aufgelöst in `load_declaration`. Dispatcher startet nicht ohne `STACKS_DIR` (Fail-fast gegen falsch aufgelöste Pfade).
38. **Ziel konfigurierbar**: bleibt `BACKUP_ROOT` (Default `/mnt/systems/backups/ovi`), jetzt ebenfalls klar in `/etc/backup.conf` dokumentiert; `SERVICES_DIR` ist der dritte konfigurierbare Pfad (Heimat der Deklarationen nach Installation).
39. **cp-Fallback im Installer**: rsync nicht garantiert auf Minimal-Hosts — Installer funktioniert mit beiden (getestet ohne rsync).

## Ergänzungen nach Robustheits-Anforderung (PR 4)

40. **Preflight-Container-Checks**: Dispatcher prüft vor dem Backup jedes DB-Services, ob `DB_CONTAINER` existiert (`docker inspect`) und läuft. Fehlt die Quelle komplett (Container weg UND keine existierenden Dateipfade), zählt der Service als `SKIP` statt `FAIL` — ein nicht deployter Service bricht den Lauf nicht mehr. Existiert nur ein Teil, läuft ein Teil-Backup mit `WARN`. Annahme: Container-Name in der Deklaration korrekt; unbekannte/umbenannte Container (siehe #8, #30) bleiben Lücken, aber keine harten Fehler.
41. **Docker-Daemon-Guard**: Bei echtem Läufen bricht der Dispatcher hart ab (`exit 1`), wenn `docker info` nicht erreichbar ist — sonst würden alle Container-Checks falsch-negativ sein und 43 SKIPs als Erfolg durchgehen. Dry-Run ohne Docker ist erlaubt (reine Pfad-/Deklarationsprüfung, WARN statt FAIL).
42. **Teil-Backup ohne FAIL**: Fehlt bei `db_and_files` nur eine Seite (z.B. Container läuft nicht, Dateien vorhanden), wird das Vorhandene gesichert und die fehlende Seite nur als `WARN` + Lücke dokumentiert — kein FAIL, kein Fehler-Exit. Begründung: Der Zustand ist auf dem Host bekannt dokumentiert, kein Skriptfehler; ein FAIL würde den Lauf (und ggf. Cron-Alarm) verwässern.
43. **SQLite-Quelle**: Für SQLite-Services (Vaultwarden) gilt der laufende Container als vorhandene Quelle — die `.sqlite3`-Datei liegt im Volume, ein Host-Pfad-Check wäre falsch. Fällt der Container weg, greift der SKIP.

## Ergänzungen zum Exclude-Prinzip (PR 6)

44. **Rebuild-Daten nicht sichern**: Grundsatz „Nur Configs + Nutzdaten; was der Container beim Start/Scan neu erzeugt (Caches, Thumbnails, Logs, Transcodes), bleibt außen vor". Umgesetzt: Plex (`Cache/ Codecs/ Transcode/ Logs/` — `plex/conf` war laut Snapshot 53G, der Cache-Anteil entfällt), Immich (`encoded-video/`, `thumbnails/` — Neugenerierung per Job-Queue nach Restore akzeptiert), arr-Familie (`MediaCover/` — Cover werden aus den Metadaten-Quellen neu geladen, schließt Frage zum ~20G-Cover-Volumen). Restore-Kosten bewusst in Kauf genommen: Thumbnail-/Cover-Rebuilds brauchen Rechenzeit.
45. **Immich `library/`/`upload/` sind NICHT exkludiert** — sie enthalten die Originale. Nur die dokumentierten Cache-Verzeichnisse (`encoded-video/`, `thumbnails/`) sind draußen. Vor dem ersten echten Immich-Backup prüfen: `ls /mnt/immich/library | head` muss die Original-Bibliothek zeigen.
46. **Audiobookshelf `metadata/` (45G) war nie im Backup** (nur `config/` mit der SQLite-DB, 269M) — die Audio-Dateien selbst gelten als über ihre Quelle (Audiobuch-Downloads) wiederbeschaffbar bzw. sind primärer Medienbestand, kein Backup-Ziel. Falls doch gewünscht: FILE_PATHS in `audiobookshelf.env` erweitern (Preis: 45G pro Stand).

## Ergänzung 5etools (PR 7)

47. **5etools: keine Datei-Backup mehr**: Der Container befüllt `/opt/docker/5etools` (htdocs, mehrstelliges GB-Volumen) selbst aus den Git-Repos, die in Forgejo gesichert sind — doppelte Sicherung unnötig. Deklaration sichert nur noch `%STACKS_DIR%/dnd/compose.yaml` (Compose-Definition lebt im arcane-Repo). Dafür wurde die `%STACKS_DIR%`-Platzhalter-Auflösung auf `FILE_PATHS` erweitert (bislang nur `ENV_FILE`). Restore = Compose-Stack hochfahren, Container lädt Inhalte selbst.

## Ergänzungen Rotation/Consistency (PR 8)

48. **Rotation statt Zeitstempel-Pfade (rsnapshot-Stil)**: Ziel ist `<service>/{db,files}/v.0..v.KEEP_VERSIONS-1`. Vor jedem Backup rotiert der Dispatcher (v.0→v.1→…→Entsorgen der ältesten). `KEEP_VERSIONS` (Default 14) via `/etc/backup.conf` konfigurierbar — ersetzt die alte KEEP_DAILY/MONTHLY-Heuristik (Frage #26 damit obsolet). Restore default = `v.0`, ältere per `--version v.N`; alte Zeitstempel-Stände bleiben über latest_dir-Fallback lesbar.
49. **Hardlink-Dedupe**: rsync `--link-dest=v.1` — unveränderte Dateien verbrauchen keinen Zusatzplatz, wenn das NAS-Dateisystem Hardlinks unterstützt (NFS: ja; CIFS: kein Link, dann Vollplatz pro Version). Annahme: NAS-Mount ist NFS (Spotlight-Silly-Rename-Fehler sprach dafür).
50. **Monatsfirste entfallen**: Die alte Monatsfirst-Behaltelogik (12 monthly) ist in der Versionen-Rotation nicht abgebildet — KEEP_VERSIONS zählt Versionen (Läufe), nicht Kalendermonate. Bei täglichem Cron = KEEP_VERSIONS Tage Historie; für längere Historie KEEP_VERSIONS hochsetzen oder wöchentlich rotierende weekly.N nachrüsten (noch nicht gebaut).
51. **Timestamps in Logs**: Jede stdout-/Log-Zeile bekommt `YYYY-MM-DD HH:MM:SS`-Präfix (vorher nur im Log-Dateinamen) — Dauer einzelner Schritte im Lauf direkt ablesbar.
52. **Consistency-Check am Laufende**: prüft pro verarbeitetem Service, dass v.0 existiert, nicht leer ist und DB-Stände mind. einen Dump >0 Bytes haben. WARNs, kein FAIL — Grund: Ein fehlender Stand ist oft ein bekannter Host-Zustand (nicht deployt), der Check ist Frühindikator, kein Alarm-Mechanismus.

## Korrektur Immich-DB-Dump (PR 8)

53. **`DB_DUMP_ALL` rief ungültiges `pg_dump --all` auf**: `--all` existiert nur bei `pg_dumpall`, nicht bei `pg_dump` — der Immich-Dump scheiterte mit `unrecognized option`. Fix: `DB_DUMP_ALL=true` nutzt jetzt `pg_dumpall -U postgres` (kompletter Cluster inkl. Rollen/Rechte, wie es die Immich-Doku für Migrationen empfiehlt); alle anderen Postgres-Services weiter mit `pg_dump --dbname`. Der Fehler wäre im echten Lauf als FAIL sichtbar geworden — der Consistency-Check aus diesem PR hätte ihn zusätzlich über den leeren/fehlenden Dump-Stand angezeigt.
