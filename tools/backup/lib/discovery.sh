#!/usr/bin/env bash
# discovery.sh — auto-discovery: running containers → backup units.
# The truth (services, mounts, DB credentials) lives in Docker and in the
# compose stacks — not in static declarations. This library derives per container:
#   - project (compose label), image, bind-mount host paths
#   - DB type + credentials from the container env (POSTGRES_*/MYSQL_*/MARIADB_*)
#   - category (db_only/files_only/db_and_files/ignore/none)
# This is overridden/extended by policies (policies.d/, policy.conf).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "discovery.sh is a library, do not execute directly." >&2
  exit 1
fi

# --- Container helpers ---
svc_label() {
  local c="${1:?container missing}" key="${2:?label key missing}"
  docker inspect -f "{{index .Config.Labels \"$key\"}}" "$c" 2>/dev/null
}

svc_env() {
  # Env value of a container (from Config.Env, never from the command line)
  local c="${1:?container missing}" var="${2:?variable missing}"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null \
    | grep -m1 "^${var}=" | cut -d= -f2-
}

svc_mounts() {
  # All bind-mount sources (host paths) of a container, line by line
  local c="${1:?container missing}"
  docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' "$c" 2>/dev/null
}

svc_mount_dest_for() {
  # Host directory that maps the container path $2 (mount source), or empty
  local c="${1:?container missing}" container_path="${2:?container path missing}"
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
  # True if the path is NOT under an allowed prefix (allowlist).
  # Only /opt/docker/* is allowed — everything else (NAS /mnt, download staging
  # /opt/downloads, OS runtime, container-internal paths) is never backed up.
  local p="${1:?path missing}" pre
  for pre in "${ALLOW_PATH_PREFIXES[@]:-}"; do
    [[ -z "$pre" ]] && continue
    [[ "$p" == "$pre"* || "$p" == "$pre" ]] && return 1
  done
  return 0
}

# --- Policy overlay: project defaults first, then container specifics ---
apply_policy() {
  local f
  # Order: policy.conf (defaults) is already sourced;
  # First the project policy, then the container policy (wins).
  for f in "$POLICY_DIR/${SVC_PROJECT:-}.project.env" "$POLICY_DIR/${SVC_NAME}.env"; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

# Loads everything for a container into the SVC_* variables.
# sets: SVC_NAME, SVC_PROJECT, SVC_IMAGE, SVC_CATEGORY, DB_*, FILE_PATHS,
#        FILE_EXCLUDES, SQLITE_FILES, STOP_CONTAINERS, STOP_SELF, EXTRA_*.
load_service_env() {
  local c="${1:?container missing}"
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

  # --- DB auto-detect: container env first (reliable), then image name ---
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
    # Dump as root: app users often lack required privileges
    # (Ghost/MySQL 9: FLUSH TABLES needs RELOAD, only root has it).
    DB_USER=root
    DB_PASSWORD="${ma_root:-$my_root}"
    DB_NAME="${ma_db:-$my_db}"
  fi

  # --- File candidates: bind mounts, filtered ---
  local src bn
  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    [[ -e "$src" ]] || continue
    path_is_ignored "$src" && continue
    bn="$(basename "$src")"
    local skip=false sb
    for sb in "${SKIP_MOUNT_BASENAMES[@]:-}"; do
      [[ -z "$sb" ]] && continue
      [[ "$bn" == "$sb" ]] && skip=true
    done
    [[ "$skip" == "true" ]] && continue
    FILE_PATHS+=("$src")
  done < <(svc_mounts "$c")

  # --- Policy overlay (project + container) ---
  apply_policy
  FILE_EXCLUDES+=("${DEFAULT_FILE_EXCLUDES[@]:-}")
  local e
  for e in "${EXTRA_FILE_EXCLUDES[@]:-}"; do
    [[ -n "$e" ]] && FILE_EXCLUDES+=("$e")
  done
  for e in "${EXTRA_FILE_PATHS[@]:-}"; do
    [[ -n "$e" ]] && FILE_PATHS+=("$e")
  done

  # DB containers (postgres/mysql/mariadb): do NOT back up the raw data
  # directory as files (inconsistent while running) — the DB is backed up via dump.
  # KEEP_FILES=true (policy) additionally forces a file backup.
  # SQLite/Forgejo exempt: their mounts hold app queues/config.
  case "$DB_TYPE" in
    postgres|mysql|mariadb)
      if [[ "$KEEP_FILES" != "true" ]]; then
        FILE_PATHS=()
      fi
      ;;
  esac

  # Stop window: policy containers + optionally the container itself
  if [[ "${STOP_SELF:-false}" == "true" ]]; then
    STOP_CONTAINERS+=("$SVC_NAME")
  fi

  # --- Derive the category ---
  if [[ "${SVC_IGNORE:-}" == "true" ]]; then
    SVC_CATEGORY=ignore
  elif [[ -n "$DB_TYPE" && ${#FILE_PATHS[@]} -gt 0 ]]; then
    SVC_CATEGORY=db_and_files
  elif [[ -n "$DB_TYPE" ]]; then
    SVC_CATEGORY=db_only
  elif [[ ${#FILE_PATHS[@]} -gt 0 || ${#SQLITE_FILES[@]} -gt 0 ]]; then
    SVC_CATEGORY=files_only
  else
    SVC_CATEGORY=none  # running, but nothing to back up (cache, proxy, ...)
  fi
  return 0
}

# All running containers (deterministically sorted)
discover_containers() {
  docker ps --format '{{.Names}}' | sort
}
