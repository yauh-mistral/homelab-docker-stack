# AGENTS.md — Leitlinie für die Zusammenarbeit an arcane-docker-stack

## Repo-Zweck & Doku-Verteilung

- Dieses Repo umfasst die **gesamte Docker-Landschaft des Hosts**: Compose-Stacks (`projects/`), die Host-Tools (`tools/`: `backup/` Backup-System, `arcane/` Bootstrap-Compose für Arcane selbst, `maintenance/` Docker-Pflege/prune) und die In-depth-Doku (`docs/`). Kernstück ist **Arcane** als Verwaltungsoberfläche, unter der alle Stacks als Projekte laufen. Installationspfad der Tools auf dem Host: `/opt/docker/tools/` (Backup-System unter `/opt/docker/tools/backup`).
- **README.md** = Überblick: Komponenten, Stacks, Zusammenhänge (inkl. Mermaid-Diagramm), Kurzfassungen mit Link auf docs/. **Keine Schritt-für-Schritt-Anleitungen im README.**
- **docs/** = In-depth: DEPLOYMENT.md (Installation/Inbetriebnahme/Cron), BACKUP-STRATEGIE.md (Strategie/Policy-Referenz), RESTORE.md (Restore), INVENTAR.md (Service-Inventar), TODOS.md (offene Todos/entscheidene Annahmen).
- **Redundanz-Regel**: Jedes Thema hat genau eine ausführliche Heimat; das andere verlinkt mit Kurzfassung. Nie Inhalte doppelt pflegen — bei Änderungen beide Stellen prüfen oder die Kurzfassung bewusst generisch halten.

## Docker-Projects-Thematik (projects/)

- **Stack-Anlage**: Jeder Stack liegt in `projects/<stack>/` mit `compose.yaml` (+ optionalem `.env.example`). Keine `.env` im Repo (siehe .env-Konventionen unten).
- **Arcane als Verwaltung**: Stacks werden als Projekte in Arcane verwaltet. Das Repo ist die Deklarationsquelle; der Deploy-Status entscheidet sich zur Laufzeit (Discovery nutzt `docker ps`, nicht das Repo).
- **Service hinzufügen/entfernen**: compose.yaml im Stack anpassen (oder neuen Stack anlegen), `.env.example` pflegen, auf dem Host die echte `.env` befüllen, dann `docker compose up -d`. Entfernte Services muss der Backup-Dispatcher unbeeindruckt verkraften (SKIP).
- **Bind-Mount-Konvention**: Nutzdaten unter `/opt/docker/<service>/`. Docker Volumes nie für zu sichernde Daten. NAS-Mounts (`/mnt/...`) nie als Backup-Quelle.
- **Backup-Anbindung**: Neue Services mit laufender DB oder Mounts werden vom Auto-Discovery automatisch erkannt und gesichert. Nur bei Besonderheiten (rebuildbare Daten, Caches, DB-Tool-Anpassungen) eine Policy in `tools/backup/policies.d/` anlegen — mit Begründungskommentar, damit die Ausnahme später nachvollziehbar bleibt.

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

- **Phase 1 (aktuell): Einfrieren bei v1.0.0 + Build-Nummer.** Bis der erste vollständige Ende-zu-Ende-Test erfolgreich durchgelaufen ist (Discovery → Dry-Run → echter Lauf → `test-restore.sh --all` alles grün), bleibt `SCRIPT_VERSION` bei v1.0.0. Der Patch-Level wird über `SCRIPT_BUILD` (PR-Nummer) erkannt: Log zeigt `v1.0.0+#<PR> <stamp>`.
- **Phase 2 (nach E2E-Erfolg): Semantic Versioning Mode.** Sobald der E2E-Test komplett grün ist, wird auf SemVer umgestellt: MAJOR = Breaking (Config/Deklarationsformat/CLI), MINOR = Feature, PATCH = Fix. Der Übergang selbst ist ein User-Entscheid, nicht automatisch.
- **`SCRIPT_BUILD`** (PR-Nummer) wird von der GitHub Action `.github/workflows/build-number.yml` nach jedem Merge automatisch nachgetragen (liest `(#N)` aus dem Merge-Commit-Subject). Manuelle Pflege entfällt.
- `SCRIPT_VERSION` gilt **nur** für `tools/backup/` (`backup.sh`, `restore.sh`, `test-restore.sh`, `install.sh`) — Hilfsskripte wie `tools/maintenance/docker-maintenance.sh` bekommen **keine** Versionsnummer.
- `install.sh` stempelt die installierte Kopie mit Installationszeitpunkt (`INSTALL_STAMP`, `YYYY-MM-DD HH:MM`) und `SCRIPT_BUILD`. Jedes Log beginnt mit der Versionszeile (`vX.Y.Z+#<PR> <stamp>`) — veraltete Stände sofort erkennbar.

## .env-Konventionen

- **`.env`-Dateien werden nie ausgeliefert** — immer nur `.env.example` mit maskierten Werten (`REPLACE_ME`).
- **Wahrheit lebt auf dem Host** in `/opt/docker/arcane/projects/<project>/.env` (bzw. `STACKS_DIR`). Das Repo dupliziert nie Credentials.
- **Gleicher Purpose = gleicher Name**: DB-Credentials heißen einheitlich nach DB-System (`POSTGRES_PASSWORD`, `MARIADB_ROOT_PASSWORD`, ...), Compose-`environment:`-Namen dürfen service-spezifisch sein (Compose mappt).
- Secret-Maskierung mit **sachgerechten Herstellungs-Hinweisen**: Passwörter `openssl rand -base64 24`, Secrets/Keys `openssl rand -hex 32`, Salts `-hex 32`; **SMTP-Passwörter kommen vom Mail-Provider** (nicht generieren); **self-hosted Tokens** (vaultwarden `ADMIN_TOKEN`) einmalig selbst festlegen; externe API-Keys beim Anbieter erstellen. Vorhandene Kommentar-Erklärung über der Variable nicht duplizieren.
- Verbindliche Secret-Liste und Format-Konventionen: `projects/env-details.md` (URL-Formate: trailing slash, Trennzeichen, Schemata).

## Backup-System-Design (v1.0.0)

- **Auto-Discovery (v1.0.0)**: Der Dispatcher liest laufende Container (`docker ps`), leitet Bind-Mounts (Datei-Backup) und DB-Typ/Credentials aus Container-ENV ab (`POSTGRES_*`/`MYSQL_*`/`MARIADB_*`). Statische `services.d/`-Deklarationen sind ENTFERNT. Rotation rsnapshot-artig (`v.0..v.N`), kein Timestamp im Pfad.
- Policies nur fuer Ausnahmen: `tools/backup/policy.conf` (globale Defaults: IGNORE_PATH_PREFIXES=/mnt,/tmp,/var/tmp; DEFAULT_FILE_EXCLUDES fuer Logs/Caches) + `tools/backup/policies.d/<project|container>.env` (Container-Policy gewinnt): EXTRA_FILE_PATHS/EXCLUDES, STOP_SELF, KEEP_FILES, DB_DUMP_ALL, DB_TYPE=sqlite|forgejo, SQLITE_FILES, SVC_IGNORE.
- **Geloesste Baustellen (v1.0.0)**: PARTIAL-Zaehler in Summary, rsync-Exit-Code + Output im Log, vaultwarden-SQLite-Bind-Mount-Aufloesung, Ghost-Root-Dump (Root-Credentials aus Container-ENV), `--list`/`--discover` ohne STACKS_DIR-Zwang.

## Stil & Kommunikation

- Deutsch als Arbeitssprache, prägnant, Versions-/Formatkonventionen dokumentieren statt implizit voraussetzen.
- Logs: ISO-artige Timestamps einheitlich, kein unprefixter Tool-Output, Teil-Backups nicht als vollwertiges OK verkaufen, Summary-Zeile mit Zahlen am Laufende.
- Bei Unsicherheit über Secret-Status: konservativ maskieren und im PR dokumentieren, Owner entscheidet.
- Skalpell statt Rasenmäher: keine funktionalen Nebenänderungen bei Format/Struktur-Harmonisierung (Schritt-5-Prinzip der env-Migration).
