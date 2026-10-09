#!/usr/bin/env bash
# install.sh — Installiert alle Host-Tools (backup + maintenance) nach /opt/docker/tools,
# unabhaengig vom Repo. Quelle (Compose-Stacks + .env) und Ziel (NAS) werden in
# /etc/backup.conf konfiguriert, nicht im Code.
# Bootstrap (bootstrap/compose.yml fuer Arcane) wird BEWUSST NICHT installiert:
# Die Compose enthaelt Secrets und wird von Hand gepflegt (siehe docs/DEPLOYMENT.md).
#
# Usage:
#   tools/install.sh [--home /opt/docker/tools] [--stacks-dir /pfad/zu/projects] [--backup-root /mnt/systems/backups/<host>]
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Version und Build (PR-Nummer) zum Installationszeitpunkt aus lib/common.sh uebernehmen
LIB_VERSION="$(grep -m1 '^SCRIPT_VERSION=' "$SCRIPT_DIR/backup/lib/common.sh" | cut -d= -f2 | tr -d '"')"
LIB_BUILD="$(grep -m1 '^SCRIPT_BUILD=' "$SCRIPT_DIR/backup/lib/common.sh" | cut -d= -f2 | tr -d '"')"
INSTALL_STAMP="$(date '+%Y-%m-%d %H:%M')"

TOOLS_HOME="/opt/docker/tools"
INSTALL_HOME="$TOOLS_HOME/backup"
MAINT_HOME="$TOOLS_HOME/maintenance"
STACKS_DIR="/opt/docker/arcane/projects"
BACKUP_ROOT="/mnt/systems/$(hostname)/backups"
CONF_FILE="/etc/backup.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)        shift; TOOLS_HOME="${1:?--home braucht Pfad}"; INSTALL_HOME="$TOOLS_HOME/backup"; MAINT_HOME="$TOOLS_HOME/maintenance" ;;
    --stacks-dir)  shift; STACKS_DIR="${1:?--stacks-dir braucht Pfad}" ;;
    --backup-root) shift; BACKUP_ROOT="${1:?--backup-root braucht Pfad}" ;;
    -h|--help)     sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "== Backup-System-Installation =="
echo "Heimat:      $TOOLS_HOME (backup + maintenance)"
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
mkdir -p "$INSTALL_HOME" "$MAINT_HOME" || { echo "FEHLER: Kann $TOOLS_HOME nicht anlegen" >&2; exit 1; }

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
copy_file "$SCRIPT_DIR/backup/backup.sh" "$INSTALL_HOME/"
copy_file "$SCRIPT_DIR/backup/restore.sh" "$INSTALL_HOME/"
copy_file "$SCRIPT_DIR/backup/test-restore.sh" "$INSTALL_HOME/"
copy_tree "$SCRIPT_DIR/backup/lib" "$INSTALL_HOME/lib"
copy_tree "$SCRIPT_DIR/backup/policies.d" "$INSTALL_HOME/policies.d" true
copy_file "$SCRIPT_DIR/backup/policy.conf" "$INSTALL_HOME/"
chmod +x "$INSTALL_HOME"/*.sh

# --- Maintenance-Tool mitinstallieren (gleiche Tools-Heimat, kein Bootstrap!) ---
if [[ -d "$SCRIPT_DIR/maintenance" ]]; then
  copy_tree "$SCRIPT_DIR/maintenance" "$MAINT_HOME" true
  chmod +x "$MAINT_HOME"/*.sh
  echo "Kopiert: maintenance -> $MAINT_HOME"
else
  echo "WARNUNG: ../maintenance nicht gefunden — Maintenance-Tool uebersprungen." >&2
fi

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

# --- Docs mitgeben (Referenz auf dem Host, gilt fuer alle Tools) ---
if [[ -d "$SCRIPT_DIR/../docs" ]]; then
  copy_tree "$SCRIPT_DIR/../docs" "$TOOLS_HOME/docs"
  echo "Kopiert: docs/ -> $TOOLS_HOME/docs/"
fi

echo
echo "== Installation abgeschlossen =="
echo "Naechste Schritte:"
echo "  1. Trockenlauf:  sudo $INSTALL_HOME/backup.sh --dry-run"
echo "  2. Erstlauf:     sudo $INSTALL_HOME/backup.sh --service litellm"
echo "  3. Voller Lauf:  sudo $INSTALL_HOME/backup.sh"
echo "  Cron-Zeiten:     siehe $TOOLS_HOME/docs/DEPLOYMENT.md"
