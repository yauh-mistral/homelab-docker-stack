#!/usr/bin/env bash
# install.sh — Installs all host tools (backup + maintenance) to /opt/docker/tools,
# independent of the repo. Source (compose stacks + .env) and target (NAS) are
# configured in /etc/backup.conf, not in the code.
# The bootstrap (bootstrap/compose.yml for Arcane) is DELIBERATELY NOT installed:
# the compose file contains secrets and is maintained by hand (see docs/DEPLOYMENT.md).
#
# Usage:
#   tools/install.sh [--home /opt/docker/tools] [--stacks-dir /path/to/projects] [--backup-root /mnt/systems/backups/<host>]
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read version and build (PR number) at installation time from lib/common.sh
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
    --home)        shift; TOOLS_HOME="${1:?--home requires a path}"; INSTALL_HOME="$TOOLS_HOME/backup"; MAINT_HOME="$TOOLS_HOME/maintenance" ;;
    --stacks-dir)  shift; STACKS_DIR="${1:?--stacks-dir requires a path}" ;;
    --backup-root) shift; BACKUP_ROOT="${1:?--backup-root requires a path}" ;;
    -h|--help)     sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "== Backup system installation =="
echo "Home:        $TOOLS_HOME (backup + maintenance)"
echo "Source:      ${STACKS_DIR:-<interactive prompt>}"
echo "Target (NAS): $BACKUP_ROOT"
echo "Config:      $CONF_FILE"
echo

# --- Validate / prompt for inputs ---
if [[ -z "$STACKS_DIR" ]]; then
  read -r -p "Path to the compose stacks (projects/, contains the .env files): " STACKS_DIR
fi
[[ -d "$STACKS_DIR" ]] || { echo "ERROR: source directory does not exist: $STACKS_DIR" >&2; exit 1; }
[[ -f "$STACKS_DIR/ghost/compose.yaml" || -f "$STACKS_DIR/ghost/docker-compose.yml" ]] \
  || echo "WARNING: $STACKS_DIR does not look like the projects/ directory (no ghost stack found) — continuing anyway."

# --- Create the target directories ---
mkdir -p "$INSTALL_HOME" "$MAINT_HOME" || { echo "ERROR: cannot create $TOOLS_HOME" >&2; exit 1; }

# --- Copy files (idempotent; rsync if available, cp fallback otherwise) ---
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
      echo "WARNING: rsync not available — --delete (mirror) skipped." >&2
      echo "         Please reconcile $dest with the repo state manually." >&2
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

# --- Also install the maintenance tool (same tools home, no bootstrap!) ---
if [[ -d "$SCRIPT_DIR/maintenance" ]]; then
  copy_tree "$SCRIPT_DIR/maintenance" "$MAINT_HOME" true
  chmod +x "$MAINT_HOME"/*.sh
  echo "Copied: maintenance -> $MAINT_HOME"
else
  echo "WARNING: ../maintenance not found — maintenance tool skipped." >&2
fi

# Write the installation time and build (PR number) into the installed copy of
# lib/common.sh so that every backup/restore log reports version + patch level +
# install time.
sed -i "s|^INSTALL_STAMP=\"\${INSTALL_STAMP:-.*}\"|INSTALL_STAMP=\"$INSTALL_STAMP\"|" \
  "$INSTALL_HOME/lib/common.sh" || true
sed -i "s|^SCRIPT_BUILD=\"\${SCRIPT_BUILD:-.*}\"|SCRIPT_BUILD=\"$LIB_BUILD\"|" \
  "$INSTALL_HOME/lib/common.sh" || true
echo "Copied: backup.sh, restore.sh, test-restore.sh, lib/, policies.d/, policy.conf -> $INSTALL_HOME (version ${LIB_VERSION}${LIB_BUILD:+ +#$LIB_BUILD}, installed $INSTALL_STAMP)"

# --- Write config (never overwrite an existing file, only add missing entries) ---
if [[ -f "$CONF_FILE" ]]; then
  echo "Note: $CONF_FILE already exists — checking entries:"
  missing=()
  grep -q "^STACKS_DIR=" "$CONF_FILE" || missing+=("STACKS_DIR=$STACKS_DIR")
  grep -q "^BACKUP_ROOT=" "$CONF_FILE" || missing+=("BACKUP_ROOT=$BACKUP_ROOT")
  grep -q "^POLICY_DIR=" "$CONF_FILE" || missing+=("POLICY_DIR=$INSTALL_HOME/policies.d")
  # Fix an orphaned POLICY_DIR (path no longer exists, e.g. from an old installation)
  old_policy_dir="$(grep -m1 '^POLICY_DIR=' "$CONF_FILE" | cut -d= -f2-)"
  if [[ -n "$old_policy_dir" && ! -d "$old_policy_dir" ]]; then
    sed -i "s|^POLICY_DIR=.*|POLICY_DIR=$INSTALL_HOME/policies.d|" "$CONF_FILE"
    echo "Fixed: POLICY_DIR $old_policy_dir does not exist -> $INSTALL_HOME/policies.d"
  fi
  grep -q "^KEEP_VERSIONS=" "$CONF_FILE" || missing+=("KEEP_VERSIONS=14")
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}" >> "$CONF_FILE"
    echo "Added: ${missing[*]}"
  fi
else
  cat > "$CONF_FILE" <<EOF
# Backup configuration (generated by install.sh) — source, target, policy home
# Source: compose stacks including their .env files (for DB passwords via ENV_FILE)
STACKS_DIR=$STACKS_DIR
# Target: NAS mount (the dispatcher refuses to start if not mounted)
BACKUP_ROOT=$BACKUP_ROOT
# Home of the policy overlays (installed copy, independent of the repo)
POLICY_DIR=$INSTALL_HOME/policies.d
# Optional: restic (only enable once restic is installed + password file exists)
USE_RESTIC=false
# RESTIC_PASSWORD_FILE=/etc/restic-password
# Number of retained versions (rsnapshot-style rotation v.0..v.KEEP_VERSIONS-1)
KEEP_VERSIONS=14
EOF
  chmod 600 "$CONF_FILE"
  echo "Created: $CONF_FILE"
fi

# --- Also install the docs (reference on the host, applies to all tools) ---
if [[ -d "$SCRIPT_DIR/../docs" ]]; then
  copy_tree "$SCRIPT_DIR/../docs" "$TOOLS_HOME/docs"
  echo "Copied: docs/ -> $TOOLS_HOME/docs/"
fi

echo
echo "== Installation complete =="
echo "Next steps:"
echo "  1. Dry run:      sudo $INSTALL_HOME/backup.sh --dry-run"
echo "  2. First run:    sudo $INSTALL_HOME/backup.sh --service <container-name>"
echo "  3. Full run:     sudo $INSTALL_HOME/backup.sh"
echo "  Cron schedule:   see $TOOLS_HOME/docs/DEPLOYMENT.md"
