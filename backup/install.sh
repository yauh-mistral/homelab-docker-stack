#!/usr/bin/env bash
# install.sh — Installiert das Backup-System in seine eigene Heimat (Default /opt/docker/backup),
# unabhaengig vom Repo. Quelle (Compose-Stacks + .env) und Ziel (NAS) werden in
# /etc/backup.conf konfiguriert, nicht im Code.
#
# Usage:
#   install.sh [--home /opt/docker/backup] [--stacks-dir /pfad/zu/projects] [--backup-root /mnt/systems/backups/ovi]
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Version und Build (PR-Nummer) zum Installationszeitpunkt aus lib/common.sh uebernehmen
LIB_VERSION="$(grep -m1 '^SCRIPT_VERSION=' "$SCRIPT_DIR/lib/common.sh" | cut -d= -f2 | tr -d '"')"
LIB_BUILD="$(grep -m1 '^SCRIPT_BUILD=' "$SCRIPT_DIR/lib/common.sh" | cut -d= -f2 | tr -d '"')"
INSTALL_STAMP="$(date '+%Y-%m-%d %H:%M')"

INSTALL_HOME="/opt/docker/backup"
STACKS_DIR="/opt/docker/arcane/projects"
BACKUP_ROOT="/mnt/systems/ovi/backup"
CONF_FILE="/etc/backup.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)        shift; INSTALL_HOME="${1:?--home braucht Pfad}" ;;
    --stacks-dir)  shift; STACKS_DIR="${1:?--stacks-dir braucht Pfad}" ;;
    --backup-root) shift; BACKUP_ROOT="${1:?--backup-root braucht Pfad}" ;;
    -h|--help)     sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "== Backup-System-Installation =="
echo "Heimat:      $INSTALL_HOME"
echo "Quelle:      ${STACKS_DIR:-<nachfragen>}"
echo "Ziel (NAS):  $BACKUP_ROOT"
echo "Konfig:      $CONF_FILE"
echo

# --- Eingaben validieren / erfragen ---
if [[ -z "$STACKS_DIR" ]]; then
  read -r -p "Pfad zu den Compose-Stacks (projects/, enthaelt die .env-Dateien): " STACKS_DIR
fi
[[ -d "$STACKS_DIR" ]] || { echo "FEHLER: Quellverzeichnis existiert nicht: $STACKS_DIR" >&2; exit 1; }
[[ -f "$STACKS_DIR/ghost/compose.yaml" || -f "$STACKS_DIR/ghost/docker-compose.yml" ]] \
  || echo "WARNUNG: $STACKS_DIR sieht nicht nach dem projects/-Verzeichnis aus (kein ghost-Stack gefunden) — trotzdem fortgesetzt."

# --- Heimat anlegen ---
mkdir -p "$INSTALL_HOME" || { echo "FEHLER: Kann $INSTALL_HOME nicht anlegen" >&2; exit 1; }

# --- Dateien kopieren (idempotent; rsync wenn verfuegbar, sonst cp-Fallback) ---
copy_file() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src" "$dest"
  else
    cp -a "$src" "$dest"
  fi
}
copy_tree() {
  local src="$1" dest="$2" mirror="${3:-false}"
  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    local -a opts=(-a)
    [[ "$mirror" == "true" ]] && opts+=(--delete)
    rsync "${opts[@]}" "$src/" "$dest/"
  else
    cp -a "$src/." "$dest/"
    if [[ "$mirror" == "true" ]]; then
      echo "WARNUNG: rsync nicht verfuegbar — --delete (Mirror) uebersprungen." >&2
      echo "         Bitte $dest manuell mit dem Repo-Stand abgleichen." >&2
    fi
  fi
}
copy_file "$SCRIPT_DIR/backup.sh" "$INSTALL_HOME/"
copy_file "$SCRIPT_DIR/restore.sh" "$INSTALL_HOME/"
copy_file "$SCRIPT_DIR/test-restore.sh" "$INSTALL_HOME/"
copy_tree "$SCRIPT_DIR/lib" "$INSTALL_HOME/lib"
copy_tree "$SCRIPT_DIR/policies.d" "$INSTALL_HOME/policies.d" true
copy_file "$SCRIPT_DIR/policy.conf" "$INSTALL_HOME/"
chmod +x "$INSTALL_HOME"/*.sh

# Installationszeitpunkt und Build (PR-Nummer) in die installierte Kopie von
# lib/common.sh schreiben, damit jedes Backup-/Restore-Log Version + Patch-Level +
# Install-Zeit ausweist.
sed -i "s|^INSTALL_STAMP=\"\${INSTALL_STAMP:-.*}\"|INSTALL_STAMP=\"$INSTALL_STAMP\"|" \
  "$INSTALL_HOME/lib/common.sh" || true
sed -i "s|^SCRIPT_BUILD=\"\${SCRIPT_BUILD:-.*}\"|SCRIPT_BUILD=\"$LIB_BUILD\"|" \
  "$INSTALL_HOME/lib/common.sh" || true
echo "Kopiert: backup.sh, restore.sh, test-restore.sh, lib/, policies.d/, policy.conf -> $INSTALL_HOME (Version ${LIB_VERSION}${LIB_BUILD:+ +#$LIB_BUILD}, installiert $INSTALL_STAMP)"

# --- Konfiguration schreiben (vorhandene nicht ueberschreiben, nur ergaenzen) ---
if [[ -f "$CONF_FILE" ]]; then
  echo "Hinweis: $CONF_FILE existiert bereits — pruefe Eintraege:"
  missing=()
  grep -q "^STACKS_DIR=" "$CONF_FILE" || missing+=("STACKS_DIR=$STACKS_DIR")
  grep -q "^BACKUP_ROOT=" "$CONF_FILE" || missing+=("BACKUP_ROOT=$BACKUP_ROOT")
  grep -q "^POLICY_DIR=" "$CONF_FILE" || missing+=("POLICY_DIR=$INSTALL_HOME/policies.d")
  grep -q "^KEEP_VERSIONS=" "$CONF_FILE" || missing+=("KEEP_VERSIONS=14")
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}" >> "$CONF_FILE"
    echo "Ergaenzt: ${missing[*]}"
  fi
else
  cat > "$CONF_FILE" <<EOF
# Backup-Konfiguration (von install.sh erzeugt) — Quelle, Ziel, Heimat der Deklarationen
# Quelle: Compose-Stacks inkl. deren .env-Dateien (fuer DB-Passwoerter via ENV_FILE)
STACKS_DIR=$STACKS_DIR
# Ziel: NAS-Mount (Dispatcher verweigert Start, wenn kein Mount)
BACKUP_ROOT=$BACKUP_ROOT
# Heimat der Policy-Overlays (installierte Kopie, unabhaengig vom Repo)
POLICY_DIR=$INSTALL_HOME/policies.d
# Optional: Restic (erst aktivieren, wenn restic installiert + Passwortdatei existiert)
USE_RESTIC=false
# RESTIC_PASSWORD_FILE=/etc/restic-password
# Anzahl behaltener Versionen (rsnapshot-Rotation v.0..v.KEEP_VERSIONS-1)
KEEP_VERSIONS=14
EOF
  chmod 600 "$CONF_FILE"
  echo "Erzeugt: $CONF_FILE"
fi

# --- Docs mitgeben (Referenz auf dem Host) ---
if [[ -d "$SCRIPT_DIR/../docs" ]]; then
  copy_tree "$SCRIPT_DIR/../docs" "$INSTALL_HOME/docs"
  echo "Kopiert: docs/ -> $INSTALL_HOME/docs/"
fi

echo
echo "== Installation abgeschlossen =="
echo "Naechste Schritte:"
echo "  1. Trockenlauf:  sudo $INSTALL_HOME/backup.sh --dry-run"
echo "  2. Erstlauf:     sudo $INSTALL_HOME/backup.sh --service litellm"
echo "  3. Voller Lauf:  sudo $INSTALL_HOME/backup.sh"
echo "  Cron-Zeiten:     siehe $INSTALL_HOME/docs/DEPLOYMENT.md"
