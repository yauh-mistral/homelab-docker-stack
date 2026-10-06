# Deployment auf Host `ovi`

Anleitung, um das Backup-System auf dem Ubuntu-Host `ovi` in Betrieb zu nehmen und einen Testrun zu starten.

## Architektur: Wer lebt wo?

```
/opt/docker/arcane/            Repo (Compose-Stacks + .env — die QUELLE)
└── projects/<stack>/compose.yaml + .env

/opt/docker/backup/            Heimat des Backup-Systems (die INSTALLATION)
├── backup.sh                  Dispatcher
├── restore.sh                 Restore pro Service
├── test-restore.sh             Dump-Restore-Test
├── install.sh                 (nur bei Installation; Kopierer)
├── lib/                       common.sh, db.sh
├── services.d/*.env           Service-Deklarationen (installierte Kopie)
└── docs/                      Referenz-Dokumentation

/etc/backup.conf               Konfiguration: Quelle, Ziel, Restic (chmod 600)
/mnt/systems/backups/ovi/      ZIEL auf dem NAS (db/ + files/ + _meta/)
```

Das Backup-System liegt **bewusst nicht im Repo-Checkout** (`/opt/docker/arcane`): Der Installer kopiert es nach `/opt/docker/backup` (konfigurierbar via `--home`). Repo-Updates überschreiben die Installation nicht; ein Re-Run von `install.sh` aktualisiert sie (Deklarationen in `services.d/` können individuell angepasst bleiben, `rsync` ohne `--delete`).

**Woher kommen Quelle und Ziel?** Ausdrücklich aus `/etc/backup.conf`:
- `STACKS_DIR` — wo Compose-Stacks und deren `.env` leben (z.B. `/opt/docker/arcane/projects`). Deklarationen nutzen den Platzhalter `%STACKS_DIR%` (z.B. `ENV_FILE=%STACKS_DIR%/ghost/.env`), der Dispatcher löst ihn auf. So bleibt die Deklaration host-agnostisch.
- `BACKUP_ROOT` — Ziel auf dem NAS (`/mnt/systems/backups/ovi`).
- `SERVICES_DIR` — Deklarations-Heimat (bei Installation `/opt/docker/backup/services.d`).

## Schritt 0: Voraussetzungen

- Ubuntu-Host `ovi` mit root-Zugriff, Docker läuft
- Repo-Checkout unter `/opt/docker/arcane` (aktuell: `sudo git pull`)
- NAS-Mount `/mnt/systems` eingebunden: `findmnt /mnt/systems`

## Schritt 1: Installation

```bash
cd /opt/docker/arcane
sudo git pull
sudo backup/install.sh \
  --home /opt/docker/backup \
  --stacks-dir /opt/docker/arcane/projects \
  --backup-root /mnt/systems/backups/ovi
```

Der Installer:
1. kopiert `backup.sh`, `restore.sh`, `test-restore.sh`, `lib/`, `services.d/` (und `docs/`) nach `/opt/docker/backup`
2. erzeugt `/etc/backup.conf` (mit `chmod 600`) bzw. ergänzt fehlende Einträge in einer bestehenden Datei

Alternativ ohne Parameter — der Installer fragt interaktiv nach dem Quellpfad.

## Schritt 2: Konfiguration prüfen

```bash
sudo cat /etc/backup.conf
```
Minimalinhalt:
```bash
STACKS_DIR=/opt/docker/arcane/projects      # Quelle: Compose + .env
BACKUP_ROOT=/mnt/systems/backups/ovi        # Ziel: NAS
SERVICES_DIR=/opt/docker/backup/services.d  # Heimat der Deklarationen
USE_RESTIC=false
```

## Schritt 3: DB-Passwörter (nur für MySQL/MariaDB-Services)

Postgres-Dumps laufen im Container über lokale Unix-Socket-Auth — kein Handbedarf. MySQL/MariaDB (`ghost`, ggf. `castopod`) brauchen `DB_PASSWORD`; die Ghost-Deklaration lädt es via `ENV_FILE=%STACKS_DIR%/ghost/.env`. Für castopod bei Bedarf in `services.d/castopod.env` ergänzen:
```bash
ENV_FILE=%STACKS_DIR%/castopod/.env
DB_PASSWORD_VAR=MYSQL_PASSWORD
```

## Schritt 4: Trockenlauf (verändert nichts)

```bash
sudo /opt/docker/backup/backup.sh --dry-run
```
Erwartung: pro Service `[DRY]`-Zeilen mit exakten `docker exec`/rsync-Befehlen, am Ende `OK=40 FAIL=0 SKIP=3`. `WARN` zu fehlenden Pfaden = Abweichung zwischen Deklaration und Host — prüfen oder als dokumentierte Lücke akzeptieren (`docs/QUESTIONS.md`).

## Schritt 5: Begrenzter erster echter Lauf

```bash
sudo /opt/docker/backup/backup.sh --service litellm
sudo ls -la /mnt/systems/backups/ovi/litellm/db/*/
```

## Schritt 6: Voller Testrun

```bash
sudo /opt/docker/backup/backup.sh
sudo grep FAIL /mnt/systems/backups/ovi/_meta/runs/<neuester-stamp>.log
```
Einzelfehler isolieren andere Services nicht (Fehler-Isolation pro Deklaration). Stop-Fenster-Services (arr-Stack, Home Assistant, Mealie, Kuma …) sind kurz down — nachts cron-fähig.

**SKIP-Semantik (Preflight):** Vor jedem Backup prüft der Dispatcher, ob die Quelle existiert (DB-Container via `docker inspect`, Dateipfade via Dateisystem). Ergebnis:

- Quelle komplett vorhanden → normales Backup.
- DB-Container fehlt/läuft nicht, aber Dateien vorhanden (oder umgekehrt) → **Teil-Backup** mit `WARN`, kein FAIL.
- Quelle fehlt komplett (Service nicht deployt, Container unbekannt, Pfade falsch) → **SKIP** mit `INFO`, kein FAIL. Der Lauf bleibt grün.
- Falsch deklarierte Services (DB-Kategorie ohne `DB_TYPE`, leere `FILE_PATHS`) bleiben FAIL — das ist ein Deklarationsfehler, kein Host-Zustand.
- Docker-Daemon nicht erreichbar (echter Lauf) → harter Abbruch statt 43 SKIPs.

`SKIP` bedeutet damit zweierlei: per Deklaration `ignore` ODER „Quelle auf diesem Host nicht vorhanden“. Die Lücken-Liste am Ende des Laufs (`WARN - DB-Container fehlt: …`) zeigt genau, welche Services nicht deployt sind — Auslieferung auf ovi ohne FAIL-Alarm möglich.

## Schritt 7: Restore-Test

```bash
sudo /opt/docker/backup/test-restore.sh          # default: litellm
sudo /opt/docker/backup/test-restore.sh --all   # alle Postgres-Services
```

## Schritt 8: Cron-Aktivierung

```bash
sudo crontab -e
```
```cron
0 2 * * * /opt/docker/backup/backup.sh --only-db >> /mnt/systems/backups/ovi/_meta/cron.log 2>&1
30 2 * * * /opt/docker/backup/backup.sh >> /mnt/systems/backups/ovi/_meta/cron.log 2>&1
0 3 * * 0 /opt/docker/backup/backup.sh --only-config >> /mnt/systems/backups/ovi/_meta/cron.log 2>&1
```
`flock` ist im Dispatcher eingebaut (parallele Läufe blockiert). Nach dem Testrun Cron-Zeiten gegen die tatsächliche Laufzeit prüfen (große rsync-Ziele wie `/mnt/immich` — ggf. Immich-Dateianteil wöchentlich, QUESTIONS.md #13).

## Schritt 9: Restic (optional)

```bash
sudo apt-get install -y restic
sudo sh -c 'openssl rand -base64 32 > /etc/restic-password && chmod 600 /etc/restic-password'
# in /etc/backup.conf: USE_RESTIC=true
```

## Monitoring & Betrieb

- Letzter Lauf: `cat /mnt/systems/backups/ovi/_meta/last-run-summary.txt`
- Logs: `ls -t /mnt/systems/backups/ovi/_meta/runs/ | head -1`
- Service nachziehen: `sudo /opt/docker/backup/backup.sh --service <name>`
- Restore: `docs/RESTORE.md`, zuerst `--dry-run`

## Updates des Backup-Systems

Repo-Änderungen (neue Deklarationen, Fixes) einspielen:
```bash
cd /opt/docker/arcane && sudo git pull
sudo backup/install.sh --stacks-dir /opt/docker/arcane/projects --backup-root /mnt/systems/backups/ovi
```
`install.sh` aktualisiert die Installation (rsync ohne `--delete`: lokal angepasste Deklarationen bleiben erhalten).

## Sicherheitshinweise

- Dispatcher läuft als root (Docker-Socket, Stop-Fenster). `/etc/backup.conf` mit `chmod 600`.
- Passwörter nie auf Prozess-Kommandozeilen (`MYSQL_PWD` via `docker exec -e`), Dumps unverschlüsselt auf dem NAS — bei Bedarf Restic aktivieren.
- Bei abgemountetem NAS verweigert der Dispatcher den Start (`require_mounted_target`) statt lokal zu schreiben.
