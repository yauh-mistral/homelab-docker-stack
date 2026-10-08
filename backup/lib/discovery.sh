#!/usr/bin/env bash
# discovery.sh — Auto-Discovery: laufende Container → Backup-Einheiten.
# Die Wahrheit (Services, Mounts, DB-Credentials) lebt in Docker bzw. in den
# Compose-Stacks — nicht in statischen Deklarationen. Diese Bibliothek leitet
# pro Container ab:
#   - Projekt (compose-Label), Image, Bind-Mount-Host-Pfade
#   - DB-Typ + Credentials aus den Container-ENV (POSTGRES_*/MYSQL_*/MARIADB_*)
#   - Kategorie (db_only/files_only/db_and_files/ignore/none)
# Überschrieben/ergänzt wird das durch Policies (policies.d/, policy.conf).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "discovery.sh ist eine Bibliothek, nicht direkt ausfuehren." >&2
  exit 1
fi

# --- Container-Helfer ---
svc_label() {
  local c="${1:?Container fehlt}" key="${2:?Label-Key fehlt}"
  docker inspect -f "{{index .Config.Labels \"$key\"}}" "$c" 2>/dev/null
}

svc_env() {
  # ENV-Wert eines Containers (aus Config.Env, nie von der Kommandozeile)
  local c="${1:?Container fehlt}" var="${2:?Variable fehlt}"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null \
    | grep -m1 "^${var}=" | cut -d= -f2-
}

svc_mounts() {
  # Alle Bind-Mount-Quellen (Host-Pfade) eines Containers, zeilenweise
  local c="${1:?Container fehlt}"
  docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' "$c" 2>/dev/null
}

svc_mount_dest_for() {
  # Host-Verzeichnis, das den Container-Pfad $2 abbildet (Mount-Source), oder leer
  local c="${1:?Container fehlt}" container_path="${2:?Container-Pfad fehlt}"
  local wanted_dir entry src dst
  wanted_dir="$(dirname "$container_path")"
  while IFS='|' read -r entry; do
    [[ -z "$entry" ]] && continue
    src="${entry%%|*}"; dst="${entry##*|}"
    [[ "$dst" == "$wanted_dir" ]] && { echo "$src"; return 0; }
  done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{printf "%s|%s\n" .Source .Destination}}{{end}}{{end}}' "$c" 2>/dev/null)
  return 1
}

path_is_ignored() {
  # True wenn Pfad NICHT unter einem erlaubten Praefix liegt (Allowlist).
  # Erlaubt ist nur /opt/docker/* — alles andere (NAS /mnt, Download-Staging
  # /opt/downloads, OS-Runtime, Container-interne Pfade) wird nie gesichert.
  local p="${1:?Pfad fehlt}" pre
  for pre in "${ALLOW_PATH_PREFIXES[@]:-}"; do
    [[ -z "$pre" ]] && continue
    [[ "$p" == "$pre"* || "$p" == "$pre" ]] && return 1
  done
  return 0
}

# --- Policy-Overlay: Projekt-Defaults, dann Container-Spezifika ---
apply_policy() {
  local f
  # Reihenfolge: policy.conf (Defaults) ist bereits gesourced;
  # zuerst Projekt-Policy, dann Container-Policy (gewinnt).
  for f in "$POLICY_DIR/${SVC_PROJECT:-}.project.env" "$POLICY_DIR/${SVC_NAME}.env"; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

# Lädt alles für einen Container in die SVC_*-Variablen.
# setzt: SVC_NAME, SVC_PROJECT, SVC_IMAGE, SVC_CATEGORY, DB_*, FILE_PATHS,
#        FILE_EXCLUDES, SQLITE_FILES, STOP_CONTAINERS, STOP_SELF, EXTRA_*.
load_service_env() {
  local c="${1:?Container fehlt}"
  SVC_NAME="$c"
  SVC_PROJECT="$(svc_label "$c" com.docker.compose.project)"
  SVC_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)"
  SVC_IGNORE=false
  SVC_CATEGORY="none"
  DB_TYPE="" DB_CONTAINER="$c" DB_USER="" DB_NAME="" DB_PASSWORD="" DB_DUMP_ALL=""
  DB_DUMP_EXTRA="" DB_DUMP_ALL="" DB_PASSWORD_VAR="" ENV_FILE=""
  FILE_PATHS=() FILE_EXCLUDES=() SQLITE_FILES=() STOP_CONTAINERS=()
  KEEP_FILES=false
  local -a EXTRA_FILE_PATHS=() EXTRA_FILE_EXCLUDES=()

  # --- DB-Auto-Detect: erst Container-ENV (zuverlaessig), dann Image-Name ---
  local pg_user pg_db my_root my_db ma_root ma_db
  pg_user="$(svc_env "$c" POSTGRES_USER)"
  pg_db="$(svc_env "$c" POSTGRES_DB)"
  my_root="$(svc_env "$c" MYSQL_ROOT_PASSWORD)"
  ma_root="$(svc_env "$c" MARIADB_ROOT_PASSWORD)"
  my_db="$(svc_env "$c" MYSQL_DATABASE)"
  ma_db="$(svc_env "$c" MARIADB_DATABASE)"
  if [[ -n "$pg_user$pg_db" || "$SVC_IMAGE" == *postgres* ]]; then
    DB_TYPE=postgres
    DB_USER="${pg_user:-postgres}"
    DB_NAME="${pg_db:-$DB_USER}"
  elif [[ -n "$my_root$ma_root" || "$SVC_IMAGE" == *mariadb* || "$SVC_IMAGE" == *mysql* ]]; then
    if [[ "$SVC_IMAGE" == *mariadb* ]]; then DB_TYPE=mariadb; else DB_TYPE=mysql; fi
    # Dump als Root: App-User haben haeufig nicht noetige Privilegien
    # (Ghost/MySQL 9: FLUSH TABLES braucht RELOAD, nur Root hat es).
    DB_USER=root
    DB_PASSWORD="${ma_root:-$my_root}"
    DB_NAME="${ma_db:-$my_db}"
  fi

  # --- Datei-Kandidaten: Bind-Mounts, gefiltert ---
  local src
  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    [[ -e "$src" ]] || continue
    path_is_ignored "$src" && continue
    FILE_PATHS+=("$src")
  done < <(svc_mounts "$c")

  # --- Policy-Overlay (Projekt + Container) ---
  apply_policy
  FILE_EXCLUDES+=("${DEFAULT_FILE_EXCLUDES[@]:-}")
  local e
  for e in "${EXTRA_FILE_EXCLUDES[@]:-}"; do
    [[ -n "$e" ]] && FILE_EXCLUDES+=("$e")
  done
  for e in "${EXTRA_FILE_PATHS[@]:-}"; do
    [[ -n "$e" ]] && FILE_PATHS+=("$e")
  done

  # DB-Container (postgres/mysql/mariadb): Rohdaten-Verzeichnis NICHT
  # file-sichern (inkonsistent im Lauf) — die DB wird per Dump gesichert.
  # KEEP_FILES=true (Policy) erzwingt Datei-Backup zusaetzlich.
  # SQLite/Forgejo ausgenommen: dort liegt im Mount die App-Queue/Config.
  case "$DB_TYPE" in
    postgres|mysql|mariadb)
      if [[ "$KEEP_FILES" != "true" ]]; then
        FILE_PATHS=()
      fi
      ;;
  esac

  # Stop-Fenster: Policy-Container + optional der Container selbst
  if [[ "${STOP_SELF:-false}" == "true" ]]; then
    STOP_CONTAINERS+=("$SVC_NAME")
  fi

  # --- Kategorie ableiten ---
  if [[ "${SVC_IGNORE:-}" == "true" ]]; then
    SVC_CATEGORY=ignore
  elif [[ -n "$DB_TYPE" && ${#FILE_PATHS[@]} -gt 0 ]]; then
    SVC_CATEGORY=db_and_files
  elif [[ -n "$DB_TYPE" ]]; then
    SVC_CATEGORY=db_only
  elif [[ ${#FILE_PATHS[@]} -gt 0 || ${#SQLITE_FILES[@]} -gt 0 ]]; then
    SVC_CATEGORY=files_only
  else
    SVC_CATEGORY=none  # laeuft, aber nichts zu sichern (Cache, Proxy, ...)
  fi
  return 0
}

# Alle laufenden Container (deterministisch sortiert)
discover_containers() {
  docker ps --format '{{.Names}}' | sort
}
