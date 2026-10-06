#!/usr/bin/env bash
# backup.sh — Dispatcher des modularen Backup-Systems fuer Host ovi.
# Liest Service-Deklarationen aus services.d/ und sichert DB-Dumps und Dateien
# nach /mnt/systems (NAS-Mount). Idempotent, defensiv, mit Dry-Run-Modus.
#
# Usage:
#   backup.sh [--dry-run] [--only-db] [--only-files] [--only-config] [--service NAME]
#   backup.sh --list
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/db.sh
source "$SCRIPT_DIR/lib/db.sh"

# ----------------------------------------------------------------------
# Optionen parsen
# ----------------------------------------------------------------------
ONLY_DB=false; ONLY_FILES=false; ONLY_CONFIG=false; SERVICE_FILTER=""; LIST=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=true ;;
    --only-db)     ONLY_DB=true ;;
    --only-files)  ONLY_FILES=true; ONLY_CONFIG=true ;;
    --only-config) ONLY_CONFIG=true ;;
    --service)     shift; SERVICE_FILTER="${1:?--service braucht einen Namen}" ;;
    --list)        LIST=true ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

# /etc/backup.conf zuerst laden (setzt Quelle/Ziel: STACKS_DIR, BACKUP_ROOT, SERVICES_DIR, ...)
# Reihenfolge: CLI-Flag > /etc/backup.conf > Defaults aus lib/common.sh
if [[ -f /etc/backup.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/backup.conf
fi

# SERVICES_DIR: Heimat der Deklarationen. Default neben diesem Skript; bei
# Installation unter /opt/docker/backup zeigt der Installer sie auf
# /opt/docker/backup/services.d (physisch eigene Kopie, unabhaengig vom Repo).
SERVICES_DIR="${SERVICES_DIR:-$SCRIPT_DIR/services.d}"
[[ -d "$SERVICES_DIR" ]] || { echo "services.d nicht gefunden: $SERVICES_DIR" >&2; exit 2; }
[[ -n "${STACKS_DIR:-}" ]] || { echo "STACKS_DIR nicht gesetzt — Quelle der Compose-Stacks/.env unbekannt." >&2; echo "Setze STACKS_DIR in /etc/backup.conf (z.B. STACKS_DIR=/opt/docker/arcane/projects)" >&2; exit 2; }

load_service_declarations "$SERVICES_DIR"

if [[ "$LIST" == "true" ]]; then
  echo "Deklarierte Services:"
  for f in "${SVC_FILES[@]}"; do
    load_declaration "$f" || continue
    printf '  %-20s %-14s db=%-8s files=%d stop=%d\n' \
      "$SVC_NAME" "$SVC_CATEGORY" "${DB_TYPE:-}" "${#FILE_PATHS[@]}" "${#STOP_CONTAINERS[@]}"
  done
  exit 0
fi

log_init
_acquire_lock
log_info "Dispatcher start: ${#SVC_FILES[@]} Deklarationen, dry-run=$DRY_RUN, Ziel=$BACKUP_ROOT"

# Preflight: Ohne Docker-Daemon wuerden alle Container-Checks falsch-negativ
# sein — lieber hart abbrechen als viele SKIPs als Erfolg zu verkaufen.
if [[ "$DRY_RUN" != "true" ]]; then
  if ! docker_available; then
    log_fail "Abbruch: Docker-Daemon nicht erreichbar (docker info fehlgeschlagen)"
    exit 1
  fi
fi

# Mount-Guard: NAS-Ziel muss ein echter Mount sein, sonst schreibt das Backup
# stillschweigend auf die lokale Platte (Katastrofall: Platte voll + falsches Ziel).
if [[ "$DRY_RUN" != "true" ]]; then
  if ! require_mounted_target "$BACKUP_ROOT"; then
    log_fail "Abbruch: Backup-Ziel $BACKUP_ROOT ist nicht als NAS-Mount verfuegbar"
    exit 1
  fi
  mkdir -p "$BACKUP_ROOT/_meta/runs" || { log_fail "Abbruch: Kann $BACKUP_ROOT/_meta/runs nicht anlegen"; exit 1; }
fi

# ----------------------------------------------------------------------
# Validierungs-Phase (immer, auch im Dry-Run): Deckung mit dem Inventar
# ----------------------------------------------------------------------
FAILS=0
OKS=0
SKIPS=0
WARTENDE_LUECKEN=()

validate_declaration() {
  local problems=0
  SVC_DB_OK=true
  SVC_FILES_OK=true
  # DB-Kategorie braucht DB_TYPE und DB_CONTAINER
  case "$SVC_CATEGORY" in
    db_only|db_and_files)
      if [[ -z "${DB_TYPE:-}" || -z "${DB_CONTAINER:-}" ]]; then
        log_fail "$SVC_NAME: DB-Kategorie, aber DB_TYPE/DB_CONTAINER fehlt"; problems=1
      else
        # Preflight: Existiert der DB-Container ueberhaupt? Fehlt er komplett,
        # ist der Service vermutlich nicht deployt -> SKIP statt FAIL.
        if ! container_exists "$DB_CONTAINER"; then
          log_warn "$SVC_NAME: DB-Container '$DB_CONTAINER' existiert nicht auf diesem Host"
          WARTENDE_LUECKEN+=("DB-Container fehlt: $DB_CONTAINER ($SVC_NAME)")
          SVC_DB_OK=false
        elif ! container_running "$DB_CONTAINER"; then
          log_warn "$SVC_NAME: DB-Container '$DB_CONTAINER' existiert, laeuft aber nicht"
          WARTENDE_LUECKEN+=("DB-Container laeuft nicht: $DB_CONTAINER ($SVC_NAME)")
          SVC_DB_OK=false
        fi
      fi
      ;;
  esac
  # Datei-Kategorie braucht Pfade
  case "$SVC_CATEGORY" in
    files_only|db_and_files|config_only)
      if [[ ${#FILE_PATHS[@]} -eq 0 && ${#SQLITE_FILES[@]} -eq 0 ]]; then
        log_fail "$SVC_NAME: Datei-Kategorie, aber FILE_PATHS/SQLITE_FILES leer"; problems=1
      fi
      ;;
  esac
  # Quellpfade pruefen (Warnung, kein Abbruch: Luecke dokumentieren)
  local p any_path_exists=false
  for p in "${FILE_PATHS[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ ! -e "$p" ]]; then
      log_warn "$SVC_NAME: Quellpfad existiert nicht auf diesem Host: $p"
      WARTENDE_LUECKEN+=("Quellpfad fehlt: $p ($SVC_NAME)")
    else
      any_path_exists=true
    fi
  done
  [[ "$any_path_exists" == "true" ]] || SVC_FILES_OK=false
  # SQLite-Dateien gelten als vorhandene Quelle, wenn der Container existiert
  if [[ ${#SQLITE_FILES[@]} -gt 0 && "$SVC_DB_OK" == "true" ]]; then
    SVC_FILES_OK=true
  fi
  return $problems
}

should_process() {
  # Filter nach CLI (db/files/config) und --service
  if [[ -n "$SERVICE_FILTER" && "$SVC_NAME" != "$SERVICE_FILTER" ]]; then return 1; fi
  case "$SVC_CATEGORY" in
    ignore) return 1 ;;
    db_only)
      [[ "$ONLY_FILES" == "true" ]] && return 1 ;;
    files_only)
      [[ "$ONLY_DB" == "true" ]] && return 1 ;;
    config_only)
      [[ "$ONLY_DB" == "true" ]] && return 1 ;;
    db_and_files) return 0 ;;
    *) return 1 ;;
  esac
  return 0
}

# ----------------------------------------------------------------------
# Backup-Phase pro Service
# ----------------------------------------------------------------------
backup_one_service() {
  local f="$1"
  load_declaration "$f" || { ((FAILS+=1)); return 1; }
  if ! should_process; then
    ((SKIPS+=1))
    return 0
  fi
  if ! validate_declaration; then
    ((FAILS+=1))
    return 1
  fi

  # Preflight-Ergebnis: Fehlt die Quelle komplett (Container nicht vorhanden,
  # keine existierenden Pfade), ist der Service auf diesem Host offenbar nicht
  # deployt -> sauberer SKIP statt FAIL. Ein Teil fehlt -> Teil-Backup + WARN.
  local skip_db=false skip_files=false
  case "$SVC_CATEGORY" in
    db_only)        [[ "$SVC_DB_OK" == "false" ]] && skip_db=true ;;
    files_only|config_only) [[ "$SVC_FILES_OK" == "false" ]] && skip_files=true ;;
    db_and_files)
      [[ "$SVC_DB_OK" == "false" ]] && skip_db=true
      [[ "$SVC_FILES_OK" == "false" ]] && skip_files=true
      ;;
  esac
  if [[ "$skip_db" == "true" && "$skip_files" == "true" ]]; then
    ((SKIPS+=1))
    log_info "$SVC_NAME: SKIP — Quelle fehlt komplett (Service nicht deployt oder Pfade/Container stimmen nicht)"
    return 0
  fi

  local rc=0
  # PRE_DUMP_HOOK (z.B. paperless document_exporter)
  if [[ -n "${PRE_DUMP_HOOK:-}" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: wuerde PRE_DUMP_HOOK ausfuehren: $PRE_DUMP_HOOK"
    else
      # shellcheck disable=SC2016
      if ! bash -c "$PRE_DUMP_HOOK" >>"$LOG_FILE" 2>&1; then
        log_fail "$SVC_NAME: PRE_DUMP_HOOK fehlgeschlagen"; ((rc+=1))
      fi
    fi
  fi

  # 1) DB-Dump (immer zuerst — Immich-Reihenfolge: DB vor Dateien)
  case "$SVC_CATEGORY" in
    db_only|db_and_files)
      if [[ "$skip_db" == "true" ]]; then
        log_warn "$SVC_NAME: DB-Backup uebersprungen (Container fehlt/laeuft nicht) — Teil-Backup"
      else
        if ! dump_database "$(svc_db_dir "$SVC_NAME")"; then ((rc+=1)); fi
      fi
      ;;
  esac

  # POST_DUMP_HOOK
  if [[ -n "${POST_DUMP_HOOK:-}" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: wuerde POST_DUMP_HOOK ausfuehren: $POST_DUMP_HOOK"
    else
      # shellcheck disable=SC2016
      if ! bash -c "$POST_DUMP_HOOK" >>"$LOG_FILE" 2>&1; then
        log_warn "$SVC_NAME: POST_DUMP_HOOK fehlgeschlagen (nicht fatal)"
      fi
    fi
  fi

  # 2) Dateien (mit optionalem Stop-Fenster)
  case "$SVC_CATEGORY" in
    files_only|db_and_files|config_only)
      if [[ "$skip_files" == "true" ]]; then
        log_warn "$SVC_NAME: Datei-Backup uebersprungen (keine Quelldateien vorhanden) — Teil-Backup"
      else
      local do_stop=false
      if [[ ${#STOP_CONTAINERS[@]} -gt 0 ]]; then do_stop=true; fi
      if [[ "$do_stop" == "true" ]]; then
        if ! stop_containers "${STOP_CONTAINERS[@]}"; then
          log_fail "$SVC_NAME: Stop-Fenster konnte nicht geoeffnet werden — ueberspringe Datei-Backup"
          ((rc+=1))
        else
          if ! backup_files_for_service; then ((rc+=1)); fi
          start_containers
        fi
      else
        if ! backup_files_for_service; then ((rc+=1)); fi
      fi
      fi
      ;;
  esac

  if [[ $rc -eq 0 ]]; then
    ((OKS+=1)); log_ok "$SVC_NAME: Backup abgeschlossen"
  else
    ((FAILS+=1))
  fi
}

backup_files_for_service() {
  local rc=0 p dest
  dest="$(svc_files_dir "$SVC_NAME")"
  if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$dest"
  fi
  for p in "${FILE_PATHS[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ ! -e "$p" && "$DRY_RUN" != "true" ]]; then
      log_warn "$SVC_NAME: Quelle fehlt, ueberspringe: $p"; ((rc+=1)); continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: wuerde rsyncen: $p -> $dest/ ($(basename "$p")) (excludes: ${FILE_EXCLUDES[*]:-none})"
    else
      local -a excludes=("${FILE_EXCLUDES[@]:-}")
      if rsync_backup "$p" "$dest/$(basename "$p")" "${excludes[@]}"; then
        log_ok "$SVC_NAME: rsync $p -> $dest/$(basename "$p")"
      else
        log_fail "$SVC_NAME: rsync fehlgeschlagen fuer $p"; ((rc+=1))
      fi
    fi
  done
  # Restic optional
  if [[ "$USE_RESTIC" == "true" && ${#FILE_PATHS[@]} -gt 0 ]]; then
    restic_backup_paths "$SVC_NAME" "${FILE_PATHS[@]}" || rc=$?
  fi
  return $rc
}

# ----------------------------------------------------------------------
# Hauptlauf
# ----------------------------------------------------------------------
for f in "${SVC_FILES[@]}"; do
  backup_one_service "$f"
done

# Retention nur bei echtem Lauf (fuer DB-Kategorien)
if [[ "$DRY_RUN" != "true" ]]; then
  for f in "${SVC_FILES[@]}"; do
    load_declaration "$f" || continue
    case "$SVC_CATEGORY" in
      db_only|db_and_files)
        prune_dump_dirs "$BACKUP_ROOT/$SVC_NAME/db" "$KEEP_DAILY_DUMPS" "$KEEP_MONTHLY_DUMPS"
        ;;
    esac
  done
fi

# Luecken (fehlende Quellpfade) als Fragen dokumentieren
if [[ ${#WARTENDE_LUECKEN[@]} -gt 0 ]]; then
  log_warn "Offene Luecken in diesem Lauf (${#WARTENDE_LUECKEN[@]}):"
  local_l=""
  for local_l in "${WARTENDE_LUECKEN[@]}"; do
    log_warn "  - $local_l"
  done
fi

log_info "Lauf beendet: OK=$OKS FAIL=$FAILS SKIP=$SKIPS"
if [[ "$DRY_RUN" != "true" ]]; then
  echo "OK=$OKS FAIL=$FAILS SKIP=$SKIPS" > "$BACKUP_ROOT/_meta/last-run-summary.txt" 2>/dev/null || true
fi

# Exit-Code: 0 wenn keine Fehler, sonst 1 (unabhaengig von der Anzahl)
if [[ $FAILS -gt 0 ]]; then exit 1; fi
exit 0
