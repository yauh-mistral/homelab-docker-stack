#!/usr/bin/env bash
# docker-maintenance.sh — Docker host housekeeping: prune images, stopped
# containers, unused networks, and (deliberately) unused volumes.
#
# Volumes are NOT rebuildable: every container that happens to stop
# (even briefly, e.g. via docker compose restart) "loses" its volumes
# to the prune until it runs again. That is why this script NEVER runs
# in parallel with backups, restores, or compose restarts —
# default cron: Sunday 04:30, safely after the backup window (02:30).
#
# Usage:
#   sudo tools/maintenance/docker-maintenance.sh [--dry-run] [--no-volumes]
#
#   --dry-run     show only what would be deleted (docker prune -f is not available with --dry-run,
#                 so the prunes are printed as planned without -f — nothing is deleted)
#   --no-volumes  do NOT prune volumes (only images/containers/networks)

set -euo pipefail

DRY_RUN=false
PRUNE_VOLUMES=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --no-volumes) PRUNE_VOLUMES=false ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    log "ERROR: Docker daemon not reachable — aborted (nothing deleted)."
    exit 1
  fi
}

# Is a backup or restore running right now? Then never prune —
# stopped backup target containers (stop window!) would otherwise be loss candidates.
check_no_backup_running() {
  if pgrep -f "backup.sh|restore.sh|test-restore.sh" >/dev/null 2>&1; then
    log "ERROR: backup/restore process running — prune aborted (stop window containers would be affected)."
    exit 1
  fi
}

run_prune() {
  local desc="$1"; shift
  if $DRY_RUN; then
    log "[DRY] $desc — would run: $*"
  else
    log "$desc ..."
    if ! "$@" 2>&1 | sed "s/^/[$(date '+%Y-%m-%d %H:%M:%S')] [EXT] /"; then
      log "WARNING: $desc reported errors — see output above."
    fi
  fi
}

require_docker
check_no_backup_running

log "Docker maintenance start (dry-run=$DRY_RUN, volumes-prune=$PRUNE_VOLUMES)"

run_prune "Prune unused images"          docker image prune -f
run_prune "Prune stopped containers"        docker container prune -f
run_prune "Prune unused networks"       docker network prune -f

if $PRUNE_VOLUMES; then
  run_prune "Prune unused volumes (not rebuildable — deliberate default, see header)" docker volume prune -f
else
  log "Volumes are not pruned (--no-volumes)."
fi

log "Docker maintenance done."
