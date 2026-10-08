#!/usr/bin/env bash
# db.sh — DB-Dump-Helfer via docker exec. Wird von backup.sh gesources.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "db.sh ist eine Bibliothek, nicht direkt ausfuehren." >&2
  exit 1
fi

# Alle Helfer erwarten die Deklarationsvariablen (SVC_NAME, DB_TYPE, DB_CONTAINER,
# DB_USER, DB_NAME, DB_PASSWORD, DB_DUMP_EXTRA, SQLITE_FILES) und den Ziel-Pfad
# als $1. Rueckgabe 0 = Erfolg. Passwoerter werden nie auf Kommandozeilen
# uebergeben, sondern als Env an docker exec (nicht in der Prozessliste sichtbar).

dump_postgres() {
  local dest_dir="$1"
  local out="$dest_dir/${SVC_NAME}.sql.gz"
  # DB_DUMP_ALL=true -> pg_dumpall (kompletter Cluster inkl. globaler Objekte).
  # WICHTIG: pg_dump kennt KEIN --all — die Option gehoert zu pg_dumpall.
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
    log_dry "$SVC_NAME: wuerde ausfuehren: ${cmd[*]} | gzip > $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB-Container $DB_CONTAINER laeuft nicht"; return 1; }
  wait_for_postgres "$DB_CONTAINER" "$DB_USER" || return 1
  mkdir -p "$dest_dir"
  if "${cmd[@]}" 2>>"$LOG_FILE" | gzip > "$out" && [[ -s "$out" ]]; then
    log_ok "$SVC_NAME: pg_dump -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  log_fail "$SVC_NAME: pg_dump fehlgeschlagen oder leer"
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
  # Wenn DB_DUMP_EXTRA --databases nutzt, stehen die Schemas dort — DB_NAME nicht anhaengen
  if [[ "${DB_DUMP_EXTRA:-}" == *"--databases"* ]]; then db_args=""; fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: wuerde ausfuehren: docker exec [-e MYSQL_PWD] $DB_CONTAINER $dumper -u $DB_USER --single-transaction ${DB_DUMP_EXTRA:-} $db_args | gzip > $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: DB-Container $DB_CONTAINER laeuft nicht"; return 1; }
  mkdir -p "$dest_dir"
  if docker exec -e MYSQL_PWD="${DB_PASSWORD:-}" "$DB_CONTAINER" \
      "$dumper" -u "$DB_USER" --single-transaction --routines --triggers "${extra[@]}" $db_args \
      2>>"$LOG_FILE" | gzip > "$out" && [[ -s "$out" ]]; then
    log_ok "$SVC_NAME: $dumper -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  log_fail "$SVC_NAME: $dumper fehlgeschlagen oder leer"
  rm -f "$out"
  return 1
}

# SQLite via sqlite3 .backup (Online-Backup-API) im laufenden Container.
# SQLITE_FILES: ("host_db_datei:container_db_pfad")
dump_sqlite() {
  local dest_dir="$1"
  local entry host_path container_path out rc=0
  for entry in "${SQLITE_FILES[@]:-}"; do
    [[ -z "$entry" ]] && continue
    host_path="${entry%%:*}"
    container_path="${entry##*:}"
    out="$dest_dir/$(basename "$host_path").sqlite3"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "$SVC_NAME: wuerde sqlite3 .backup ausfuehren: $DB_CONTAINER:$container_path -> $out"
      continue
    fi
    container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: Container $DB_CONTAINER laeuft nicht (SQLite-Online-Backup braucht laufenden Container)"; rc=1; continue; }
    mkdir -p "$dest_dir"
    if docker exec "$DB_CONTAINER" sqlite3 "$container_path" ".backup /tmp/backup.sqlite" 2>>"$LOG_FILE" \
      && docker cp "$DB_CONTAINER:/tmp/backup.sqlite" "$out" >/dev/null 2>>"$LOG_FILE" \
      && docker exec "$DB_CONTAINER" rm -f /tmp/backup.sqlite; then
      log_ok "$SVC_NAME: sqlite .backup -> $out ($(du -h "$out" | cut -f1))"
    else
      # Fallback: Viele Images (z.B. vaultwarden) enthalten kein sqlite3-Binary.
      # Dann das Verzeichnis der DB per Hilfscontainer mit sqlite3-Image sichern.
      log_warn "$SVC_NAME: sqlite3 nicht im Container verfuegbar — nutze Hilfscontainer-Fallback"
      # Host-Pfad des Bind-Mounts ermitteln, der den DB-Ordner abbildet.
      # (Einfaches, robustes Parsing statt verschachtelter Go-Templates.)
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
        # Ein Hilfscontainer mit sqlite3-Image: liest die DB (ro) und schreibt
        # den konsistenten Snapshot direkt ins Zielverzeichnis (Online-Backup-API)
        if docker run --rm -v "$src_dir:/db:ro" -v "$dest_dir:/out" keinos/sqlite3:latest \
             sqlite3 "/db/$(basename "$container_path")" ".backup /out/$(basename "$host_path")" >>"$LOG_FILE" 2>&1 \
          && [[ -s "$out" ]]; then
          log_ok "$SVC_NAME: sqlite Fallback (Hilfscontainer) -> $out ($(du -h "$out" | cut -f1))"
        else
          log_fail "$SVC_NAME: sqlite .backup fehlgeschlagen fuer $container_path (auch Hilfscontainer-Fallback)"
          rc=1
        fi
      else
        log_fail "$SVC_NAME: sqlite .backup fehlgeschlagen fuer $container_path (kein Bind-Mount aufloesbar)"
        rc=1
      fi
      docker exec "$DB_CONTAINER" rm -f /tmp/backup.sqlite 2>/dev/null
    fi
  done
  return $rc
}

# Forgejo: konsistenter Gesamt-Dump (DB+Config) via forgejo/gitea dump.
dump_forgejo() {
  local dest_dir="$1"
  local out="$dest_dir/${SVC_NAME}-dump.zip"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: wuerde ausfuehren: docker exec --user git $DB_CONTAINER forgejo dump --skip-repository [${DB_DUMP_EXTRA:-}] -> $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: Forgejo-Container laeuft nicht"; return 1; }
  mkdir -p "$dest_dir"
  local binary
  if docker exec "$DB_CONTAINER" sh -c 'command -v forgejo >/dev/null 2>&1'; then binary=forgejo; else binary=gitea; fi
  # --skip-repository: Repos werden per rsync gesichert (FILE_PATHS) — sonst
  # waere der Dump (~15G inkl. Mirrors) eine Doppelung. DB_DUMP_EXTRA kann die
  # Option fuer Einzelfaelle ueberschreiben (z.B. voller Dump gewuenscht).
  local -a skip_repo=(--skip-repository)
  if [[ "${DB_DUMP_EXTRA:-}" == *full* ]]; then skip_repo=(); fi
  if docker exec --user git "$DB_CONTAINER" "$binary" dump "${skip_repo[@]}" --tempdir /tmp --type zip --file /tmp/forgejo-dump.zip 2>>"$LOG_FILE" \
    && docker cp "$DB_CONTAINER:/tmp/forgejo-dump.zip" "$out" >/dev/null 2>>"$LOG_FILE" \
    && docker exec "$DB_CONTAINER" rm -f /tmp/forgejo-dump.zip; then
    log_ok "$SVC_NAME: $binary dump -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  log_fail "$SVC_NAME: $binary dump fehlgeschlagen"
  docker exec "$DB_CONTAINER" rm -f /tmp/forgejo-dump.zip 2>/dev/null
  rm -f "$out"
  return 1
}

# SurrealDB: konsistenter Export via surreal export.
dump_surreal() {
  local dest_dir="$1"
  local out="$dest_dir/${SVC_NAME}.surql"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$SVC_NAME: wuerde ausfuehren: docker exec $DB_CONTAINER surreal export --conn ${DB_CONN:-rocksdb:/mydata} -f /tmp/export.surql -> $out"
    return 0
  fi
  container_running "$DB_CONTAINER" || { log_fail "$SVC_NAME: SurrealDB-Container laeuft nicht"; return 1; }
  mkdir -p "$dest_dir"
  if docker exec "$DB_CONTAINER" surreal export --conn "${DB_CONN:-rocksdb:/mydata}" \
      --user "${DB_USER:-root}" --pass "${DB_PASSWORD:-root}" -f /tmp/export.surql 2>>"$LOG_FILE" \
    && docker cp "$DB_CONTAINER:/tmp/export.surql" "$out" >/dev/null 2>>"$LOG_FILE" \
    && docker exec "$DB_CONTAINER" rm -f /tmp/export.surql; then
    log_ok "$SVC_NAME: surreal export -> $out ($(du -h "$out" | cut -f1))"
    return 0
  fi
  log_fail "$SVC_NAME: surreal export fehlgeschlagen"
  docker exec "$DB_CONTAINER" rm -f /tmp/export.surql 2>/dev/null
  rm -f "$out"
  return 1
}

# Dispatch nach DB_TYPE
dump_database() {
  local dest_dir="$1"
  case "${DB_TYPE:-}" in
    postgres)  dump_postgres "$dest_dir" ;;
    mysql|mariadb) dump_mysql "$dest_dir" ;;
    sqlite)    dump_sqlite "$dest_dir" ;;
    forgejo)   dump_forgejo "$dest_dir" ;;
    surreal)   dump_surreal "$dest_dir" ;;
    "")        log_fail "$SVC_NAME: DB-Dump angefordert, aber DB_TYPE ist leer"; return 1 ;;
    *)         log_fail "$SVC_NAME: unbekannter DB_TYPE '$DB_TYPE'"; return 1 ;;
  esac
}
