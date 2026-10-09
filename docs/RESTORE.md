# Restore-Anleitung pro Backup-Kategorie

Allgemein: `backup/restore.sh <service> [--date YYYY-MM-DD_HHMM] [--dry-run]`
Liste der Services: `backup/backup.sh --list`. Backup-Stände: `/mnt/systems/backups/&lt;host&gt;/&lt;service&gt;/db|files/&lt;zeitstempel&gt;`.

**Vor jedem Restore**: `backup/backup.sh --service <name>` laufen lassen (frischer Stand) oder bewusst den letzten Stand verwenden. `--dry-run` zuerst zeigen lassen, was passieren würde.

## Kategorie: DB-Dump (postgres / mysql / mariadb)

Services: analytics, castopod, ghost, immich, litellm, n8n, paperless

1. Service-Stack ggf. stoppen (App-Container, NICHT die DB): `docker stop <app-container>` — sonst schreiben Apps während des Restores.
2. `backup/restore.sh <service> --db-only`
   - Postgres: `gunzip -c dump.sql.gz | docker exec -i <db> psql -U <user> -d <db> --single-transaction --set ON_ERROR_STOP=on`
   - MySQL/MariaDB: analog mit `mysql -u<user> <db>` (Passwort via Env).
3. App-Container wieder starten.
4. **Verifizieren**: Login testen, Objektzahl plausibilisieren (z.B. Immich: Fotos zählen; n8n: Workflows auflisten).

Spezialfälle:
- **Immich**: Restore in eine *leere* DB (Doku: frische Installation, `docker compose create`, nur DB-Container starten, Dump einspielen, dann Rest starten). Der Dump enthält `--clean --if-exists` bzw. pg_dumpall-Form und kann über bestehende Strukturen gespielt werden.
- **Ghost**: beide Schemas (`ghost_prod`, `ghost_activitypub`) sind im Dump enthalten (dump wurde über die Instanz erstellt); ActivityPub-Container nach Restore mitstarten.
- **Forgejo** (`DB_TYPE=forgejo`): der `forgejo dump` liegt als ZIP vor. Manueller Restore (Forgejo-/Gitea-Doku):
  1. Stack stoppen. 2. ZIP entpacken. 3. `data/*` nach `/data/gitea`, `repos/*` nach `/data/git/gitea-repositories/` verschieben. 4. `chown -R git:git /data`. 5. `forgejo admin regenerate hooks` (bzw. `gitea admin regenerate hooks`) ausführen. 6. Stack starten.
- **Open-Notebook** (`DB_TYPE=surreal`): `docker exec <c> surreal import --conn rocksdb:/mydata -f export.surql` (Export-Datei aus dem Backup-Stand).

## Kategorie: DB-Dump (sqlite) — Vaultwarden

Hersteller-Prozedur (Vaultwarden-Wiki):
1. Container stoppen: `docker stop vaultwarden`
2. **`db.sqlite3-wal` und `db.sqlite3-shm` löschen** (sonst Korruption durch stale WAL!)
3. Dump-Datei (`db.sqlite3.sqlite3` aus dem Backup-Stand) nach `/opt/docker/vaultwarden/db.sqlite3` kopieren.
4. `docker start vaultwarden`
5. Verifizieren: Login, Vault-Inhalt stichprobenartig prüfen.

`restore.sh vaultwarden` führt Schritt 1–4 automatisch aus (Stop → WAL löschen → Kopie → Start).

## Kategorie: Datei-Rsync-Restic (und config_only mit Stop-Fenster)

Services: immich (files), castopod (media), opencloud, paperless (files), n8n (.n8n), vaultwarden (attachments/sends), wanderer, forgejo (repos), ghost (content) sowie alle config_only-Services.

1. `backup/restore.sh <service> --files-only [--date ...]`
   - Das Skript öffnet automatisch das Stop-Fenster (deklarierte `STOP_CONTAINERS`), rsynct die Dateien zurück und startet die Container wieder.
2. **Verifizieren** je Service:
   - Immich: Fotos sichtbar, Thumbs bauen sich nach.
   - Paperless: Dokumente durchsuchbar (ggf. `document_importer` bei Export-Backups).
   - OpenCloud: Login + Dateiliste; Hersteller: Restore im gestoppten Zustand; danach Start und Funktionstest (Datei hochladen/runterladen).
   - arr-Services (sonarr etc.): UI öffnen, Serien/Filme vorhanden, keine DB-Fehler im Log.
3. **Achtung Restore-Richtung**: `restore_files` überschreibt den aktuellen Zustand des Zielpfads mit dem Backup-Stand (`rsync -a` ohne `--delete` — Dateien, die im Backup nicht sind, bleiben liegen; für exakte Spiegelung `rsync -a --delete` manuell nachziehen).

## Kategorie: config_only ohne Stop-Fenster (node-red, homepage, searxng, web-proxy, mosquitto, codex, dnd)

1. `backup/restore.sh <service> --files-only`
2. Container i.d.R. neu starten (`docker restart <c>`), damit Config neu eingelesen wird.
3. Verifizieren: Seite/Flow erreichbar, Proxy-Routen funktionieren (web-proxy: `docker exec web-proxy-nginx nginx -t` vor dem Reload!).

## Kategorie: ignorieren

Für als `ignore` deklarierte Services (crawl4ai, firecrawl, metube, Media-Libraries) gibt es keinen Restore — sie sind aus dem Compose-Stack neu aufsetzbar bzw. die Daten liegen in den Media-Backups anderer Systeme.

## Restore-Test (halbautomatisch)

`backup/test-restore.sh [service]` — spielt den Dump in einen Wegwerf-`postgres:16-alpine`-Container ein und prüft, dass Tabellen entstehen. Empfehlung: monatlich für alle Postgres-Services (`--all`) ausführen; Ergebnis im Lauf-Log dokumentieren.

## Checkliste nach jedem Restore

- [ ] Service-Container laufen (`docker ps`)
- [ ] Logs frei von DB-Fehlern (`docker logs --tail 50 <c>`)
- [ ] Funktionsprobe über die UI/API
- [ ] Backup-Lauf wieder aktivieren (falls deaktiviert) und einmalig manuell triggern
