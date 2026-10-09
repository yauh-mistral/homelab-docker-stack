#!/usr/bin/env bash
# docker-maintenance.sh — Docker-Host-Pflege: prune von Images, gestoppten
# Containern, ungenutzten Netzwerken und (bewusst) ungenutzten Volumes.
#
# Volumes sind NICHT rebuildbar: Alle Container, die gerade stoppen
# (auch nur kurz, z.B. durch docker compose restart), "verlieren" ihre
# Volumes an den Prune, bis sie wieder laufen. Deshalb laeuft dieses
# Skript NIE parallel zu Backups, Restores oder Compose-Neustarts —
# default Cron: sonntags 04:30, klar nach dem Backup-Fenster (02:30).
#
# Usage:
#   sudo tools/maintenance/docker-maintenance.sh [--dry-run] [--no-volumes]
#
#   --dry-run    nur anzeigen, was geloescht wuerde (docker-prune -f mit --dry-run nicht verfuegbar,
#                deshalb werden die Prunes ohne -f geplant ausgegeben — nichts wird geloescht)
#   --no-volumes  Volumes NICHT prunen (nur Images/Container/Netzwerke)

set -euo pipefail

DRY_RUN=false
PRUNE_VOLUMES=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --no-volumes) PRUNE_VOLUMES=false ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    log "FEHLER: Docker-Daemon nicht erreichbar — abgebrochen (nichts geloescht)."
    exit 1
  fi
}

# Läuft gerade ein Backup oder Restore? Dann niemals prunen —
# gestoppte Backup-Ziel-Container (Stop-Fenster!) wären sonst Verlustkandidaten.
check_no_backup_running() {
  if pgrep -f "backup.sh|restore.sh|test-restore.sh" >/dev/null 2>&1; then
    log "FEHLER: Backup-/Restore-Prozess läuft — prune abgebrochen (Stop-Fenster-Container wären betroffen)."
    exit 1
  fi
}

run_prune() {
  local desc="$1"; shift
  if $DRY_RUN; then
    log "[DRY] $desc — würde ausgeführt: $*"
  else
    log "$desc ..."
    if ! "$@" 2>&1 | sed "s/^/[$(date '+%Y-%m-%d %H:%M:%S')] [EXT] /"; then
      log "WARNUNG: $desc meldete Fehler — siehe Output oben."
    fi
  fi
}

require_docker
check_no_backup_running

log "Docker-Maintenance start (dry-run=$DRY_RUN, volumes-prune=$PRUNE_VOLUMES)"

run_prune "Ungenutzte Images prunen"          docker image prune -f
run_prune "Gestoppte Container prunen"        docker container prune -f
run_prune "Ungenutzte Netzwerke prunen"       docker network prune -f

if $PRUNE_VOLUMES; then
  run_prune "Ungenutzte Volumes prunen (nicht rebuildbar — bewusster Default, siehe Kopf)" docker volume prune -f
else
  log "Volumes werden nicht geprunt (--no-volumes)."
fi

log "Docker-Maintenance fertig."
