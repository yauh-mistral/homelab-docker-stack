# AGENTS.md — Leitlinie für die Zusammenarbeit an arcane-docker-stack

## Ziel & Umgebung

- **Zielsystem**: Ubuntu 26.04 mit Docker (Host `ovi`). Services können jederzeit deployed, gestartet, gestoppt oder entfernt sein — der Backup-Dispatcher muss damit umgehen (SKIP bei nicht deploytem Service, Teil-Backup bei halb fehlender Quelle, nie stiller Scheinerfolg).
- **Datenhaltung**: Nutzdaten liegen als Bind-Mounts im Host-Dateisystem (`/opt/docker/...`), auch Datenbanken. **Docker Volumes werden nie für zu sichernde Daten genutzt.** NAS-Mounts (`/mnt/...`) sind nie Backup-Quelle — das NAS hat sein eigenes Backup.
- **Restore-Philosophie**: Restore muss mit minimalen Daten funktionieren. Vollständig gesichert werden: Nutzdaten (Medien etc.), Konfiguration, Metadaten, Permissions. **Nicht gesichert**: Thumbnails, Logs, temporäre Dateien — alles, was der Container beim Start selbst regeneriert. **Compute/Zeit beim Restore ist akzeptabel, wenn dadurch das Backup kürzer und kleiner wird.**
- **Keine doppelten Backups**: Wenn Daten sowohl auf Platte als auch in einer DB liegen und aus einem von beiden rekonstruierbar sind, nur eines sichern (Beispiel: Forgejo-Repos vs. `forgejo dump --skip-repository`).

## Git/PR-Workflow (wichtig!)

- **Vor jedem neuen PR**: Prüfen, ob es bereits einen offenen PR gibt, der ergänzt werden kann — bestehenden PR aktualisieren (Branch pushen), statt einen neuen zu öffnen. Branch-Head checken, bei Rewrites `--force-with-lease`.
- **Niemals annehmen, dass ein Change automatisch in einen offenen PR integriert wird** — Merge-Status und Branch-Divergenz prüfen (passiert schon zweimal: Fixes liefen Gefahr, hinter einem Merge zu verschwinden).
- Branches: `vibe/<slug>-5f329e`, Draft-PR als Standard, kein Push auf `main`.
- Commits fokussiert und beschreibend; PR-Body mit Summary + Verification.

## Versionierung

- `SCRIPT_VERSION` (Semantic Versioning) **nur** für `backup/`, `restore.sh`, `install.sh` — Start v0.0.1. MAJOR = Breaking (Config/Deklarationsformat/CLI), MINOR = Feature, PATCH = Fix.
- **Hilfsskripte** (z. B. `make-env-examples.sh`) bekommen **keine** Versionsnummer.
- `install.sh` stempelt die installierte Kopie mit Installationszeitpunkt (`INSTALL_STAMP`, `YYYY-MM-DD HH:MM`). Jedes Log beginnt mit `=== Version (vX.Y.Z <stamp>) ===` — veraltete Stände sofort erkennbar.

## .env-Konventionen

- **`.env`-Dateien werden nie ausgeliefert** — immer nur `.env.example` mit maskierten Werten (`REPLACE_ME`).
- **Wahrheit lebt auf dem Host** in `/opt/docker/arcane/projects/<project>/.env` (bzw. `STACKS_DIR`). Das Repo dupliziert nie Credentials.
- **Gleicher Purpose = gleicher Name**: DB-Credentials heißen einheitlich nach DB-System (`POSTGRES_PASSWORD`, `MARIADB_ROOT_PASSWORD`, ...), Compose-`environment:`-Namen dürfen service-spezifisch sein (Compose mappt).
- Secret-Maskierung mit **sachgerechten Herstellungs-Hinweisen**: Passwörter `openssl rand -base64 24`, Secrets/Keys `openssl rand -hex 32`, Salts `-hex 32`; **SMTP-Passwörter kommen vom Mail-Provider** (nicht generieren); **self-hosted Tokens** (vaultwarden `ADMIN_TOKEN`) einmalig selbst festlegen; externe API-Keys beim Anbieter erstellen. Vorhandene Kommentar-Erklärung über der Variable nicht duplizieren.
- Verbindliche Secret-Liste und Format-Konventionen: `projects/env-details.md` (URL-Formate: trailing slash, Trennzeichen, Schemata).

## Backup-System-Design (Stand)

- Deklarationen in `backup/services.d/*.env` (Kategorien: db_only/files_only/db_and_files/config_only/ignore). Rotation rsnapshot-artig (`v.0..v.N`), kein Timestamp im Pfad.
- **Bekannte offene Baustellen** (priorisiert): Ghost-Root-Dump verifizieren (MySQL 9 FLUSH TABLES/RELOAD), PARTIAL-Status statt WARN+OK einführen, Tool-Output im Log mit Service-Prefix versehen, vaultwarden-SQLite (Volume-Pfad auflösen oder Copy im Stop-Fenster), bekannte SKIP-Lücken demuten (Whitelist), Consistency vs. Lauf-Status vereinheitlichen, `--list` soll ohne `STACKS_DIR`-Abbruch funktionieren.
- Ziel-Konzept (beschlossen, noch nicht umgesetzt): **Inventar & Credentials aus der Compose-Wahrheit ableiten** (`docker compose config --format json`), `services.d/` reduziert sich auf Backup-Policy; Policy liegt künftig neben dem Projekt (`projects/<p>/backup.env`); Drift zwischen Deklaration und Realität als eigene Validierungsphase.

## Stil & Kommunikation

- Deutsch als Arbeitssprache, prägnant, Versions-/Formatkonventionen dokumentieren statt implizit voraussetzen.
- Logs: ISO-artige Timestamps einheitlich, kein unprefixter Tool-Output, Teil-Backups nicht als vollwertiges OK verkaufen, Summary-Zeile mit Zahlen am Laufende.
- Bei Unsicherheit über Secret-Status: konservativ maskieren und im PR dokumentieren, Owner entscheidet.
- Skalpell statt Rasenmäher: keine funktionalen Nebenänderungen bei Format/Struktur-Harmonisierung (Schritt-5-Prinzip der env-Migration).
