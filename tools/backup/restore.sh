#!/usr/bin/env bash
# restore.sh — restore a service from the NAS backup (/mnt/systems).
# Uses the same auto-discovery + policies as the dispatcher (v1.x).
# <service> is the container name (docker ps).
#
# Usage:
#   restore.sh <service> [--version v.N] [--dry-run] [--db-only] [--files-only]
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/db.sh
source "$SCRIPT_DIR/lib/db.sh"
# shellcheck source=lib/discovery.sh
source "$SCRIPT_DIR/lib/discovery.sh"

RESTORE_DATE=""
DB_ONLY=false; FILES_ONLY=false

if [[ $# -lt 1 ]]; then
  sed -n '2,8p' "$0" >&2
  exit 2
fi
SVC_ARG="${1:?service name missing}"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     shift; RESTORE_DATE="${1:?--version requires v.N (e.g. v.2)}" ;;
    --date)        shift; RESTORE_DATE="${1:?--date requires v.N}" ;;
    --dry-run)     DRY_RUN=true ;;
    --db-only)     DB_ONLY=true ;;
    --files-only)  FILES_ONLY=true ;;
    -h|--help)     sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Load /etc/backup.conf first (source/target: STACKS_DIR, BACKUP_ROOT, POLICY_DIR, ...)
if [[ -f /etc/backup.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/backup.conf
fi

# shellcheck source=../policy.conf
source "$SCRIPT_DIR/policy.conf"
POLICY_DIR="${POLICY_DIR:-$SCRIPT_DIR/policies.d}"
[[ -d "$POLICY_DIR" ]] || { echo "policies.d not found" >&2; exit 2; }
container_exists "$SVC_ARG" || { echo "No container '$SVC_ARG' on this host (docker ps)" >&2; exit 2; }
load_service_env "$SVC_ARG"

log_init
_acquire_lock
log_info "Version ($(version_string))"
log_info "Restore: $SVC_NAME (date=${RESTORE_DATE:-latest}, dry-run=$DRY_RUN)"

# ---------------------------------------------------------------------
# Find the latest backup directory
# ----------------------------------------------------------------------
latest_dir() {
  local base="$1"
  [[ -d "$base" ]] || return 1
  local latest=""
  local d
  while IFS= read -r d; do
    [[ -z "$latest" || "$d" > "$latest" ]] && latest="$d"
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  [[ -n "$latest" ]] || return 1
  echo "$latest"
}

resolve_run_dir() {
  local base="$1"
  if [[ -n "$RESTORE_DATE" ]]; then
    if [[ -d "$base/$RESTORE_DATE" ]]; then
      echo "$base/$RESTORE_DATE"
    else
      log_fail "Backup state $RESTORE_DATE not found in $base"
      return 1
    fi
  else
    # Default: v.0 (always the latest state, rotation-proof)
    if [[ -d "$base/v.0" ]]; then
      echo "$base/v.0"
    else
      latest_dir "$base" || { log_fail "No backups found in $base"; return 1; }
    fi
  fi
}

rc=0

# ---------------------------------------------------------------------
# 1) DB restore
# ----------------------------------------------------------------------
restore_db() {
  local run_dir=""
  if ! run_dir="$(resolve_run_dir "$BACKUP_ROOT/$SVC_NAME/db")"; then
    log_fail "$SVC_NAME: no DB backup state in $BACKUP_ROOT/$SVC_NAME/db (date=${RESTORE_DATE:-latest})"
    ((rc+=1)); return
  fi
  log_info "$SVC_NAME: DB restore from $run_dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: would replay the DB dump from $run_dir (type: ${DB_TYPE:-unknown})"
    return
  fi
  case "${DB_TYPE:-}" in
    postgres)
      local dump="$run_dir/${SVC_NAME}.sql.gz"
      [[ -f "$dump" ]] || { log_fail "$SVC_NAME: dump missing: $dump"; ((rc+=1)); return; }
      container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB container is not running"; ((rc+=1)); return; }
      if gunzip -c "$dump" | docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" \
          --single-transaction --set ON_ERROR_STOP=on >>"$LOG_FILE" 2>&1; then
        log_ok "$SVC_NAME: psql restore complete"
      else
        log_fail "$SVC_NAME: psql restore failed"; ((rc+=1))
      fi
      ;;
    mysql|mariadb)
      local dump="$run_dir/${SVC_NAME}.sql.gz"
      [[ -f "$dump" ]] || { log_fail "$SVC_NAME: dump missing: $dump"; ((rc+=1)); return; }
      container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB container is not running"; ((rc+=1)); return; }
      if gunzip -c "$dump" | docker exec -i -e MYSQL_PWD="${DB_PASSWORD:-}" "$DB_CONTAINER" \
          mysql -u "$DB_USER" "$DB_NAME" >>"$LOG_FILE" 2>&1; then
        log_ok "$SVC_NAME: mysql restore complete"
      else
        log_fail "$SVC_NAME: mysql restore failed"; ((rc+=1))
      fi
      ;;
    sqlite)
      local entry host_path container_path dump
      for entry in "${SQLITE_FILES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        host_path="${entry%%:*}"
        container_path="${entry##*:}"
        dump="$run_dir/$(basename "$host_path").sqlite3"
        [[ -f "$dump" ]] || { log_fail "$SVC_NAME: SQLite dump missing: $dump"; ((rc+=1)); continue; }
        # Vaultwarden procedure: stop the container, delete WAL/SHM, replay the file
        if container_running "$DB_CONTAINER"; then
          docker stop "$DB_CONTAINER" >/dev/null 2>&1 || { log_fail "$SVC_NAME: $DB_CONTAINER could not be stopped"; ((rc+=1)); continue; }
        fi
        rm -f "${host_path}-wal" "${host_path}-shm"
        if cp "$dump" "$host_path"; then
          log_ok "$SVC_NAME: SQLite DB replaced: $host_path"
        else
          log_fail "$SVC_NAME: SQLite restore failed"; ((rc+=1))
        fi
        docker start "$DB_CONTAINER" >/dev/null 2>&1 || log_warn "$SVC_NAME: $DB_CONTAINER could not be started"
      done
      ;;
    forgejo)
      # forgejo dump contains DB+config; the restore is a manual multi-step
      # process (docs: docs/RESTORE.md). We only provide the archive.
      log_info "$SVC_NAME: Forgejo dump available in $run_dir — restore per docs/RESTORE.md (DB dump category)"
      ;;
    surreal)
      log_info "$SVC_NAME: Surreal export available in $run_dir — restore via 'surreal import' (docs/RESTORE.md)"
      ;;
    *)
      log_fail "$SVC_NAME: restore not implemented for DB_TYPE '${DB_TYPE:-empty}'"; ((rc+=1))
      ;;
  esac
}

# ---------------------------------------------------------------------
# 2) File restore (rsync back)
# ----------------------------------------------------------------------
restore_files() {
  local run_dir=""
  if ! run_dir="$(resolve_run_dir "$BACKUP_ROOT/$SVC_NAME/files")"; then
    log_fail "$SVC_NAME: no file backup state in $BACKUP_ROOT/$SVC_NAME/files (date=${RESTORE_DATE:-latest})"
    ((rc+=1)); return
  fi
  log_info "$SVC_NAME: file restore from $run_dir"
  # Stop window as with the backup (consistent copy-back)
  if [[ ${#STOP_CONTAINERS[@]} -gt 0 ]]; then
    if ! stop_containers "${STOP_CONTAINERS[@]}"; then
      log_fail "$SVC_NAME: stop window failed — file restore aborted"
      ((rc+=1)); return
    fi
  fi
  local p src dest
  for p in "${FILE_PATHS[@]:-}"; do
    [[ -z "$p" ]] && continue
    src="$run_dir/$(basename "$p")"
    if [[ ! -e "$src" ]]; then
      log_warn "$SVC_NAME: backup source missing: $src (skipping)"
      continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: would rsync: $src/ -> $p/"
    else
      mkdir -p "$p"
      if rsync -a --numeric-ids "$src/" "$p/"; then
        log_ok "$SVC_NAME: rsync $src -> $p"
      else
        log_fail "$SVC_NAME: rsync failed: $src -> $p"; ((rc+=1))
      fi
    fi
  done
  start_containers
}

# ---------------------------------------------------------------------
case "$SVC_CATEGORY" in
  ignore)
    log_info "$SVC_NAME is declared 'ignore' — nothing to restore"
    ;;
  db_only)
    [[ "$FILES_ONLY" == "true" ]] || restore_db
    ;;
  files_only)
    [[ "$DB_ONLY" == "true" ]] || restore_files
    ;;
  db_and_files)
    if [[ "$FILES_ONLY" != "true" ]]; then restore_db; fi
    if [[ "$DB_ONLY" != "true" ]]; then restore_files; fi
    ;;
  config_only)
    [[ "$DB_ONLY" == "true" ]] || restore_files
    ;;
  *)
    log_fail "$SVC_NAME: unknown category '$SVC_CATEGORY'"; ((rc+=1))
    ;;
esac

if [[ $rc -eq 0 ]]; then
  log_ok "$SVC_NAME: restore complete — verify the service (docs/RESTORE.md checklist)!"
else
  log_fail "$SVC_NAME: restore finished with errors (rc=$rc)"
fi
exit $rc
