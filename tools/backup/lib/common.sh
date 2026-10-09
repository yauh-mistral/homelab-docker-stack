#!/usr/bin/env bash
# common.sh — Logging, locking, path handling, stop/start window, restic wrapper
# Part of the backup system for the Docker host. Sourced by backup.sh / restore.sh.
# Not meant to run standalone (no shebang execution path needed, but defensive):
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "common.sh is a library, do not execute directly." >&2
  exit 1
fi

set -o pipefail

# --- Configuration (can be overridden via /etc/backup.conf) ---
# BACKUP_ROOT: target (NAS)
# STACKS_DIR:   source of the compose stacks and their .env files (e.g. /opt/docker/arcane/projects)
#               Declarations may use the %STACKS_DIR% placeholder.
# --- Versioning (semantic versioning) ---
# Script version of the backup system. PATCH=fixes, MINOR=features,
# MAJOR=breaking changes (config/declaration format/CLI).
# INSTALL_STAMP is set by install.sh with the installation time
# (format: "YYYY-MM-DD HH:MM") so logs reveal which state was running.
# SCRIPT_BUILD is the number of the GitHub PR that delivered this state —
# added on merge so logs map unambiguously to the patch level (PR).
SCRIPT_VERSION="v1.0.0"
SCRIPT_BUILD="66"
INSTALL_STAMP="${INSTALL_STAMP:-not-installed}"
version_string() {
  local v="$SCRIPT_VERSION"
  [[ -n "$SCRIPT_BUILD" ]] && v+="+#${SCRIPT_BUILD}"
  if [[ "$INSTALL_STAMP" == "not-installed" ]]; then
    echo "$v (uninstalled repo copy)"
  else
    echo "$v $INSTALL_STAMP"
  fi
}

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/systems/backups/$(hostname)}"
RESTIC_ROOT="${RESTIC_ROOT:-/mnt/systems/backups/$(hostname)/restic}"
STACKS_DIR="${STACKS_DIR:-}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
USE_RESTIC="${USE_RESTIC:-false}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/restic-password}"
KEEP_DAILY_DUMPS="${KEEP_DAILY_DUMPS:-30}"
KEEP_MONTHLY_DUMPS="${KEEP_MONTHLY_DUMPS:-12}"
KEEP_DAILY_FILES="${KEEP_DAILY_FILES:-14}"
KEEP_WEEKLY_FILES="${KEEP_WEEKLY_FILES:-8}"
# rsnapshot-style rotation: number of retained versions (v.0 .. v.N-1)
# 0 = current version, 1 = yesterday, etc. Configurable via /etc/backup.conf.
KEEP_VERSIONS="${KEEP_VERSIONS:-14}"

LOG_FILE=""
_TIMESTAMP="$(date +%Y-%m-%d_%H%M)"

# --- Logging ---
log_init() {
  local dir="$BACKUP_ROOT/logs"
  if [[ "$DRY_RUN" == "true" ]]; then
    LOG_FILE=""
    return 0
  fi
  mkdir -p "$dir"
  LOG_FILE="$dir/${_TIMESTAMP}.log"
  : > "$LOG_FILE"
  echo "=== Version ($(version_string)) ===" >> "$LOG_FILE"
  echo "=== Backup run $_TIMESTAMP (host: $(hostname)) ===" >> "$LOG_FILE"
}

_log() {
  local level="$1"; shift
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$line"
  if [[ -n "$LOG_FILE" && "$DRY_RUN" != "true" ]]; then
    echo "$line" >> "$LOG_FILE"
  fi
}
log_info()  { _log INFO  "$@"; }
log_ok()    { _log OK    "$@"; }
log_fail()  { _log FAIL  "$@"; }
log_dry()   { _log DRY   "$@"; }
log_warn()  { _log WARN  "$@"; }

# Prefix for external tool output (rsync --stats, forgejo dump, etc.)
# so the log file keeps uniform timestamps. Use in pipes:
#   tool ... 2>>"$LOG_FILE" | tee_ext "$SVC_NAME" >>"$LOG_FILE"
# Without an active log (DRY_RUN), tee_ext is a plain >/dev/null.
tee_ext() {
  local svc="$1"
  if [[ -z "${LOG_FILE:-}" ]]; then
    cat >/dev/null
    return 0
  fi
  while IFS= read -r line; do
    printf '[%s] [EXT] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$svc" "$line" >>"$LOG_FILE"
  done
}

# --- Locking against parallel runs ---
_acquire_lock() {
  local lockfile="/tmp/backup-dispatcher.lock"
  if ! exec 9>"$lockfile"; then
    log_fail "Cannot open lockfile $lockfile"
    exit 1
  fi
  if ! flock -n 9; then
    log_fail "Another backup run is already active ($lockfile)"
    exit 1
  fi
}

# --- Existence checks (for dry runs and real runs) ---
# Preflight: is Docker reachable at all? If not (e.g. daemon down), every
# container_exists check returns false and all services would be SKIP.
# In that case we prefer a hard abort over silently backing up nothing.
docker_available() {
  docker info >/dev/null 2>&1
}

container_exists() {
  local name="${1:?container name missing}"
  docker inspect "$name" >/dev/null 2>&1
}

container_running() {
  local name="${1:?container name missing}"
  [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

# Checks whether the backup target is a real mount (the NAS must not be unmounted,
# otherwise the backup silently writes to the local disk).
# FORCE_LOCAL=true bypasses the check (for tests on non-production hosts).
require_mounted_target() {
  local target="${1:?target path missing}"
  if [[ "${FORCE_LOCAL:-false}" == "true" ]]; then
    log_warn "FORCE_LOCAL=true — mount check for $target skipped (tests only!)"
    return 0
  fi
  if ! command -v findmnt >/dev/null 2>&1; then
    log_warn "findmnt not available — cannot check mount status of $target"
    return 0
  fi
  if [[ -d "$target" && "$(findmnt -nr -o TARGET --target "$target" 2>/dev/null)" == "$target" ]]; then
    return 0
  fi
  # The target is on a mount (e.g. under /mnt), but this exact path
  # is not a mountpoint — acceptable if a parent mount exists
  local parent_mount
  parent_mount="$(findmnt -nr -o TARGET --target "$target" 2>/dev/null)" || true
  if [[ -n "$parent_mount" ]]; then
    case "$parent_mount" in
      /mnt/*|/mnt|/media/*) return 0 ;;
      *) : ;;
    esac
  fi
  log_fail "$target is not a NAS mount (findmnt found no mountpoint) — backup aborted."
  log_fail "If the backup should deliberately write to the local disk (TEST!): FORCE_LOCAL=true"
  return 1
}

# Waits until a Postgres container accepts connections (e.g. after a host reboot).
wait_for_postgres() {
  local container="${1:?container missing}" user="${2:-postgres}" tries="${3:-30}"
  local i
  for ((i=1; i<=tries; i++)); do
    if docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log_fail "$SVC_NAME: Postgres in $container not ready after $tries attempts"
  return 1
}

# --- Stop window ---
stop_containers() {
  local -a cts=("$@")
  STOPPED_CONTAINERS=()
  local c rc=0
  for c in "${cts[@]}"; do
    if container_running "$c"; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$SVC_NAME: would stop container '$c'"
      else
        if docker stop "$c" >/dev/null 2>&1; then
          STOPPED_CONTAINERS+=("$c")
          log_info "$SVC_NAME: container '$c' stopped (stop window)"
        else
          log_fail "$SVC_NAME: container '$c' could not be stopped"
          rc=1
        fi
      fi
    else
      log_warn "$SVC_NAME: container '$c' is not running (nothing to stop)"
    fi
  done
  # On errors, restart already stopped containers IMMEDIATELY
  # so no service accidentally stays down.
  if [[ $rc -ne 0 && ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
    log_warn "$SVC_NAME: stop window only partial — restarting already stopped containers"
    start_containers
  fi
  return $rc
}

start_containers() {
  local c
  for c in "${STOPPED_CONTAINERS[@]:-}"; do
    [[ -z "$c" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: would start container '$c'"
    else
      if docker start "$c" >/dev/null 2>&1; then
        log_info "$SVC_NAME: container '$c' restarted"
      else
        log_fail "$SVC_NAME: container '$c' could not be started!"
      fi
    fi
  done
}

# --- Target paths per service (rsnapshot-style rotation, NO timestamps in paths) ---
# Restore and cron stay stable: v.0 is always the latest state.
svc_db_dir()     { echo "$BACKUP_ROOT/${1:?svc}/db/v.0"; }
svc_files_dir()  { echo "$BACKUP_ROOT/${1:?svc}/files/v.0"; }

# --- Rotation (rsnapshot style): v.N -> v.N+1, oldest drops out ---
rotate_versions() {
  local base="${1:?base directory missing}" keep="${2:-$KEEP_VERSIONS}" i
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Rotation: would shift versions in $base (v.0..v.$((keep-1)))"
    return 0
  fi
  mkdir -p "$base"
  rm -rf "$base/v.$((keep-1))"
  for ((i=keep-2; i>=0; i--)); do
    [[ -e "$base/v.$i" ]] && mv "$base/v.$i" "$base/v.$((i+1))"
  done
  return 0
}

# --- Retention (dumps: KEEP_DAILY + monthly firsts) ---
prune_dump_dirs() {
  local base="$1" keep_days="$2" keep_monthly="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Retention: would remove dump directories in $base older than $keep_days days (keeping monthly firsts: $keep_monthly months)"
    return 0
  fi
  [[ -d "$base" ]] || return 0
  local d name month_first_limit
  month_first_limit="$(date -d "-${keep_monthly} months" +%Y-%m-01)"
  local -a to_delete=()
  while IFS= read -r d; do
    name="$(basename "$d")"
    # Keep monthly firsts (YYYY-MM-01_HHMM)
    if [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-01_ ]]; then
      # Monthly first: only delete if older than keep_monthly months
      if [[ "${name:0:10}" < "$month_first_limit" ]]; then to_delete+=("$d"); fi
      continue
    fi
    if [[ -z "$(find "$d" -type d -mtime -"$keep_days" 2>/dev/null)" ]]; then
      to_delete+=("$d")
    fi
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  local x
  for x in "${to_delete[@]:-}"; do
    [[ -e "$x" ]] || continue
    log_info "Retention: removing $x"
    rm -rf "$x"
  done
}

# --- rsync wrapper with exclude list from array ---
rsync_backup() {
  local src="$1" dest="$2"
  shift 2
  local -a excludes=() e
  for e in "$@"; do
    [[ -z "$e" ]] && continue
    excludes+=(--exclude "$e")
  done
  # Hardlink dedupe against the previous version (rsnapshot principle): unchanged
  # files take no additional space if the filesystem supports hardlinks
  # (NFS usually yes; CIFS often not — then a silent fallback without links).
  local link_dest="${dest/v.0/v.1}"
  if [[ -e "$link_dest" ]]; then
    excludes+=(--link-dest="$link_dest")
  fi
  # NAS shares usually do not allow chown by the host (root_squash/CIFS) —
  # without --no-owner/--no-group rsync returns exit code 23 (chown: operation
  # not permitted) despite a complete transfer. Ownership cannot be stored on
  # the target anyway; permissions/times are preserved.
  local -a opts=(-a --no-owner --no-group --delete-excluded --numeric-ids --mkpath)
  if [[ "$DRY_RUN" == "true" ]]; then
    opts+=(-n --stats)
  else
    opts+=(--stats)
  fi
  # rsync output (including error details) prefixed into the log — exit code preserved
  local errtmp=""
  [[ -n "${LOG_FILE:-}" ]] && errtmp="$(mktemp)"
  if [[ -n "$errtmp" ]]; then
    rsync "${opts[@]}" "${excludes[@]}" "$src" "$dest" 2>"$errtmp" | tee_ext "rsync" >>"$LOG_FILE"
    local rc=$?
    [[ -s "$errtmp" ]] && tee_ext "rsync" <"$errtmp" >>"$LOG_FILE"
    rm -f "$errtmp"
    return $rc
  fi
  rsync "${opts[@]}" "${excludes[@]}" "$src" "$dest"
  return $?
}

# --- Restic wrappers (optionally enabled) ---
restic_repo() { echo "${RESTIC_ROOT}/${1:?svc}"; }

restic_backup_paths() {
  local svc="$1"; shift
  if [[ "$USE_RESTIC" != "true" ]]; then return 0; fi
  local repo; repo="$(restic_repo "$svc")"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$svc: would run restic backup to $repo for: $*"
    return 0
  fi
  if ! command -v restic >/dev/null 2>&1; then
    log_warn "$svc: restic not installed, skipping restic backup"
    return 0
  fi
  mkdir -p "$repo"
  if ! restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" snapshots >/dev/null 2>&1; then
    restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" init >/dev/null 2>&1 || {
      log_fail "$svc: restic init failed"; return 1; }
  fi
  local -a excludes=()
  local e
  for e in "${FILE_EXCLUDES[@]:-}"; do
    [[ -z "$e" ]] && continue
    excludes+=(-e "$e")
  done
  restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" backup "$@" "${excludes[@]}" \
    >/dev/null 2>&1 || { log_fail "$svc: restic backup failed"; return 1; }
  restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" forget \
    --keep-daily "$KEEP_DAILY_FILES" --keep-weekly "$KEEP_WEEKLY_FILES" \
    --keep-monthly "$KEEP_MONTHLY_DUMPS" --prune >/dev/null 2>&1 || \
    log_warn "$svc: restic forget/prune failed (backup itself ok)"
  log_ok "$svc: restic backup updated"
  return 0
}
