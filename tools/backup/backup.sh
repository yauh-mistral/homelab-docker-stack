#!/usr/bin/env bash
# backup.sh — Dispatcher of the modular backup system for the Docker host (v1.x).
# Auto-discovery: running containers are detected, bind mounts backed up,
# DB containers dumped. Policies (policy.conf + policies.d/) only control
# exceptions: excludes, stop windows, SQLite/Forgejo, IGNORES.
#
# Usage:
#   backup.sh [--dry-run] [--only-db] [--only-files] [--service CONTAINER] [--project STACK]
#   backup.sh --list
#   backup.sh --discover            # show inventory only, no backup
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

# ----------------------------------------------------------------------
# Parse options
# ----------------------------------------------------------------------
ONLY_DB=false; ONLY_FILES=false; SERVICE_FILTER=""; PROJECT_FILTER=""; LIST=false; DISCOVER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=true ;;
    --only-db)     ONLY_DB=true ;;
    --only-files)  ONLY_FILES=true ;;
    --service)     shift; SERVICE_FILTER="${1:?--service requires a container name}" ;;
    --project)     shift; PROJECT_FILTER="${1:?--project requires a stack name (compose project)}" ;;
    --list|--discover) LIST=true; DISCOVER=true ;;
    -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Load /etc/backup.conf first (sets source/target: STACKS_DIR, BACKUP_ROOT, ...)
# Order of precedence: CLI flag > /etc/backup.conf > defaults from lib/common.sh
if [[ -f /etc/backup.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/backup.conf
fi

# Load central policy defaults (ALLOW_PATH_PREFIXES, DEFAULT_FILE_EXCLUDES, ...)
# shellcheck source=../policy.conf
source "$SCRIPT_DIR/policy.conf"
POLICY_DIR="${POLICY_DIR:-$SCRIPT_DIR/policies.d}"
[[ -d "$POLICY_DIR" ]] || { echo "policies.d not found: $POLICY_DIR" >&2; exit 2; }

log_init
_acquire_lock
log_info "Version ($(version_string))"
log_info "Dispatcher start: auto-discovery, dry-run=$DRY_RUN, target=$BACKUP_ROOT"
log_info "Policy: ALLOW_PATH_PREFIXES=[${ALLOW_PATH_PREFIXES[*]:-}] DEFAULT_FILE_EXCLUDES=[${DEFAULT_FILE_EXCLUDES[*]:-}]"

if [[ "$DRY_RUN" != "true" ]]; then
  if ! docker_available; then
    log_fail "Aborting: Docker daemon not reachable (docker info failed)"
    exit 1
  fi
  if ! require_mounted_target "$BACKUP_ROOT"; then
    log_fail "Aborting: backup target $BACKUP_ROOT is not available as a NAS mount"
    exit 1
  fi
  mkdir -p "$BACKUP_ROOT/logs" || { log_fail "Aborting: cannot create $BACKUP_ROOT/logs"; exit 1; }
fi

# ----------------------------------------------------------------------
# Discovery: all running containers -> backup units
# ----------------------------------------------------------------------
FAILS=0
OKS=0
SKIPS=0
STAT_DUMPS=0
STAT_FILES=0
STAT_BYTES=0
PARTIALS=0
OPEN_GAPS=()
# Path dedupe: running containers share mounts (e.g. a shared
# downloads directory, ghost content between ghost+activitypub). Each host path is backed up
# only once per run — in the context of the first container reporting it.
declare -A SEEN_PATHS=()
declare -a RUN_CONTAINERS=()

if [[ "$DRY_RUN" != "true" && ! docker_available ]]; then
  log_fail "Aborting: Docker not available"
  exit 1
fi

while IFS= read -r SVC_CTR; do
  [[ -z "$SVC_CTR" ]] && continue
  RUN_CONTAINERS+=("$SVC_CTR")
done < <(discover_containers)

if [[ ${#RUN_CONTAINERS[@]} -eq 0 ]]; then
  log_fail "No running containers found — nothing to do"
  exit 1
fi

log_info "Discovery: ${#RUN_CONTAINERS[@]} running containers found"

# CLI filters
should_process() {
  if [[ -n "$SERVICE_FILTER" && "$SVC_NAME" != "$SERVICE_FILTER" ]]; then return 1; fi
  if [[ -n "$PROJECT_FILTER" && "${SVC_PROJECT:-}" != "$PROJECT_FILTER" ]]; then return 1; fi
  case "$SVC_CATEGORY" in
    ignore) return 1 ;;
    none)   return 1 ;;
    db_only)
      [[ "$ONLY_FILES" == "true" ]] && return 1 ;;
    files_only)
      [[ "$ONLY_DB" == "true" ]] && return 1 ;;
    db_and_files) return 0 ;;
    *) return 1 ;;
  esac
  return 0
}

validate_service() {
  local problems=0 p
  SVC_DB_OK=true
  SVC_FILES_OK=true
  case "$SVC_CATEGORY" in
    db_only|db_and_files)
      if ! container_running "$DB_CONTAINER"; then
        log_warn "$SVC_NAME: DB container '$DB_CONTAINER' is not running"
        OPEN_GAPS+=("DB container not running: $DB_CONTAINER ($SVC_NAME)")
        SVC_DB_OK=false
      fi
      ;;
  esac
  for p in "${FILE_PATHS[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ ! -e "$p" ]]; then
      log_warn "$SVC_NAME: source path does not exist: $p"
      OPEN_GAPS+=("Source path missing: $p ($SVC_NAME)")
      SVC_FILES_OK=false
    fi
  done
  return $problems
}

# ----------------------------------------------------------------------
# Backup phase per container
# ----------------------------------------------------------------------
backup_one_service() {
  local ctr="$1"
  load_service_env "$ctr"
  if [[ "$DISCOVER" == "true" ]]; then
    printf '  %-28s %-14s project=%-14s image=%s\n' "$SVC_NAME" "$SVC_CATEGORY" "${SVC_PROJECT:-?}" "${SVC_IMAGE:-?}"
    return 0
  fi
  if ! should_process; then
    if [[ "$SVC_CATEGORY" == "ignore" ]]; then ((SKIPS+=1)); fi
    return 0
  fi
  validate_service

  local skip_db=false skip_files=false
  case "$SVC_CATEGORY" in
    db_only)        [[ "$SVC_DB_OK" == "false" ]] && skip_db=true ;;
    files_only)     [[ "$SVC_FILES_OK" == "false" ]] && skip_files=true ;;
    db_and_files)
      [[ "$SVC_DB_OK" == "false" ]] && skip_db=true
      [[ "$SVC_FILES_OK" == "false" ]] && skip_files=true
      ;;
  esac
  if [[ "$skip_db" == "true" && "$skip_files" == "true" ]]; then
    ((SKIPS+=1))
    log_info "$SVC_NAME: SKIP — source missing entirely"
    return 0
  fi
  if [[ "$skip_db" == "true" || "$skip_files" == "true" ]]; then
    PARTIALS=$((PARTIALS+1))
  fi

  # Rotate BEFORE writing
  if [[ "$DRY_RUN" != "true" ]]; then
    case "$SVC_CATEGORY" in
      db_only)        rotate_versions "$BACKUP_ROOT/$SVC_NAME/db" ;;
      files_only)     rotate_versions "$BACKUP_ROOT/$SVC_NAME/files" ;;
      db_and_files)
        rotate_versions "$BACKUP_ROOT/$SVC_NAME/db"
        rotate_versions "$BACKUP_ROOT/$SVC_NAME/files"
        ;;
    esac
  fi

  local rc=0
  # 1) DB-Dump
  case "$SVC_CATEGORY" in
    db_only|db_and_files)
      if [[ "$skip_db" == "true" ]]; then
        log_warn "$SVC_NAME: DB backup skipped — partial backup"
      else
        if dump_database "$(svc_db_dir "$SVC_NAME")"; then
          ((STAT_DUMPS+=1))
        else
          ((rc+=1))
        fi
      fi
      ;;
  esac

  # 2) Files (with optional stop window)
  case "$SVC_CATEGORY" in
    files_only|db_and_files)
      if [[ "$skip_files" == "true" ]]; then
        log_warn "$SVC_NAME: file backup skipped — partial backup"
      else
        DEDUPED_ALL=false
        dedupe_paths
        if [[ ${#DEDUPED_PATHS[@]} -eq 0 ]]; then
          DEDUPED_ALL=true
          log_info "$SVC_NAME: all file paths already backed up in this run — file backup skipped"
        else
          local do_stop=false
        if [[ ${#STOP_CONTAINERS[@]} -gt 0 ]]; then do_stop=true; fi
        if [[ "$do_stop" == "true" ]]; then
          if ! stop_containers "${STOP_CONTAINERS[@]}"; then
            log_fail "$SVC_NAME: could not open stop window — skipping file backup"
            ((rc+=1))
          else
            if ! backup_files_for_service; then ((rc+=1)); fi
            start_containers
          fi
        else
          if ! backup_files_for_service; then ((rc+=1)); fi
        fi
        fi
      fi
      ;;
  esac

  if [[ $rc -eq 0 ]]; then
    ((OKS+=1))
  else
    ((FAILS+=1))
  fi
  consistency_check_service
}

consistency_check_service() {
  local problems=0 dest dump
  [[ "$DRY_RUN" == "true" ]] && return 0
  case "$SVC_CATEGORY" in
    db_only|db_and_files)
      if [[ "$skip_db" != "true" ]]; then
        dest="$BACKUP_ROOT/$SVC_NAME/db/v.0"
        if [[ ! -d "$dest" ]]; then
          log_warn "Consistency: $SVC_NAME: no DB state in $dest"; problems=1
        else
          dump="$(find "$dest" -maxdepth 1 -type f -size +0c | head -1)"
          if [[ -z "$dump" ]]; then
            log_warn "Consistency: $SVC_NAME: DB state empty/0-byte in $dest"; problems=1
          fi
        fi
      fi
      ;;
  esac
  case "$SVC_CATEGORY" in
    files_only|db_and_files)
      if [[ "$skip_files" != "true" && "${DEDUPED_ALL:-false}" != "true" ]]; then
        dest="$BACKUP_ROOT/$SVC_NAME/files/v.0"
        if [[ ! -d "$dest" ]]; then
          log_warn "Consistency: $SVC_NAME: no file state in $dest"; problems=1
        elif [[ -z "$(find "$dest" -type f -print -quit)" ]]; then
          log_warn "Consistency: $SVC_NAME: file state empty in $dest"; problems=1
        fi
      fi
      ;;
  esac
  return $problems
}

dedupe_paths() {
  DEDUPED_PATHS=()
  local p
  for p in "${FILE_PATHS[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ -n "${SEEN_PATHS[$p]:-}" ]]; then
      log_info "$SVC_NAME: path already backed up in this run (via ${SEEN_PATHS[$p]}), skipping: $p"
      continue
    fi
    DEDUPED_PATHS+=("$p")
    SEEN_PATHS[$p]="$SVC_NAME"
  done
}

backup_files_for_service() {
  local rc=0 p dest
  dest="$(svc_files_dir "$SVC_NAME")"
  [[ "$DRY_RUN" != "true" ]] && mkdir -p "$dest"
  for p in "${DEDUPED_PATHS[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ ! -e "$p" && "$DRY_RUN" != "true" ]]; then
      log_warn "$SVC_NAME: source missing, skipping: $p"; ((rc+=1)); continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: would rsync: $p -> $dest/$(basename "$p") (excludes: ${FILE_EXCLUDES[*]:-none})"
    else
      local -a excludes=("${FILE_EXCLUDES[@]:-}")
      local src_arg="$p"
      [[ -d "$p" ]] && src_arg="${p%/}/"
      if rsync_backup "$src_arg" "$dest/$(basename "$p")" "${excludes[@]}"; then
        log_ok "$SVC_NAME: rsync $p -> $dest/$(basename "$p")"
        local -a _fs
        _fs=($(find "$dest/$(basename "$p")" -type f 2>/dev/null | wc -l; du -sb "$dest/$(basename "$p")" 2>/dev/null | cut -f1))
        STAT_FILES=$((STAT_FILES + ${_fs[0]:-0}))
        STAT_BYTES=$((STAT_BYTES + ${_fs[1]:-0}))
      else
        local rcode=$?
        log_fail "$SVC_NAME: rsync failed for $p (exit=$rcode) — see log for details"
        ((rc+=1))
      fi
    fi
  done
  if [[ "$USE_RESTIC" == "true" && ${#FILE_PATHS[@]} -gt 0 ]]; then
    restic_backup_paths "$SVC_NAME" "${FILE_PATHS[@]}" || rc=$?
  fi
  return $rc
}

# ----------------------------------------------------------------------
# Main run
# ----------------------------------------------------------------------
for ctr in "${RUN_CONTAINERS[@]}"; do
  backup_one_service "$ctr"
done

if [[ "$DISCOVER" == "true" ]]; then
  log_info "Discovery finished: ${#RUN_CONTAINERS[@]} containers inventoried (no backup written)"
  exit 0
fi

if [[ ${#OPEN_GAPS[@]} -gt 0 ]]; then
  log_warn "Open gaps in this run (${#OPEN_GAPS[@]}):"
  local_l=""
  for local_l in "${OPEN_GAPS[@]}"; do
    log_warn "  - $local_l"
  done
fi

human_size() {
  local b="${1:-0}"
  if   (( b >= 1024*1024*1024 )); then echo "$((b / 1024 / 1024 / 1024))GB"
  elif (( b >= 1024*1024 ));      then echo "$((b / 1024 / 1024))MB"
  elif (( b >= 1024 ));           then echo "$((b / 1024))KB"
  else                                echo "${b}B"
  fi
}
log_info "Summary: $OKS Services backed up, $STAT_DUMPS database dumps, $STAT_FILES Files ($(human_size $STAT_BYTES)), PARTIAL=$PARTIALS"
log_info "Run finished: OK=$OKS FAIL=$FAILS SKIP=$SKIPS PARTIAL=$PARTIALS"
if [[ "$DRY_RUN" != "true" ]]; then
  printf 'OK=%s FAIL=%s SKIP=%s PARTIAL=%s DUMPS=%s FILES=%s BYTES=%s\n' \
    "$OKS" "$FAILS" "$SKIPS" "$PARTIALS" "$STAT_DUMPS" "$STAT_FILES" "$STAT_BYTES" \
    > "$BACKUP_ROOT/logs/last-run-summary.txt" 2>/dev/null || true
fi

if [[ "$DRY_RUN" != "true" ]]; then
  if [[ $FAILS -gt 0 ]]; then
    log_warn "Overall check: $FAILS service(s) with errors — see details above"
  else
    log_ok "Overall check: all scheduled backups successful and consistent"
  fi
fi

if [[ $FAILS -gt 0 ]]; then exit 1; fi
exit 0
