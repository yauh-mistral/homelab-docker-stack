# arcane-docker-stack

Docker-Compose-Stacks und Backup-System für Host **`ovi`** (Ubuntu, Docker).
Kernstück ist **Arcane** — die Verwaltungsoberfläche, unter der alle Stacks als Projekte laufen. Dieses Repo beschreibt, pflegt und sichert die gesamte Docker-Landschaft des Hosts.

> Arbeitssprache ist Deutsch. In-depth-Anleitungen (Deploy, Konfiguration, Services hinzufügen/entfernen, Backup, Restore) liegen in [`docs/`](docs/) — dieses README gibt den Überblick über Komponenten und Möglichkeiten.

## Komponenten

| Komponente | Ort | Zweck |
|---|---|---|
| **Arcane** (Verwaltung) | `/opt/docker/compose/compose.yml` (Host) | Docker-Verwaltungsoberfläche; verwaltet alle Compose-Stacks als Projekte. **Selbst-Bootstrap**: Arcane kann sich nicht selbst verwalten — es läuft aus einem host-seitigen Compose-File außerhalb des Repos (`/opt/docker/compose/compose.yml`, Projektname `base`). Daten als Bind-Mount unter `/opt/docker/arcane/` |
| **Compose-Stacks** | `projects/<stack>/` | Deklaration aller Services: `compose.yaml` + `.env.example`. Die echten `.env`-Dateien leben **nur auf dem Host** (`/opt/docker/arcane/projects/<stack>/.env`) — nie im Repo |
| **Backup-System** | `backup/` | Auto-Discovery-Backup: sichert alle laufenden Container (Dateien + DB-Dumps) auf das NAS. Installiert nach `/opt/docker/backup` via `install.sh` |
| **Dokumentation** | `docs/` | In-depth-Referenz: Deployment, Backup-Strategie, Restore, Inventar, offene Fragen |

## Die Stacks (projects/)

| Stack | Services (Auswahl) | Zweck |
|---|---|---|
| `arcane` | arcane | Verwaltung aller Projekte (Kernstück). **Hinweis:** Arcane selbst läuft nicht aus `projects/arcane`, sondern aus dem host-seitigen Compose-File `/opt/docker/compose/compose.yml` (Projekt `base`) — es kann sich nicht selbst hosten („Bootstrap-Problem"). Der Container ist identisch: `ghcr.io/getarcaneapp/arcane:latest`, Mounts auf `/opt/docker/arcane/data` und `/opt/docker/arcane/projects` |
| `arr-stack` | sonarr, radarr, lidarr, bazarr, prowlarr, sabnzbd, overseerr | PVR/Media-Automation |
| `media` | plex, tautulli, audiobookshelf, metube, calibre-web, codex, tdarr | Medienserver & -verarbeitung |
| `smarthome` | homeassistant, music-assistant, mosquitto, matter-server | Hausautomatisierung |
| `monitoring` | dashdot, uptime-kuma, grafana, shynet | Überwachung & Analytics |
| `local-ai` | litellm, crawl4ai, valkey, searxng | Selbstgehostete KI/LLM-Infrastruktur |
| `content` | homepage, 5etools | Statische Inhalte |
| `infra` | omada-controller, crowdsec | Netzwerk & Security |
| `web-proxy` | nginx, acme | Reverse-Proxy + TLS-Zertifikate |
| `forgejo` (+ Runner) | forgejo, forgejo-runner | Git-Hosting & CI |
| `ghost` | ghost, ghost-mysql, ghost-activitypub | Blog |
| `immich` | immich, immich_postgres | Foto-Management |
| `vaultwarden` | vaultwarden (SQLite) | Passwort-Manager |
| `castopod` | castopod_app, castopod_mariadb, castopod_redis | Podcast |
| `wanderer` | wanderer (app, db, search, web) | Routenplanung (Hiking) |
| `analytics` | shynet (analytics-db) | Web-Analytics |

**Konvention:** Jeder Stack hat ein `compose.yaml` mit Bind-Mounts unter `/opt/docker/<service>/`. Docker-Volumes werden **nie** für zu sichernde Daten genutzt; NAS-Mounts (`/mnt/...`) sind nie Backup-Quelle.

## Zusammenhänge (Diagramm)

```mermaid
flowchart LR
    subgraph host["Host ovi (/opt/docker)"]
        B["/opt/docker/compose/compose.yml<br/>(Projekt 'base', Host-Compose)"] -->|"startet (Bootstrap — Arcane<br/>kann sich nicht selbst hosten)"| A
        A["Arcane<br/>(Verwaltung)"] -->|"verwaltet als Projekte"| S["Compose-Stacks<br/>(projects/*)"]
        S --- B[("/opt/docker/&lt;service&gt;/<br/>Bind-Mount-Daten")]
        S -.->|".env (nur Host)| E["/opt/docker/arcane/projects/&lt;stack&gt;/.env"]
    end

    subgraph backupsys["Backup-System (backup/)"]
        D["backup.sh Dispatcher<br/>(Auto-Discovery)"]
        P["policies.d/*.env<br/>(Ausnahmen)"]
        T["test-restore.sh"]
    end

    D -->|"liest Container, Mounts,<br/>ENV-Credentials"| host
    P --> D
    D -->|"rsync + DB-Dumps<br/>Rotation v.0..v.13"| NAS[("NAS<br/>/mnt/systems/ovi/backups")]
    D -->|"Dump-Qualitätstest<br/>(Wegwerf-Postgres)"| T

    C["Cron (nächtlich)"] -->|"flock-gesichert"| D
```

Das Diagramm zeigt das Kernprinzip: **Die Wahrheit der Services lebt in Docker** (Container, Mounts, ENV) — nicht im Repo. Der Backup-Dispatcher entdeckt alles laufende selbst; das Repo liefert nur Struktur, Compose-Deklarationen und Ausnahme-Policies.

## Das Backup-System im Überblick

- **Auto-Discovery**: Findest du einen Mount, sicher ihn. Läuft eine DB, dump sie. Keine statischen Service-Deklarationen mehr.
- **Rotation**: rsnapshot-artig `v.0..v.13` mit Hardlink-Dedupe — Restore-Pfade bleiben stabil.
- **Policies für Ausnahmen**: `backup/policy.conf` (globale Defaults, Allowlist `/opt/docker`) + `policies.d/` (z.B. `SVC_IGNORE=true` für Caches, `EXTRA_FILE_EXCLUDES` für rebuildbare Daten).
- **Restore-Test**: `test-restore.sh --all` spielt DB-Dumps in einen Wegwerf-Postgres — das Live-System wird nie berührt.
- **Versionierung**: `v1.0.0+#<PR-Nummer>` — die Build-Nummer wird von der GitHub Action bei jedem Merge automatisch nachgetragen.

Details: [`docs/BACKUP-STRATEGIE.md`](docs/BACKUP-STRATEGIE.md) · [`docs/RESTORE.md`](docs/RESTORE.md) · [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)

## Schnellstart

```bash
# Backup-System installieren (aus dem Repo-Klon!)
cd /opt/docker/arcane && sudo git pull
sudo backup/install.sh --home /opt/docker/backup \
     --stacks-dir /opt/docker/arcane/projects \
     --backup-root /mnt/systems/ovi/backups

# Testen
sudo /opt/docker/backup/backup.sh --dry-run       # nichts schreiben, nur planen
sudo /opt/docker/backup/backup.sh                 # echter Lauf
sudo /opt/docker/backup/test-restore.sh --all     # Restore-Fähigkeit prüfen
```

### Nächtclicher Cron (auf ovi, root-Crontab)

```cron
30 2 * * * /usr/bin/flock -n /tmp/backup-dispatcher.lock /opt/docker/backup/backup.sh >> /var/log/backup-dispatcher.log 2>&1
```

- Läuft täglich um 02:30 Uhr
- `flock -n` verhindert Überlappungen (das Skript selbst lockt zusätzlich — doppelt abgesichert)
- Log landet in `/var/log/backup-dispatcher.log` (das Skript schreibt zusätzlich strukturiert nach `$BACKUP_ROOT/_meta/runs/`)

Einrichten mit `sudo crontab -e` und Zeile einfügen.

## Verzeichnisstruktur

```
arcane-docker-stack/
├── AGENTS.md              # Leitlinie für die Zusammenarbeit (KI + Mensch)
├── projects/              # Compose-Stacks (compose.yaml + .env.example je Stack)
│   └── env-audit.md       # Secret-Audit + env-Konventionen
├── backup/                # Backup-System (Dispatcher, libs, policies)
│   ├── backup.sh          # Dispatcher mit Auto-Discovery
│   ├── restore.sh         # Restore pro Service
│   ├── test-restore.sh    # Dump-Restore-Test (Wegwerf-Postgres)
│   ├── install.sh         # Installation nach /opt/docker/backup
│   ├── policy.conf        # Globale Backup-Defaults
│   ├── policies.d/        # Ausnahme-Policies (Projekt/Container)
│   └── lib/               # common.sh, db.sh, discovery.sh
├── docs/                  # In-depth-Dokumentation
│   ├── DEPLOYMENT.md      # Installation & Inbetriebnahme
│   ├── BACKUP-STRATEGIE.md# Strategie & Policy-Referenz
│   ├── RESTORE.md         # Restore-Anleitung
│   ├── INVENTAR.md        # Service-Inventar (Backup-Kategorien)
│   └── QUESTIONS.md       # Offene Punkte & Annahmen
└── make-env-examples.sh   # Hilfsskript: .env.example aus .env erzeugen
```

## Doku-Verteilung (weniger Redundanz)

| Thema | Hier (README) | In `docs/` |
|---|---|---|
| Komponenten, Stacks, Zusammenhänge | Überblick + Diagramm | — |
| Deployment (Installation, erste Schritte) | Schnellstart-Block | `DEPLOYMENT.md` (vollständig) |
| Backup (Strategie, Policies, Rotation) | Kurzfassung | `BACKUP-STRATEGIE.md` (Referenz) |
| Restore | Kurzfassung | `RESTORE.md` (vollständig) |
| Service-Inventar | Stack-Tabelle (Namen) | `INVENTAR.md` (Kategorien, Größen, Pfade) |
| Cron-Einrichtung | Beispiel-Zeile | `DEPLOYMENT.md` |

Regel: **README = was gibt es und wie hängt es zusammen; docs/ = wie mache ich es Schritt für Schritt.** Überschneidungen bewusst als Kurzfassung mit Link, nie als Kopie.

## Zusammenarbeit

Siehe [`AGENTS.md`](AGENTS.md) — Ziel/Umgebung, Git/PR-Workflow, Versionierung, .env-Konventionen, Backup-Design und Stil sind dort verbindlich dokumentiert.
