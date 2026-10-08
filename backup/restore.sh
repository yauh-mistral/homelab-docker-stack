#!/usr/bin/env bash
# restore.sh — Restore eines Services aus dem NAS-Backup (/mnt/systems).
# Nutzt dieselbe Deklaration wie der Dispatcher (services.d/<service>.env).
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

RESTORE_DATE=""
DB_ONLY=false; FILES_ONLY=false

if [[ $# -lt 1 ]]; then
  sed -n '2,8p' "$0" >&2
  exit 2
fi
SVC_ARG="${1:?Service-Name fehlt}"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     shift; RESTORE_DATE="${1:?--version braucht v.N (z.B. v.2)}" ;;
    --date)        shift; RESTORE_DATE="${1:?--date braucht v.N}" ;;
    --dry-run)     DRY_RUN=true ;;
    --db-only)     DB_ONLY=true ;;
    --files-only)  FILES_ONLY=true ;;
    -h|--help)     sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

# /etc/backup.conf zuerst laden (Quelle/Ziel: STACKS_DIR, BACKUP_ROOT, SERVICES_DIR, ...)
if [[ -f /etc/backup.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/backup.conf
fi

SERVICES_DIR="${SERVICES_DIR:-$SCRIPT_DIR/services.d}"
[[ -d "$SERVICES_DIR" ]] || { echo "services.d nicht gefunden" >&2; exit 2; }
[[ -n "${STACKS_DIR:-}" ]] || { echo "STACKS_DIR nicht gesetzt — siehe /etc/backup.conf" >&2; exit 2; }
DECL="$SERVICES_DIR/${SVC_ARG}.env"
[[ -f "$DECL" ]] || { echo "Keine Deklaration fuer '$SVC_ARG' ($DECL)" >&2; exit 2; }
load_declaration "$DECL"

log_init
_acquire_lock
log_info "Version ($(version_string))"
log_info "Restore: $SVC_NAME (date=${RESTORE_DATE:-latest}, dry-run=$DRY_RUN)"

# ---------------------------------------------------------------------
# Neuestes Backup-Verzeichnis finden
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
      log_fail "Backup-Stand $RESTORE_DATE nicht gefunden in $base"
      return 1
    fi
  else
    # Default: v.0 (immer der aktuellste Stand, rotationssicher)
    if [[ -d "$base/v.0" ]]; then
      echo "$base/v.0"
    else
      latest_dir "$base" || { log_fail "Keine Backups in $base gefunden"; return 1; }
    fi
  fi
}

rc=0

# ---------------------------------------------------------------------
# 1) DB-Restore
# ----------------------------------------------------------------------
restore_db() {
  local run_dir=""
  if ! run_dir="$(resolve_run_dir "$BACKUP_ROOT/$SVC_NAME/db")"; then
    log_fail "$SVC_NAME: kein DB-Backup-Stand in $BACKUP_ROOT/$SVC_NAME/db (date=${RESTORE_DATE:-latest})"
    ((rc+=1)); return
  fi
  log_info "$SVC_NAME: DB-Restore aus $run_dir"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: wuerde DB-Dump aus $run_dir einspielen (Typ: ${DB_TYPE:-unbekannt})"
    return
  fi
  case "${DB_TYPE:-}" in
    postgres)
      local dump="$run_dir/${SVC_NAME}.sql.gz"
      [[ -f "$dump" ]] || { log_fail "$SVC_NAME: Dump fehlt: $dump"; ((rc+=1)); return; }
      container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB-Container laeuft nicht"; ((rc+=1)); return; }
      if gunzip -c "$dump" | docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" \
          --single-transaction --set ON_ERROR_STOP=on >>"$LOG_FILE" 2>&1; then
        log_ok "$SVC_NAME: psql-Restore abgeschlossen"
      else
        log_fail "$SVC_NAME: psql-Restore fehlgeschlagen"; ((rc+=1))
      fi
      ;;
    mysql|mariadb)
      local dump="$run_dir/${SVC_NAME}.sql.gz"
      [[ -f "$dump" ]] || { log_fail "$SVC_NAME: Dump fehlt: $dump"; ((rc+=1)); return; }
      container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB-Container laeuft nicht"; ((rc+=1)); return; }
      if gunzip -c "$dump" | docker exec -i -e MYSQL_PWD="${DB_PASSWORD:-}" "$DB_CONTAINER" \
          mysql -u "$DB_USER" "$DB_NAME" >>"$LOG_FILE" 2>&1; then
        log_ok "$SVC_NAME: mysql-Restore abgeschlossen"
      else
        log_fail "$SVC_NAME: mysql-Restore fehlgeschlagen"; ((rc+=1))
      fi
      ;;
    sqlite)
      local entry host_path container_path dump
      for entry in "${SQLITE_FILES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        host_path="${entry%%:*}"
        container_path="${entry##*:}"
        dump="$run_dir/$(basename "$host_path").sqlite3"
        [[ -f "$dump" ]] || { log_fail "$SVC_NAME: SQLite-Dump fehlt: $dump"; ((rc+=1)); continue; }
        # Vaultwarden-Prozedur: Container stoppen, WAL/SHM loeschen, Datei einspielen
        if container_running "$DB_CONTAINER"; then
          docker stop "$DB_CONTAINER" >/dev/null 2>&1 || { log_fail "$SVC_NAME: $DB_CONTAINER konnte nicht gestoppt werden"; ((rc+=1)); continue; }
        fi
        rm -f "${host_path}-wal" "${host_path}-shm"
        if cp "$dump" "$host_path"; then
          log_ok "$SVC_NAME: SQLite-DB ersetzt: $host_path"
        else
          log_fail "$SVC_NAME: SQLite-Restore fehlgeschlagen"; ((rc+=1))
        fi
        docker start "$DB_CONTAINER" >/dev/null 2>&1 || log_warn "$SVC_NAME: $DB_CONTAINER konnte nicht gestartet werden"
      done
      ;;
    forgejo)
      # forgejo dump enthaelt DB+Config; Restore ist ein manueller Mehrschritt-
      # Prozess (Doku: docs/RESTORE.md). Wir liefern nur das Archiv bereit.
      log_info "$SVC_NAME: Forgejo-Dump liegt bereit in $run_dir — Restore siehe docs/RESTORE.md (Kategorie DB-Dump)"
      ;;
    surreal)
      log_info "$SVC_NAME: Surreal-Export liegt bereit in $run_dir — Restore via 'surreal import' (docs/RESTORE.md)"
      ;;
    *)
      log_fail "$SVC_NAME: Restore fuer DB_TYPE '${DB_TYPE:-leer}' nicht implementiert"; ((rc+=1))
      ;;
  esac
}

# ---------------------------------------------------------------------
# 2) Datei-Restore (rsync zurueck)
# ----------------------------------------------------------------------
restore_files() {
  local run_dir=""
  if ! run_dir="$(resolve_run_dir "$BACKUP_ROOT/$SVC_NAME/files")"; then
    log_fail "$SVC_NAME: kein Datei-Backup-Stand in $BACKUP_ROOT/$SVC_NAME/files (date=${RESTORE_DATE:-latest})"
    ((rc+=1)); return
  fi
  log_info "$SVC_NAME: Datei-Restore aus $run_dir"
  # Stop-Fenster wie beim Backup (konsistente Zurueckkopie)
  if [[ ${#STOP_CONTAINERS[@]} -gt 0 ]]; then
    if ! stop_containers "${STOP_CONTAINERS[@]}"; then
      log_fail "$SVC_NAME: Stop-Fenster fehlgeschlagen — Datei-Restore abgebrochen"
      ((rc+=1)); return
    fi
  fi
  local p src dest
  for p in "${FILE_PATHS[@]:-}"; do
    [[ -z "$p" ]] && continue
    src="$run_dir/$(basename "$p")"
    if [[ ! -e "$src" ]]; then
      log_warn "$SVC_NAME: Backup-Quelle fehlt: $src (ueberspringe)"
      continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: wuerde rsyncen: $src/ -> $p/"
    else
      mkdir -p "$p"
      if rsync -a --numeric-ids "$src/" "$p/"; then
        log_ok "$SVC_NAME: rsync $src -> $p"
      else
        log_fail "$SVC_NAME: rsync fehlgeschlagen: $src -> $p"; ((rc+=1))
      fi
    fi
  done
  start_containers
}

# ---------------------------------------------------------------------
case "$SVC_CATEGORY" in
  ignore)
    log_info "$SVC_NAME ist als 'ignore' deklariert — nichts zu restoren"
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
    log_fail "$SVC_NAME: unbekannte Kategorie '$SVC_CATEGORY'"; ((rc+=1))
    ;;
esac

if [[ $rc -eq 0 ]]; then
  log_ok "$SVC_NAME: Restore abgeschlossen — Service verifizieren (docs/RESTORE.md Checkliste)!"
else
  log_fail "$SVC_NAME: Restore mit Fehlern abgeschlossen (rc=$rc)"
fi
exit $rc
