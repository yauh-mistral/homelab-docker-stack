# arcane-docker-stack

Docker-Compose-Stacks und Backup-System für Host **`ovi`** (Ubuntu, Docker).
Kernstück ist **Arcane** — die Verwaltungsoberfläche, unter der alle Stacks als Projekte laufen. Dieses Repo beschreibt, pflegt und sichert die gesamte Docker-Landschaft des Hosts.

> Arbeitssprache ist Deutsch. In-depth-Anleitungen (Deploy, Konfiguration, Services hinzufügen/entfernen, Backup, Restore) liegen in [`docs/`](docs/) — dieses README gibt den Überblick über Komponenten und Möglichkeiten.

## Komponenten

| Komponente | Ort | Zweck |
|---|---|---|
| **Arcane** (Verwaltung) | `/opt/docker/tools/arcane/compose.yml` (Host) | Docker-Verwaltungsoberfläche; verwaltet alle Compose-Stacks als Projekte. **Selbst-Bootstrap**: Arcane kann sich nicht selbst verwalten — es läuft aus einem host-seitigen Compose-File (Repo: `tools/arcane/compose.yml`, Host-Installation `/opt/docker/tools/arcane/compose.yml`, Projektname `base`). Daten als Bind-Mount unter `/opt/docker/arcane/` |
| **Compose-Stacks** | `projects/<stack>/` | Deklaration aller Services: `compose.yaml` + `.env.example`. Die echten `.env`-Dateien leben **nur auf dem Host** (`/opt/docker/arcane/projects/<stack>/.env`) — nie im Repo |
| **Backup-System** | `tools/backup/` | Auto-Discovery-Backup: sichert alle laufenden Container (Dateien + DB-Dumps) auf das NAS. Installiert nach `/opt/docker/tools/backup` via `install.sh` |
| **Docker-Maintenance** | `tools/maintenance/` | Host-Pflege: prune von ungenutzten Images, gestoppten Containern, Netzwerken und Volumes (bewusst, nicht rebuildbar — nie parallel zu Backups). Installiert nach `/opt/docker/tools/maintenance` |
| **Dokumentation** | `docs/` | In-depth-Referenz: Deployment, Backup-Strategie, Restore, Inventar, Todos & Entscheidungen |

## Die Stacks (projects/)

| Stack | Services (Auswahl) | Zweck |
|---|---|---|
| `arcane` | arcane | Verwaltung aller Projekte (Kernstück). **Hinweis:** Arcane selbst läuft nicht aus `projects/arcane`, sondern aus dem host-seitigen Compose-File `tools/arcane/compose.yml` (Host: `/opt/docker/tools/arcane/compose.yml`, Projekt `base`) — es kann sich nicht selbst hosten („Bootstrap-Problem"). Der Container ist identisch: `ghcr.io/getarcaneapp/arcane:latest`, Mounts auf `/opt/docker/arcane/data` und `/opt/docker/arcane/projects` |
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

    subgraph ovi["Docker-Host ovi"]
        B["tools/arcane/compose.yml<br/>(Projekt 'base')"] -->|"startet (Bootstrap)"| A
        A["Arcane (Verwaltung)"] -->|"verwaltet als Projekte"| S["Compose-Stacks<br/>(projects/*)"]
        S --- CFG[("Config-Daten (Host)<br/>/opt/docker/&lt;service&gt;/<br/>Bind-Mounts — gesichert")]
        S -.->|".env (nur Host)"| E["stack-.env auf dem Host"]
    end

    subgraph nas["NAS-Host (NFS)"]
        MEDIA[("Medien-Daten (NFS)<br/>/mnt/immich, /mnt/media, ...<br/>NAS-eigenes Backup — nicht gesichert")]
        BKPTGT[("Backup-Ziel<br/>/mnt/systems/ovi/backups")]
    end

    subgraph backupsys["Backup-System (tools/backup/)"]
        D["backup.sh Dispatcher<br/>(Auto-Discovery)"]
        P["policies.d/*.env<br/>(Ausnahmen)"]
        T["test-restore.sh"]
    end

    S ---|"NFS-Mounts (Medien)"| MEDIA
    D -->|"liest Container, Mounts,<br/>ENV-Credentials"| ovi
    P --> D
    D -->|"rsync + DB-Dumps<br/>Rotation v.0..v.13"| BKPTGT
    D -->|"Dump-Test"| T
    C["Cron (nächtlich 02:30)"] -->|"flock-gesichert"| D
    M["Cron (So 04:30)"] -.->|"Maintenance: prune (inkl. Volumes)"| ovi
```

Das Diagramm zeigt die Daten-Trennung: **Config-Daten** leben als Bind-Mounts auf dem Docker-Host (`/opt/docker/...` — vom Backup-System gesichert), **Medien-Daten** auf dem NAS (NFS-Mounts — vom NAS-eigenen Backup abgedeckt), und das **Backup-Ziel** ist ein eigener NAS-Bereich. Kernprinzip: **Die Wahrheit der Services lebt in Docker** (Container, Mounts, ENV) — nicht im Repo. Der Backup-Dispatcher entdeckt alles laufende selbst; das Repo liefert nur Struktur, Compose-Deklarationen und Ausnahme-Policies.

## Das Backup-System im Überblick

- **Auto-Discovery**: Findest du einen Mount, sicher ihn. Läuft eine DB, dump sie. Keine statischen Service-Deklarationen mehr.
- **Rotation**: rsnapshot-artig `v.0..v.13` mit Hardlink-Dedupe — Restore-Pfade bleiben stabil.
- **Policies für Ausnahmen**: `tools/backup/policy.conf` (globale Defaults, Allowlist `/opt/docker`) + `policies.d/` (z.B. `SVC_IGNORE=true` für Caches, `EXTRA_FILE_EXCLUDES` für rebuildbare Daten).
- **Restore-Test**: `test-restore.sh --all` spielt DB-Dumps in einen Wegwerf-Postgres — das Live-System wird nie berührt.
- **Versionierung**: `v1.0.0+#<PR-Nummer>` — die Build-Nummer wird von der GitHub Action bei jedem Merge automatisch nachgetragen.

Details: [`docs/BACKUP-STRATEGIE.md`](docs/BACKUP-STRATEGIE.md) · [`docs/RESTORE.md`](docs/RESTORE.md) · [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)

## Schnellstart

```bash
# Backup-System installieren (aus dem Repo-Klon!)
cd /opt/docker/arcane && sudo git pull
sudo tools/backup/install.sh --home /opt/docker/tools/backup \
     --stacks-dir /opt/docker/arcane/projects \
     --backup-root /mnt/systems/ovi/backups

# Testen
sudo /opt/docker/tools/backup/backup.sh --dry-run       # nichts schreiben, nur planen
sudo /opt/docker/tools/backup/backup.sh                 # echter Lauf
sudo /opt/docker/tools/backup/test-restore.sh --all     # Restore-Fähigkeit prüfen
```

### Nächtclicher Cron (auf ovi, root-Crontab)

```cron
30 2 * * * /usr/bin/flock -n /tmp/backup-dispatcher.lock /opt/docker/tools/backup/backup.sh >> /var/log/backup-dispatcher.log 2>&1
```

- Läuft täglich um 02:30 Uhr
- `flock -n` verhindert Überlappungen (das Skript selbst lockt zusätzlich — doppelt abgesichert)
- Log landet in `/var/log/backup-dispatcher.log` (das Skript schreibt zusätzlich strukturiert nach `$BACKUP_ROOT/_meta/runs/`)

Einrichten mit `sudo crontab -e` und Zeile einfügen.

## Verzeichnisstruktur

```
arcane-docker-stack/
├── AGENTS.md              # Leitlinie für die Zusammenarbeit (KI + Mensch)
├── projects/              # Compose-Stacks: <stack>/compose.yaml (+ .env.example je Stack)
│                          #   + env-details.md (Secret-/Format-Konventionen)
├── tools/                 # Host-Tools (Installationspfad: /opt/docker/tools/)
│   ├── backup/            # Backup-System (Dispatcher, libs, policies)
│   │   ├── backup.sh      # Dispatcher mit Auto-Discovery
│   │   ├── restore.sh     # Restore pro Service
│   │   ├── test-restore.sh # Dump-Restore-Test (Wegwerf-Postgres)
│   │   ├── install.sh     # Installation nach /opt/docker/tools/backup
│   │   ├── policy.conf    # Globale Backup-Defaults
│   │   ├── policies.d/     # Ausnahme-Policies (Projekt/Container)
│   │   └── lib/            # common.sh, db.sh, discovery.sh
│   ├── arcane/            # Bootstrap-Compose für Arcane selbst (Host: /opt/docker/tools/arcane)
│   └── maintenance/       # docker-maintenance.sh (prune Images/Container/Netzwerke/Volumes)
├── docs/                  # In-depth-Dokumentation
│   ├── DEPLOYMENT.md      # Installation & Inbetriebnahme
│   ├── BACKUP-STRATEGIE.md# Strategie & Policy-Referenz
│   ├── RESTORE.md         # Restore-Anleitung
│   ├── INVENTAR.md        # Service-Inventar (Backup-Kategorien)
│   └── TODOS.md           # Offene Todos & dokumentierte Entscheidungen
```

## Doku-Verteilung (weniger Redundanz)

| Thema | Hier (README) | In `docs/` |
|---|---|---|
| Komponenten, Stacks, Zusammenhänge | Überblick + Diagramm | — |
| Deployment (Installation, erste Schritte) | Schnellstart-Block | [`DEPLOYMENT.md`](docs/DEPLOYMENT.md) (vollständig) |
| Backup (Strategie, Policies, Rotation) | Kurzfassung | [`BACKUP-STRATEGIE.md`](docs/BACKUP-STRATEGIE.md) (Referenz) |
| Restore | Kurzfassung | [`RESTORE.md`](docs/RESTORE.md) (vollständig) |
| Service-Inventar | Stack-Tabelle (Namen) | [`INVENTAR.md`](docs/INVENTAR.md) (Kategorien, Größen, Pfade) |
| Todos & Entscheidungen | — | [`TODOS.md`](docs/TODOS.md) (offene Punkte, compact) |
| Cron-Einrichtung | Beispiel-Zeile | [`DEPLOYMENT.md`](docs/DEPLOYMENT.md) |

Regel: **README = was gibt es und wie hängt es zusammen; docs/ = wie mache ich es Schritt für Schritt.** Überschneidungen bewusst als Kurzfassung mit Link, nie als Kopie.

## Zusammenarbeit

Siehe [`AGENTS.md`](AGENTS.md) — Ziel/Umgebung, Git/PR-Workflow, Versionierung, .env-Konventionen, Backup-Design und Stil sind dort verbindlich dokumentiert.
