#!/usr/bin/env bash
# common.sh — Logging, Locking, Pfad-Handling, Stop/Start-Fenster, Restic-Wrapper
# Teil des Backup-Systems fuer Host ovi. Wird von backup.sh / restore.sh gesourced.
# Keine Ausfuehrung standalone (kein shebang-Ausfuehrungspfad noetig, aber defensiv):
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "common.sh ist eine Bibliothek, nicht direkt ausfuehren." >&2
  exit 1
fi

set -o pipefail

# --- Konfiguration (kann durch /etc/backup.conf ueberschrieben werden) ---
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/systems/backups/ovi}"
RESTIC_ROOT="${RESTIC_ROOT:-/mnt/systems/backups/ovi/restic}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
USE_RESTIC="${USE_RESTIC:-false}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/restic-password}"
KEEP_DAILY_DUMPS="${KEEP_DAILY_DUMPS:-30}"
KEEP_MONTHLY_DUMPS="${KEEP_MONTHLY_DUMPS:-12}"
KEEP_DAILY_FILES="${KEEP_DAILY_FILES:-14}"
KEEP_WEEKLY_FILES="${KEEP_WEEKLY_FILES:-8}"

LOG_FILE=""
_TIMESTAMP="$(date +%Y-%m-%d_%H%M)"

# --- Logging ---
log_init() {
  local dir="$BACKUP_ROOT/_meta/runs"
  if [[ "$DRY_RUN" == "true" ]]; then
    LOG_FILE=""
    return 0
  fi
  mkdir -p "$dir"
  LOG_FILE="$dir/${_TIMESTAMP}.log"
  : > "$LOG_FILE"
  echo "=== Backup-Lauf $_TIMESTAMP (host: $(hostname)) ===" >> "$LOG_FILE"
}

_log() {
  local level="$1"; shift
  local line="[$level] $*"
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

# --- Locking gegen Parallel-Laefte ---
_acquire_lock() {
  local lockfile="/tmp/backup-dispatcher.lock"
  if ! exec 9>"$lockfile"; then
    log_fail "Kann Lockfile $lockfile nicht oeffnen"
    exit 1
  fi
  if ! flock -n 9; then
    log_fail "Ein anderer Backup-Lauf ist bereits aktiv ($lockfile)"
    exit 1
  fi
}

# --- Service-Deklarationen einlesen ---
# Erwartet: SERVICES_DIR (Pfad zu services.d), gefuellte Liste SVC_FILES (global)
load_service_declarations() {
  local dir="${1:?services.d-Pfad fehlt}"
  SVC_FILES=()
  local f
  for f in "$dir"/*.env; do
    [[ -e "$f" ]] || continue
    SVC_FILES+=("$f")
  done
  if [[ ${#SVC_FILES[@]} -eq 0 ]]; then
    log_fail "Keine Service-Deklarationen in $dir gefunden"
    exit 1
  fi
  # deterministische Reihenfolge
  SVC_FILES=($(printf '%s\n' "${SVC_FILES[@]}" | sort))
}

# Laedt eine Deklaration und validiert Pflichtfelder defensiv.
# setzt: SVC (assoz. via Variablen SVC_NAME, SVC_CATEGORY, ...)
load_declaration() {
  local file="${1:?Deklarationsdatei fehlt}"
  # Reset
  SVC_NAME="" SVC_CATEGORY="" SVC_STACK="" DB_TYPE="" DB_CONTAINER="" DB_USER=""
  DB_NAME="" DB_DUMP_ALL="" DB_DUMP_EXTRA="" FILE_PATHS=() FILE_EXCLUDES=()
  SQLITE_FILES=() STOP_CONTAINERS=() PRE_DUMP_HOOK="" POST_DUMP_HOOK=""
  # shellcheck disable=SC1090
  source "$file"
  SVC_NAME="${SVC_NAME:-$(basename "$file" .env)}"
  if [[ -z "${SVC_CATEGORY:-}" ]]; then
    log_fail "$SVC_NAME: SVC_CATEGORY fehlt in $file"
    return 1
  fi
  return 0
}

# --- Existenzpruefungen (fuer Dry-Run und echte Laeufe) ---
container_exists() {
  local name="${1:?Containername fehlt}"
  docker inspect "$name" >/dev/null 2>&1
}

container_running() {
  local name="${1:?Containername fehlt}"
  [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

# --- Stop-Fenster ---
stop_containers() {
  local -a cts=("$@")
  STOPPED_CONTAINERS=()
  local c
  for c in "${cts[@]}"; do
    if container_running "$c"; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$SVC_NAME: wuerde Container '$c' stoppen"
      else
        if docker stop "$c" >/dev/null 2>&1; then
          STOPPED_CONTAINERS+=("$c")
          log_info "$SVC_NAME: Container '$c' gestoppt (Stop-Fenster)"
        else
          log_fail "$SVC_NAME: Container '$c' konnte nicht gestoppt werden"
          return 1
        fi
      fi
    else
      log_warn "$SVC_NAME: Container '$c' laeuft nicht (nichts zu stoppen)"
    fi
  done
  return 0
}

start_containers() {
  local c
  for c in "${STOPPED_CONTAINERS[@]:-}"; do
    [[ -z "$c" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: wuerde Container '$c' starten"
    else
      if docker start "$c" >/dev/null 2>&1; then
        log_info "$SVC_NAME: Container '$c' wieder gestartet"
      else
        log_fail "$SVC_NAME: Container '$c' konnte nicht gestartet werden!"
      fi
    fi
  done
}

# --- Ziel-Pfade pro Service/Lauf ---
svc_db_dir()     { echo "$BACKUP_ROOT/${1:?svc}/db/${_TIMESTAMP}"; }
svc_files_dir()  { echo "$BACKUP_ROOT/${1:?svc}/files/${_TIMESTAMP}"; }

# --- Retention (Dumps: KEEP_DAILY + Monatsfirste) ---
prune_dump_dirs() {
  local base="$1" keep_days="$2" keep_monthly="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Retention: wuerde Dump-Verzeichnisse in $base aelter als $keep_days Tage entfernen (Monatsfirste behalten: $keep_monthly Monate)"
    return 0
  fi
  [[ -d "$base" ]] || return 0
  local d name month_first_limit
  month_first_limit="$(date -d "-${keep_monthly} months" +%Y-%m-01)"
  local -a to_delete=()
  while IFS= read -r d; do
    name="$(basename "$d")"
    # Behalte Monatsfirste (YYYY-MM-01_HHMM)
    if [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-01_ ]]; then
      # Monatsfirst: nur loeschen wenn aelter als keep_monthly Monate
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
    log_info "Retention: entferne $x"
    rm -rf "$x"
  done
}

# --- rsync-Wrapper mit Exclude-Liste aus Array ---
rsync_backup() {
  local src="$1" dest="$2"
  shift 2
  local -a excludes=() e
  for e in "$@"; do
    [[ -z "$e" ]] && continue
    excludes+=(--exclude "$e")
  done
  local -a opts=(-a --delete-excluded --numeric-ids --mkpath)
  if [[ "$DRY_RUN" == "true" ]]; then
    opts+=(-n --stats)
  else
    opts+=(--stats)
  fi
  rsync "${opts[@]}" "${excludes[@]}" "$src" "$dest"
}

# --- Restic-Wrapper (optional zugeschaltet) ---
restic_repo() { echo "${RESTIC_ROOT}/${1:?svc}"; }

restic_backup_paths() {
  local svc="$1"; shift
  if [[ "$USE_RESTIC" != "true" ]]; then return 0; fi
  local repo; repo="$(restic_repo "$svc")"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$svc: wuerde restic backup nach $repo ausfuehren fuer: $*"
    return 0
  fi
  if ! command -v restic >/dev/null 2>&1; then
    log_warn "$svc: restic nicht installiert, ueberspringe Restic-Backup"
    return 0
  fi
  mkdir -p "$repo"
  if ! restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" snapshots >/dev/null 2>&1; then
    restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" init >/dev/null 2>&1 || {
      log_fail "$svc: restic init fehlgeschlagen"; return 1; }
  fi
  local -a excludes=()
  local e
  for e in "${FILE_EXCLUDES[@]:-}"; do
    [[ -z "$e" ]] && continue
    excludes+=(-e "$e")
  done
  restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" backup "$@" "${excludes[@]}" \
    >/dev/null 2>&1 || { log_fail "$svc: restic backup fehlgeschlagen"; return 1; }
  restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" forget \
    --keep-daily "$KEEP_DAILY_FILES" --keep-weekly "$KEEP_WEEKLY_FILES" \
    --keep-monthly "$KEEP_MONTHLY_DUMPS" --prune >/dev/null 2>&1 || \
    log_warn "$svc: restic forget/prune fehlgeschlagen (Backup selbst ok)"
  log_ok "$svc: restic backup aktualisiert"
  return 0
}
