# Deployment auf Host `ovi`

Anleitung, um das Backup-System auf dem Ubuntu-Host `ovi` in Betrieb zu nehmen und einen Testrun zu starten.

## Voraussetzungen

- Ubuntu-Host `ovi` mit root-Zugang (oder sudo), Docker läuft
- Repo-Checkout liegt auf ovi unter `/opt/docker/arcane` (im Snapshot sichtbar: `/opt/docker/arcane/projects` — dort liegt dieses Repo)
- NAS-Mount `/mnt/systems` ist eingebunden (`findmnt /mnt/systems` muss einen Mount zeigen)

## Schritt 1: Repo auf den aktuellen Stand bringen

```bash
cd /opt/docker/arcane
sudo git pull
```

## Schritt 2: Konfigurationsdatei anlegen

Der Dispatcher liest optional `/etc/backup.conf`. Für den ersten Testrun genügen Defaults (Ziel `/mnt/systems/backups/ovi`), aber die Datei ist der saubere Ort für Overrides:

```bash
sudo tee /etc/backup.conf >/dev/null <<'EOF'
# Backup-Konfiguration fuer ovi
BACKUP_ROOT=/mnt/systems/backups/ovi
DRY_RUN=false
VERBOSE=false
# Restic optional (erst aktivieren, wenn restic installiert + Passwortdatei existiert):
USE_RESTIC=false
# RESTIC_PASSWORD_FILE=/etc/restic-password
EOF
sudo chmod 600 /etc/backup.conf
```

## Schritt 3: DB-Passwörter (nur für MySQL/MariaDB-Services)

Postgres-Dumps laufen im Container über die lokale Unix-Socket-Auth (`pg_dump -U <user>` ohne Passwort) — kein Handbedarf.

MySQL/MariaDB (`ghost`, `castopod`) brauchen `DB_PASSWORD`. Die Ghost-Deklaration lädt es selbstständig via `ENV_FILE=/opt/docker/arcane/projects/ghost/.env`. Prüfen:
```bash
grep '^DB_PASSWORD=' /opt/docker/arcane/projects/ghost/.env
```
Für castopod analog `MYSQL_PASSWORD` — falls der Dump ohne Passwort scheitert, in `backup/services.d/castopod.env` ergänzen:
```bash
ENV_FILE=/opt/docker/arcane/projects/castopod/.env
DB_PASSWORD_VAR=MYSQL_PASSWORD
```

## Schritt 4: Trockenlauf (verändert nichts)

```bash
cd /opt/docker/arcane/backup
sudo ./backup.sh --dry-run
```
Erwartung: pro Service `[DRY]`-Zeilen mit den exakten `docker exec`/rsync-Befehlen, am Ende `OK=40 FAIL=0 SKIP=3`. `WARN`-Zeilen zu fehlenden Pfaden/Containern bedeuten Abweichungen zwischen Deklaration und Host — vor dem echten Lauf prüfen und Deklaration korrigieren oder als bereits dokumentierte Lücke akzeptieren (siehe `docs/QUESTIONS.md`).

## Schritt 5: Begrenzter erster echter Lauf (ein kleiner Service)

```bash
sudo ./backup.sh --service litellm
sudo ls -la /mnt/systems/backups/ovi/litellm/db/*/ /mnt/systems/backups/ovi/litellm/files/*/
```
Prüfen: Dump ist nicht-leer (`*.sql.gz`), Log zeigt `[OK]`.

## Schritt 6: Voller Testrun

```bash
sudo ./backup.sh
```
- Einzelfehler isolieren: `sudo grep FAIL /mnt/systems/backups/ovi/_meta/runs/<neuester-stamp>.log`
- Exit-Code 0 = alle Services OK; einzelne FAILs beenden andere Services nicht (Fehler-Isolation pro Service).
- Typische erste-Lauf-Fälle:
  - DB-Container ohne laufende Healthcheck-Auth → `wait_for_postgres` protokolliert, Dump wird nachgeholt
  - SQLite-Apps mit Stop-Fenster (arr-Stack, Home Assistant, Mealie, Kuma …) sind kurz down (Sekunden bis wenige Minuten); Lauf daher nachts cron-fähig

## Schritt 7: Restore-Test (Proof, dass Dumps nutzbar sind)

```bash
sudo ./test-restore.sh          # default: litellm
sudo ./test-restore.sh --all     # alle Postgres-Services
```
Erwartung: `[OK] <svc>: Restore-Test BESTANDEN (N Tabellen ...)` — Dump wird in Wegwerf-Postgres eingespielt, Produktiv-DB unberührt.

## Schritt 8: Cron-Aktivierung

```bash
sudo crontab -e
```
Eintragen:
```cron
# DB-Dumps taeglich 02:00 (versetzt zu Immich-internen 02:00-Dumps um Kollision zu vermeiden -> 02:30 siehe Strategie)
0 2 * * * /opt/docker/arcane/backup/backup.sh --only-db >> /mnt/systems/backups/ovi/_meta/cron.log 2>&1
# Datei-Backups taeglich 02:30 (im selben Lauf gemaess Strategie nach den DBs)
30 2 * * * /opt/docker/arcane/backup/backup.sh >> /mnt/systems/backups/ovi/_meta/cron.log 2>&1
# Config-only woechentlich Sonntag 03:00
0 3 * * 0 /opt/docker/arcane/backup/backup.sh --only-config >> /mnt/systems/backups/ovi/_meta/cron.log 2>&1
```
Hinweis: `flock` ist im Dispatcher eingebaut (parallele Läufe blockiert). Nach dem Testrun die Cron-Zeiten gegen die tatsächliche Laufzeit prüfen (große rsync-Ziele wie `/mnt/immich` können den 02:30-Lauf überlappen — ggf. Immich-Dateianteil auf wöchentlich umstellen, siehe QUESTIONS.md #13).

## Schritt 9: Restic (optional)

```bash
sudo apt-get install -y restic
sudo sh -c 'openssl rand -base64 32 > /etc/restic-password && chmod 600 /etc/restic-password'
# in /etc/backup.conf: USE_RESTIC=true setzen
```
Wichtig: Passwortdatei zusätzlich ins Offsite-Sicherungskonzept (nicht nur auf ovi selbst).

## Monitoring & Betrieb

- Letzter Lauf: `cat /mnt/systems/backups/ovi/_meta/last-run-summary.txt` (`OK=x FAIL=y SKIP=z`)
- Logs: `ls -t /mnt/systems/backups/ovi/_meta/runs/ | head -1` dann Datei ansehen
- Ein Service manuell nachziehen: `sudo ./backup.sh --service <name>`
- Restore: `docs/RESTORE.md` und `sudo ./restore.sh <name> --dry-run` zuerst

## Sicherheitshinweise

- Der Dispatcher läuft als root (Zugriff auf `/opt/docker`, Docker-Socket, Stop-Fenster). Cron-Dateien und `/etc/backup.conf` mit `chmod 600` schützen.
- Passwörter werden nie auf Prozess-Kommandozeilen sichtbar (`MYSQL_PWD` via `docker exec -e`), Dumps liegen unverschlüsselt auf dem NAS — bei Bedarf Restic aktivieren (verschlüsselt das Repo).
- Bei abgemountetem NAS verweigert der Dispatcher den Start (`require_mounted_target`), statt lokal zu schreiben.
