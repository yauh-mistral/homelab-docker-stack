#!/usr/bin/env bash
# db.sh — DB dump helpers via docker exec. Sourced by backup.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "db.sh is a library, do not execute directly." >&2
  exit 1
fi

# All helpers expect the declaration variables (SVC_NAME, DB_TYPE, DB_CONTAINER,
# DB_USER, DB_NAME, DB_PASSWORD, DB_DUMP_EXTRA, SQLITE_FILES) and the target
# path as $1. Return 0 = success. Passwords are never passed on command lines
# but as env to docker exec (not visible in the process list).

dump_postgres() {
  local dest_dir="$1"
  local out="$dest_dir/${SVC_NAME}.sql.gz"
  # DB_DUMP_ALL=true -> pg_dumpall (whole cluster including global objects).
  # IMPORTANT: pg_dump has NO --all — that option belongs to pg_dumpall.
  local -a cmd=(docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER")
  if [[ "${DB_DUMP_ALL:-false}" == "true" ]]; then
    cmd=(docker exec "$DB_CONTAINER" pg_dumpall -U "$DB_USER")
  else
    cmd+=(--dbname "$DB_NAME")
  fi
  local -a extra=()
  [[ -n "${DB_DUMP_EXTRA:-}" ]] && read -r -a extra <<< "$DB_DUMP_EXTRA"
  cmd+=("${extra[@]}")
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: would run: ${cmd[*]} | gzip > $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB container $DB_CONTAINER is not running"; return 1; }
  wait_for_postgres "$DB_CONTAINER" "$DB_USER" || return 1
  mkdir -p "$dest_dir"
  if "${cmd[@]}" 2>>"$LOG_FILE" | gzip > "$out" && [[ -s "$out" ]]; then
    log_ok "$SVC_NAME: pg_dump -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  log_fail "$SVC_NAME: pg_dump failed or empty"
  rm -f "$out"
  return 1
}

dump_mysql() {
  local dest_dir="$1"
  local out="$dest_dir/${SVC_NAME}.sql.gz"
  local dumper="mysqldump"
  docker exec "$DB_CONTAINER" sh -c 'command -v mysqldump >/dev/null 2>&1' || dumper="mariadb-dump"
  local db_args="${DB_NAME:-}"
  local -a extra=()
  [[ -n "${DB_DUMP_EXTRA:-}" ]] && read -r -a extra <<< "$DB_DUMP_EXTRA"
  # If DB_DUMP_EXTRA uses --databases, the schemas are declared there — do not append DB_NAME
  if [[ "${DB_DUMP_EXTRA:-}" == *"--databases"* ]]; then db_args=""; fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: would run: docker exec [-e MYSQL_PWD] $DB_CONTAINER $dumper -u $DB_USER --single-transaction ${DB_DUMP_EXTRA:-} $db_args | gzip > $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB container $DB_CONTAINER is not running"; return 1; }
  mkdir -p "$dest_dir"
  if docker exec -e MYSQL_PWD="${DB_PASSWORD:-}" "$DB_CONTAINER" \
      "$dumper" -u "$DB_USER" --single-transaction --routines --triggers "${extra[@]}" $db_args \
      2>>"$LOG_FILE" | gzip > "$out" && [[ -s "$out" ]]; then
    log_ok "$SVC_NAME: $dumper -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  log_fail "$SVC_NAME: $dumper failed or empty"
  rm -f "$out"
  return 1
}

# SQLite via sqlite3 .backup (online backup API) in the running container.
# SQLITE_FILES: ("host_db_file:container_db_path")
dump_sqlite() {
  local dest_dir="$1"
  local entry host_path container_path out rc=0
  for entry in "${SQLITE_FILES[@]:-}"; do
    [[ -z "$entry" ]] && continue
    host_path="${entry%%:*}"
    container_path="${entry##*:}"
    out="$dest_dir/$(basename "$host_path").sqlite3"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: would run sqlite3 .backup: $DB_CONTAINER:$container_path -> $out"
      continue
    fi
    container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: container $DB_CONTAINER is not running (SQLite online backup needs a running container)"; rc=1; continue; }
    mkdir -p "$dest_dir"
    if docker exec "$DB_CONTAINER" sqlite3 "$container_path" ".backup /tmp/backup.sqlite" 2>>"$LOG_FILE" \
      && docker cp "$DB_CONTAINER:/tmp/backup.sqlite" "$out" >/dev/null 2>>"$LOG_FILE" \
      && docker exec "$DB_CONTAINER" rm -f /tmp/backup.sqlite; then
      log_ok "$SVC_NAME: sqlite .backup -> $out ($(du -h "$out" | cut -f1))"
    else
      # Fallback: many images (e.g. vaultwarden) do not contain a sqlite3 binary.
      # Then back up the DB directory via a helper container with a sqlite3 image.
      log_warn "$SVC_NAME: sqlite3 not available in the container — using helper container fallback"
      # Determine the host path of the bind mount that maps the DB directory.
      # (Simple, robust parsing instead of nested Go templates.)
      local src_dir=""
      local _m _src _dst
      while IFS= read -r _m; do
        [[ -z "$_m" ]] && continue
        _src="${_m%%|*}"; _dst="${_m##*|}"
        if [[ "$_dst" == "$(dirname "$container_path")" ]]; then
          src_dir="$_src"
          break
        fi
      done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{printf "%s|%s\n" .Source .Destination}}{{end}}{{end}}' "$DB_CONTAINER" 2>>"$LOG_FILE")
      if [[ -n "$src_dir" && -d "$src_dir" ]]; then
        # A helper container with a sqlite3 image: reads the DB (ro) and writes
        # the consistent snapshot directly to the target directory (online backup API)
        if docker run --rm -v "$src_dir:/db:ro" -v "$dest_dir:/out" keinos/sqlite3:latest \
             sqlite3 "/db/$(basename "$container_path")" ".backup /out/$(basename "$out")" >>"$LOG_FILE" 2>&1 \
          && [[ -s "$out" ]]; then
          log_ok "$SVC_NAME: sqlite fallback (helper container) -> $out ($(du -h "$out" | cut -f1))"
        else
          log_fail "$SVC_NAME: sqlite .backup failed for $container_path (helper container fallback also failed)"
          rc=1
        fi
      else
        log_fail "$SVC_NAME: sqlite .backup failed for $container_path (no bind mount resolvable)"
        rc=1
      fi
      docker exec "$DB_CONTAINER" rm -f /tmp/backup.sqlite 2>/dev/null
    fi
  done
  return $rc
}

# Forgejo: consistent full dump (DB+config) via forgejo/gitea dump.
dump_forgejo() {
  local dest_dir="$1"
  local out="$dest_dir/${SVC_NAME}-dump.zip"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: would run: docker exec --user git $DB_CONTAINER forgejo dump --skip-repository ${DB_DUMP_EXTRA:+[$DB_DUMP_EXTRA]} -> $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: Forgejo container is not running"; return 1; }
  mkdir -p "$dest_dir"
  local binary
  if docker exec "$DB_CONTAINER" sh -c 'command -v forgejo >/dev/null 2>&1'; then binary=forgejo; else binary=gitea; fi
  # --skip-repository: repos are backed up via rsync (FILE_PATHS) — otherwise
  # the dump (~15G incl. mirrors) would be a duplicate. DB_DUMP_EXTRA can
  # override the option for special cases (e.g. a full dump is wanted).
  local -a skip_repo=(--skip-repository)
  if [[ "${DB_DUMP_EXTRA:-}" == *full* ]]; then skip_repo=(); fi
  local dumptmp=""
  [[ -n "${LOG_FILE:-}" ]] && dumptmp="$(mktemp)"
  if { docker exec --user git "$DB_CONTAINER" "$binary" dump "${skip_repo[@]}" --tempdir /tmp --type zip --file /tmp/forgejo-dump.zip 2>"${dumptmp:-/dev/null}"; \
       docker cp "$DB_CONTAINER:/tmp/forgejo-dump.zip" "$out" >/dev/null 2>>"${dumptmp:-/dev/null}"; } \
    && docker exec "$DB_CONTAINER" rm -f /tmp/forgejo-dump.zip; then
    [[ -n "$dumptmp" && -s "$dumptmp" ]] && tee_ext "$SVC_NAME" <"$dumptmp" >>"$LOG_FILE"
    rm -f "${dumptmp:-/dev/null}" 2>/dev/null
    log_ok "$SVC_NAME: $binary dump -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  [[ -n "$dumptmp" && -s "$dumptmp" ]] && tee_ext "$SVC_NAME" <"$dumptmp" >>"$LOG_FILE"
  rm -f "${dumptmp:-/dev/null}" 2>/dev/null
  log_fail "$SVC_NAME: $binary dump failed"
  docker exec "$DB_CONTAINER" rm -f /tmp/forgejo-dump.zip 2>/dev/null
  rm -f "$out"
  return 1
}

# SurrealDB: consistent export via surreal export.
dump_surreal() {
  local dest_dir="$1"
  local out="$dest_dir/${SVC_NAME}.surql"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: would run: docker exec $DB_CONTAINER surreal export --conn ${DB_CONN:-rocksdb:/mydata} -f /tmp/export.surql -> $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: SurrealDB container is not running"; return 1; }
  mkdir -p "$dest_dir"
  if docker exec "$DB_CONTAINER" surreal export --conn "${DB_CONN:-rocksdb:/mydata}" \
      --user "${DB_USER:-root}" --pass "${DB_PASSWORD:-root}" -f /tmp/export.surql 2>>"$LOG_FILE" \
    && docker cp "$DB_CONTAINER:/tmp/export.surql" "$out" >/dev/null 2>>"$LOG_FILE" \
    && docker exec "$DB_CONTAINER" rm -f /tmp/export.surql; then
    log_ok "$SVC_NAME: surreal export -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  log_fail "$SVC_NAME: surreal export failed"
  docker exec "$DB_CONTAINER" rm -f /tmp/export.surql 2>/dev/null
  rm -f "$out"
  return 1
}

# Dispatch by DB_TYPE
dump_database() {
  local dest_dir="$1"
  case "${DB_TYPE:-}" in
    postgres)  dump_postgres "$dest_dir" ;;
    mysql|mariadb) dump_mysql "$dest_dir" ;;
    sqlite)    dump_sqlite "$dest_dir" ;;
    forgejo)   dump_forgejo "$dest_dir" ;;
    surreal)   dump_surreal "$dest_dir" ;;
    "")        log_fail "$SVC_NAME: DB dump requested but DB_TYPE is empty"; return 1 ;;
    *)         log_fail "$SVC_NAME: unknown DB_TYPE '$DB_TYPE'"; return 1 ;;
  esac
}
