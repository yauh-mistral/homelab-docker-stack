# Deployment auf Host `ovi`

Anleitung, um das Backup-System auf dem Ubuntu-Host `ovi` in Betrieb zu nehmen und einen Testrun zu starten.

## Architektur: Wer lebt wo?

```
/opt/docker/arcane/            Repo (Compose-Stacks + .env — die QUELLE)
└── projects/<stack>/compose.yaml + .env

/opt/docker/tools/                Heimat aller Host-Tools (die INSTALLATION)
├── backup/                    Backup-System (installiert via tools/backup/install.sh)
│   ├── backup.sh                  Dispatcher
│   ├── restore.sh                 Restore pro Service
│   ├── test-restore.sh            Dump-Restore-Test
│   ├── install.sh                 (nur bei Installation; Kopierer)
│   ├── lib/                       common.sh, db.sh
│   ├── policies.d/*.env           Policy-Overlays (installierte Kopie)
│   └── docs/                      Referenz-Dokumentation
├── arcane/                    Bootstrap-Compose für Arcane selbst (compose.yml, Projekt 'base')
└── maintenance/               docker-maintenance.sh (prune, inkl. Volumes)

/etc/backup.conf               Konfiguration: Quelle, Ziel, Restic (chmod 600)
/mnt/systems/backups/ovi/      ZIEL auf dem NAS (db/ + files/ + logs/)
```

Das Backup-System liegt **bewusst nicht im Repo-Checkout** (`/opt/docker/arcane`): Der Installer kopiert es nach `/opt/docker/tools/backup` (konfigurierbar via `--home`). Repo-Updates überschreiben die Installation nicht; ein Re-Run von `install.sh` aktualisiert sie (Policies in `policies.d/`/`policy.conf` können individuell angepasst bleiben, `rsync` ohne `--delete`).

**Woher kommen Quelle und Ziel?** Ausdrücklich aus `/etc/backup.conf`:
- `STACKS_DIR` — wo Compose-Stacks und deren `.env` leben (z.B. `/opt/docker/arcane/projects`). Deklarationen nutzen den Platzhalter `%STACKS_DIR%` (z.B. `ENV_FILE=%STACKS_DIR%/ghost/.env`), der Dispatcher löst ihn auf. So bleibt die Deklaration host-agnostisch.
- `BACKUP_ROOT` — Ziel auf dem NAS (`/mnt/systems/backups/ovi`).
- `POLICY_DIR` — Policy-Heimat (bei Installation `/opt/docker/tools/backup/policies.d`).

## Schritt 0: Voraussetzungen

- Ubuntu-Host `ovi` mit root-Zugriff, Docker läuft
- Repo-Checkout unter `/opt/docker/arcane` (aktuell: `sudo git pull`)
- NAS-Mount `/mnt/systems` eingebunden: `findmnt /mnt/systems`

**Arcane läuft nicht aus dem Repo-Projektverzeichnis.** Arcane kann sich nicht selbst hosten (Bootstrap-Problem: Die Verwaltungsoberfläche kann den Compose-Stack, der sie selbst startet, nicht verwalten). Der Arcane-Container läuft daher aus einem host-seitigen Compose-File: `/opt/docker/tools/arcane/compose.yml` (Repo-Vorlage: `tools/arcane/compose.yml`; Compose-Projektname `base`, Image `ghcr.io/getarcaneapp/arcane:latest`, Mounts auf `/opt/docker/arcane/data` und `/opt/docker/arcane/projects`). Start/Update von Hand:

```bash
cd /opt/docker/tools/arcane
docker compose pull && docker compose up -d   # Arcane (base-Projekt) aktualisieren
```

Alle **anderen** Stacks werden als Projekte von Arcane verwaltet (`/opt/docker/arcane/projects`).

## Schritt 1: Installation

```bash
cd /opt/docker/arcane
sudo git pull
sudo tools/backup/install.sh \
  --home /opt/docker/tools/backup \
  --stacks-dir /opt/docker/arcane/projects \
  --backup-root /mnt/systems/backups/ovi
```

Der Installer:
1. kopiert `backup.sh`, `restore.sh`, `test-restore.sh`, `lib/`, `policies.d/`, `policy.conf` (und `docs/`) nach `/opt/docker/tools/backup`
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
POLICY_DIR=/opt/docker/tools/backup/policies.d  # Heimat der Policy-Overlays
USE_RESTIC=false
```

## Schritt 3: Trockenlauf (verändert nichts) (verändert nichts)

```bash
sudo /opt/docker/tools/backup/backup.sh --dry-run
```
Erwartung: pro Service `[DRY]`-Zeilen mit exakten `docker exec`/rsync-Befehlen, am Ende `OK=40 FAIL=0 SKIP=3`. `WARN` zu fehlenden Pfaden = Abweichung zwischen Deklaration und Host — prüfen oder als dokumentierte Lücke akzeptieren (`docs/TODOS.md`).

## Schritt 5: Begrenzter erster echter Lauf

```bash
sudo /opt/docker/tools/backup/backup.sh --service litellm
sudo ls -la /mnt/systems/backups/ovi/litellm/db/*/
```

## Schritt 6: Voller Testrun

```bash
sudo /opt/docker/tools/backup/backup.sh
sudo grep FAIL /mnt/systems/backups/ovi/logs/<neuester-stamp>.log
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
sudo /opt/docker/tools/backup/test-restore.sh          # default: litellm
sudo /opt/docker/tools/backup/test-restore.sh --all   # alle Postgres-Services
```

## Schritt 8: Cron-Aktivierung

```bash
sudo crontab -e
```
```cron
30 2 * * * /usr/bin/flock -n /tmp/backup-dispatcher.lock /opt/docker/tools/backup/backup.sh >> /var/log/backup-dispatcher.log 2>&1
30 4 * * 0 /opt/docker/tools/maintenance/docker-maintenance.sh >> /var/log/docker-maintenance.log 2>&1
```

Die Maintenance-Zeile (sonntags 04:30) prunt bewusst auch Volumes (`--volumes`-Verhalten ist Default; `--no-volumes` zum Deaktivieren). Sie läuft nie parallel zu Backups — das Skript bricht selbst ab, wenn ein Backup-/Restore-Prozess läuft (Stop-Fenster-Container wären sonst Verlustkandidaten).
`flock` ist im Dispatcher eingebaut (parallele Läufe blockiert). Nach dem Testrun Cron-Zeiten gegen die tatsächliche Laufzeit prüfen (große rsync-Ziele wie `/mnt/immich` — ggf. Immich-Dateianteil wöchentlich, TODOS.md #13).

## Versionierung & Retention (rsnapshot-Stil)

Ziel-Pfade enthalten **keine Timestamps** mehr. Jeder Service hat rotierende Versionen:

```text
/mnt/systems/ovi/backups/<service>/db/v.0     <- aktuellster Stand
                                                  v.1 ... v.KEEP_VERSIONS-1
```

- Vor jedem Backup schiebt der Dispatcher `v.0 -> v.1 -> ... -> v.N-1`, die älteste Version fällt weg.
- `KEEP_VERSIONS` (Default: **14**) in `/etc/backup.conf` konfigurierbar — z.B. `KEEP_VERSIONS=30`.
- rsync nutzt `--link-dest=v.1`: unveränderte Dateien sind Hardlinks zum Vortag — pro Version nur echte Änderungen, Speicherbedarf bleibt flach (NFS unterstützt Hardlinks; auf CIFS läuft es ohne Verlinkung, verbraucht dann mehr Platz).
- Timestamps stehen nicht im Pfad, sondern im Log: jede stdout- und Log-Zeile beginnt mit `YYYY-MM-DD HH:MM:SS` — Dauer einzelner Schritte direkt ablesbar.
- Restore mit Version statt Datum: `restore.sh <service>` (neueste Version = `v.0`) oder `restore.sh <service> --version v.3`.
- Am Laufende prüft der **Consistency-Check** alle Ziel-Stände: existiert `v.0`, ist er nicht leer, enthalten DB-Stände mind. einen Dump > 0 Bytes. Probleme erscheinen als `WARN` im Log.
- Alte timestamp-basierte Stände (vor dieser Umstellung) bleiben über den `latest_dir`-Fallback im Restore lesbar.

## Schritt 9: Restic (optional)

```bash
sudo apt-get install -y restic
sudo sh -c 'openssl rand -base64 32 > /etc/restic-password && chmod 600 /etc/restic-password'
# in /etc/backup.conf: USE_RESTIC=true
```

## Monitoring & Betrieb

- Letzter Lauf: `cat /mnt/systems/backups/ovi/logs/last-run-summary.txt`
- Logs: `ls -t /mnt/systems/backups/ovi/logs/ | head -1`
- Service nachziehen: `sudo /opt/docker/tools/backup/backup.sh --service <name>`
- Restore: `docs/RESTORE.md`, zuerst `--dry-run`

## Updates des Backup-Systems

Repo-Änderungen (neue Deklarationen, Fixes) einspielen:
```bash
cd /opt/docker/arcane && sudo git pull
sudo tools/backup/install.sh --stacks-dir /opt/docker/arcane/projects --backup-root /mnt/systems/backups/ovi
```
`install.sh` aktualisiert die Installation (rsync ohne `--delete`: lokal angepasste Deklarationen bleiben erhalten).

## Sicherheitshinweise

- Dispatcher läuft als root (Docker-Socket, Stop-Fenster). `/etc/backup.conf` mit `chmod 600`.
- Passwörter nie auf Prozess-Kommandozeilen (`MYSQL_PWD` via `docker exec -e`), Dumps unverschlüsselt auf dem NAS — bei Bedarf Restic aktivieren.
- Bei abgemountetem NAS verweigert der Dispatcher den Start (`require_mounted_target`) statt lokal zu schreiben.
