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
# BACKUP_ROOT: Ziel (NAS)
# STACKS_DIR:   Quelle der Compose-Stacks und deren .env-Dateien (z.B. /opt/docker/arcane/projects)
#               Deklarationen koennen den Platzhalter %STACKS_DIR% nutzen.
# --- Versionierung (Semantic Versioning) ---
# Skript-Version des Backup-Systems. PATCH=Fixes, MINOR=Features,
# MAJOR=Breaking Changes (Config/Deklarationsformat/CLI).
# INSTALL_STAMP wird von install.sh mit Installationszeitpunkt versehen
# (Format: "YYYY-MM-DD HH:MM"), damit Logs erkennen lassen, welcher Stand lief.
SCRIPT_VERSION="v1.0.0"
INSTALL_STAMP="${INSTALL_STAMP:-not-installed}"
version_string() {
  if [[ "$INSTALL_STAMP" == "not-installed" ]]; then
    echo "$SCRIPT_VERSION (uninstalled repo copy)"
  else
    echo "$SCRIPT_VERSION $INSTALL_STAMP"
  fi
}

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/systems/backups/ovi}"
RESTIC_ROOT="${RESTIC_ROOT:-/mnt/systems/backups/ovi/restic}"
STACKS_DIR="${STACKS_DIR:-}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
USE_RESTIC="${USE_RESTIC:-false}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/restic-password}"
KEEP_DAILY_DUMPS="${KEEP_DAILY_DUMPS:-30}"
KEEP_MONTHLY_DUMPS="${KEEP_MONTHLY_DUMPS:-12}"
KEEP_DAILY_FILES="${KEEP_DAILY_FILES:-14}"
KEEP_WEEKLY_FILES="${KEEP_WEEKLY_FILES:-8}"
# rsnapshot-artige Rotation: Anzahl behaltener Versionen (v.0 .. v.N-1)
# 0 = aktuelle Version, 1 = gestern usw. Konfigurierbar via /etc/backup.conf.
KEEP_VERSIONS="${KEEP_VERSIONS:-14}"

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
  echo "=== Version ($(version_string)) ===" >> "$LOG_FILE"
  echo "=== Backup-Lauf $_TIMESTAMP (host: $(hostname)) ===" >> "$LOG_FILE"
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

# Praefix fuer externen Tool-Output (rsync --stats, forgejo dump, etc.),
# damit die Log-Datei einheitliche Timestamps behaelt. Aufruf in Pipes:
#   tool ... 2>>"$LOG_FILE" | tee_ext "$SVC_NAME" >>"$LOG_FILE"
# Ohne aktives Log (DRY_RUN) ist tee_ext ein reines >/dev/null.
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

# --- Existenzpruefungen (fuer Dry-Run und echte Laeufe) ---
# Preflight: Ist Docker ueberhaupt ansprechbar? Wenn nicht (z.B. Daemon down),
# liefert jede container_exists-Pruefung false und alle Services waeren SKIP.
# In dem Fall brechen wir lieber hart ab, statt stillschweigend nichts zu sichern.
docker_available() {
  docker info >/dev/null 2>&1
}

container_exists() {
  local name="${1:?Containername fehlt}"
  docker inspect "$name" >/dev/null 2>&1
}

container_running() {
  local name="${1:?Containername fehlt}"
  [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

# Prueft, ob das Backup-Ziel ein echter Mount ist (NAS darf nicht abgemountet sein,
# sonst schreibt das Backup stillschweigend auf die lokale Platte).
# FORCE_LOCAL=true umgeht den Check (fuer Tests auf Nicht-Produktions-Hosts).
require_mounted_target() {
  local target="${1:?Zielpfad fehlt}"
  if [[ "${FORCE_LOCAL:-false}" == "true" ]]; then
    log_warn "FORCE_LOCAL=true — Mount-Pruefung von $target uebersprungen (nur fuer Tests!)"
    return 0
  fi
  if ! command -v findmnt >/dev/null 2>&1; then
    log_warn "findmnt nicht verfuegbar — kann Mount-Status von $target nicht pruefen"
    return 0
  fi
  if [[ -d "$target" && "$(findmnt -nr -o TARGET --target "$target" 2>/dev/null)" == "$target" ]]; then
    return 0
  fi
  # Ziel liegt auf einem Mount (z.B. /mnt oder darunter), aber exakt dieser Pfad
  # ist kein Mountpoint — akzeptabel, wenn ein uebergeordneter Mount existiert
  local parent_mount
  parent_mount="$(findmnt -nr -o TARGET --target "$target" 2>/dev/null)" || true
  if [[ -n "$parent_mount" ]]; then
    case "$parent_mount" in
      /mnt/*|/mnt|/media/*) return 0 ;;
      *) : ;;
    esac
  fi
  log_fail "$target ist kein NAS-Mount (findmnt findet keinen Mountpoint) — Backup abgebrochen."
  log_fail "Wenn das Backup absichtlich auf lokale Platte laufen soll (TEST!): FORCE_LOCAL=true"
  return 1
}

# Wartet, bis ein Postgres-Container Verbindungen annimmt (nach z.B. Host-Reboot).
wait_for_postgres() {
  local container="${1:?Container fehlt}" user="${2:-postgres}" tries="${3:-30}"
  local i
  for ((i=1; i<=tries; i++)); do
    if docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log_fail "$SVC_NAME: Postgres in $container nach $tries Versuchen nicht bereit"
  return 1
}

# --- Stop-Fenster ---
stop_containers() {
  local -a cts=("$@")
  STOPPED_CONTAINERS=()
  local c rc=0
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
          rc=1
        fi
      fi
    else
      log_warn "$SVC_NAME: Container '$c' laeuft nicht (nichts zu stoppen)"
    fi
  done
  # Bei Fehlern bereits gestoppte Container SOFORT wieder starten,
  # damit kein Service versehentlich down bleibt.
  if [[ $rc -ne 0 && ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
    log_warn "$SVC_NAME: Stop-Fenster nur teilweise — starte bereits gestoppte Container zurueck"
    start_containers
  fi
  return $rc
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

# --- Ziel-Pfade pro Service (rsnapshot-artige Rotation, KEINE Timestamps im Pfad) ---
# Restore und Cron bleiben dadurch stabil: v.0 ist immer der aktuellste Stand.
svc_db_dir()     { echo "$BACKUP_ROOT/${1:?svc}/db/v.0"; }
svc_files_dir()  { echo "$BACKUP_ROOT/${1:?svc}/files/v.0"; }

# --- Rotation (rsnapshot-Stil): v.N -> v.N+1, aelteste faellt raus ---
rotate_versions() {
  local base="${1:?Basisverzeichnis fehlt}" keep="${2:-$KEEP_VERSIONS}" i
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Rotation: wuerde Versionen in $base weiterschieben (v.0..v.$((keep-1)))"
    return 0
  fi
  mkdir -p "$base"
  rm -rf "$base/v.$((keep-1))"
  for ((i=keep-2; i>=0; i--)); do
    [[ -e "$base/v.$i" ]] && mv "$base/v.$i" "$base/v.$((i+1))"
  done
  return 0
}

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
  # Hardlink-Dedupe gegen Vortagesversion (rsnapshot-Prinzip): unveraenderte
  # Dateien belegen keinen zusaetzlichen Platz, wenn das Dateisystem Hardlinks
  # unterstuetzt (NFS meist ja; CIFS oft nicht — dann stiller Fallback ohne Link).
  local link_dest="${dest/v.0/v.1}"
  if [[ -e "$link_dest" ]]; then
    excludes+=(--link-dest="$link_dest")
  fi
  # NAS-Shares erlauben i.d.R. kein chown durch den Host (root_squash/CIFS) —
  # ohne --no-owner/--no-group liefert rsync trotz vollstaendigem Transfer
  # Exit-Code 23 (chown: Operation not permitted). Ownership kann auf dem
  # Ziel ohnehin nicht gespeichert werden; Rechte/Zeiten bleiben erhalten.
  local -a opts=(-a --no-owner --no-group --delete-excluded --numeric-ids --mkpath)
  if [[ "$DRY_RUN" == "true" ]]; then
    opts+=(-n --stats)
  else
    opts+=(--stats)
  fi
  # rsync-Output (inkl. Fehlerdetails) praefixiert ins Log — Exit-Code bleibt erhalten
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
