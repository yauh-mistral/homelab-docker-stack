#!/usr/bin/env bash
# test-restore.sh — Restore-Test: spielt die DB-Dumps aller entdeckten Services
# in Wegwerf-Container ein und prueft, dass Tabellen angelegt wurden.
# Testet die Dump-Methode (nicht die Produktivdaten). Produktiv-DB wird nicht beruehrt.
#
# Usage:
#   test-restore.sh                 # testet alle DB-Services (postgres + mysql/mariadb)
#   test-restore.sh <service>       # testet nur den genannten Service (Container-Name)
#   test-restore.sh --dry-run       # zeigt nur, welche Services getestet wuerden
#
# Konsistent zu backup.sh: ohne Filter = alles, Einzelauswahl via Argument.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/discovery.sh
source "$SCRIPT_DIR/lib/discovery.sh"

if [[ -f /etc/backup.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/backup.conf
fi

log_info "Version ($(version_string))"

TEST_IMAGE_PG="${TEST_IMAGE:-postgres:16-alpine}"
TEST_IMAGE_MY="${TEST_IMAGE_MYSQL:-mariadb:11}"
TESTNET="backup-restore-test"
TEST_PG_NAME="backup-restore-test-pg"
TEST_MY_NAME="backup-restore-test-my"
DRY_RUN_TEST=false
SINGLE=""

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN_TEST=true
elif [[ -n "${1:-}" ]]; then
  SINGLE="$1"
fi

# --- Ziele sammeln: alle Services mit DB-Dump (Default) oder genau einer ---
declare -A TARGETS=()
while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  load_service_env "$c"
  case "${DB_TYPE:-}" in
    postgres|mysql|mariadb) TARGETS["$SVC_NAME"]="$c" ;;
  esac
done < <(discover_containers)

if [[ -n "$SINGLE" ]]; then
  if [[ -z "${TARGETS[$SINGLE]+_}" ]]; then
    log_fail "$SINGLE: kein DB-Service mit diesem Namen entdeckt (Container-Name erwartet, Backups mit DB_TYPE postgres/mysql/mariadb)"
    exit 1
  fi
  # Nur den gewuenschten Service behalten
  for k in "${!TARGETS[@]}"; do [[ "$k" != "$SINGLE" ]] && unset 'TARGETS[$k]'; done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  log_fail "Keine DB-Services entdeckt — Restore-Test ohne Ziele abgebrochen (kein falsch-positives OK)"
  exit 1
fi

log_info "Restore-Test fuer: ${TARGETS[*]} (Wegwerf-Container, keine Produktiv-DB)"

if [[ "$DRY_RUN_TEST" == "true" ]]; then
  log_ok "Restore-Test (dry): wuerde ${#TARGETS[@]} Services testen: ${TARGETS[*]}"
  exit 0
fi

# --- Wegwerf-Container nur fuer die DB-Typen starten, die tatsaechlich getestet werden ---
NEED_PG=false NEED_MY=false
for svc in "${!TARGETS[@]}"; do
  load_service_env "${TARGETS[$svc]}"
  case "${DB_TYPE:-}" in
    postgres)        NEED_PG=true ;;
    mysql|mariadb)   NEED_MY=true ;;
  esac
done

# Cleanup-Trap: Test-Container und -Netzwerk auch bei Abbruch/Fehler entfernen,
# damit Wegwerf-DBs nie als laufende Container uebrig bleiben (wuerden
# sonst von der Auto-Discovery als Services gesichert).
cleanup_test() {
  docker rm -f "$TEST_PG_NAME" "$TEST_MY_NAME" >/dev/null 2>&1
  docker network rm "$TESTNET" >/dev/null 2>&1 || true
}
trap cleanup_test EXIT

if ! docker network inspect "$TESTNET" >/dev/null 2>&1; then
  docker network create "$TESTNET" >/dev/null 2>&1 || { log_fail "Kann Test-Netzwerk nicht anlegen"; exit 1; }
fi

start_test_pg() {
  [[ "$NEED_PG" == "true" ]] || return 0
  docker inspect "$TEST_PG_NAME" >/dev/null 2>&1 && docker rm -f "$TEST_PG_NAME" >/dev/null 2>&1
  docker run -d --rm --name "$TEST_PG_NAME" --network "$TESTNET" \
    -e POSTGRES_PASSWORD=testpass -e POSTGRES_USER=test -e POSTGRES_DB=testdb \
    "$TEST_IMAGE_PG" >/dev/null 2>&1 || { log_fail "Kann Test-Postgres nicht starten"; exit 1; }
  for i in $(seq 1 30); do
    docker exec "$TEST_PG_NAME" pg_isready -U test >/dev/null 2>&1 && return 0
    sleep 1
  done
  log_fail "Test-Postgres nicht bereit"; exit 1
}

start_test_my() {
  [[ "$NEED_MY" == "true" ]] || return 0
  docker inspect "$TEST_MY_NAME" >/dev/null 2>&1 && docker rm -f "$TEST_MY_NAME" >/dev/null 2>&1
  docker run -d --rm --name "$TEST_MY_NAME" --network "$TESTNET" \
    -e MARIADB_ROOT_PASSWORD=testpass -e MARIADB_DATABASE=testdb \
    "$TEST_IMAGE_MY" >/dev/null 2>&1 || { log_fail "Kann Test-MariaDB nicht starten"; exit 1; }
  for i in $(seq 1 60); do
    docker exec "$TEST_MY_NAME" mariadb-admin ping -uroot -ptestpass >/dev/null 2>&1 && return 0
    sleep 1
  done
  log_fail "Test-MariaDB nicht bereit"; exit 1
}

start_test_pg
start_test_my

# --- Einzelne Restore-Tests ---------------------------------------------

test_postgres_restore() {
  local svc="$1" dump="$2"
  log_info "$svc: spiele Dump $dump in Test-DB ein..."
  # pg_dumpall-Dumps (DB_DUMP_ALL) enthalten \connect-Anweisungen und legen
  # Tabellen in der Original-DB an — Restore in die Original-DB simulieren.
  # Einfache pg_dump-Dumps landen in der Ziel-DB testdb (kein \connect enthalten).
  local restore_db="testdb"
  if grep -aq '^\\connect' <(gunzip -c "$dump" | head -50); then
    restore_db="$DB_NAME"
    docker exec "$TEST_PG_NAME" psql -U test -d testdb -c "CREATE DATABASE \"$restore_db\"" >/dev/null 2>&1 || true
  fi
  if gunzip -c "$dump" | docker exec -i "$TEST_PG_NAME" psql -U test -d "$restore_db" --set ON_ERROR_STOP=off >/dev/null 2>&1; then
    local tables
    tables="$(docker exec "$TEST_PG_NAME" psql -U test -d "$restore_db" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null)"
    if [[ "${tables:-0}" -gt 0 ]]; then
      log_ok "$svc: Restore-Test BESTANDEN ($tables Tabellen aus Stand $latest)"
      cleanup_pg_schema "$restore_db"
      return 0
    fi
    log_fail "$svc: Dump eingespielt, aber 0 Tabellen — Dump pruefen!"
  else
    log_fail "$svc: psql-Import fehlgeschlagen"
  fi
  cleanup_pg_schema "$restore_db"
  return 1
}

cleanup_pg_schema() {
  local restore_db="$1"
  docker exec "$TEST_PG_NAME" psql -U test -d testdb -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
  if [[ "$restore_db" != "testdb" ]]; then
    docker exec "$TEST_PG_NAME" psql -U test -d testdb -c "DROP DATABASE IF EXISTS \"$restore_db\" WITH (FORCE)" >/dev/null 2>&1
  fi
}

test_mysql_restore() {
  local svc="$1" dump="$2"
  log_info "$svc: spiele Dump $dump in Test-MariaDB ein..."
  # mysql-Dumps ohne CREATE DATABASE landen in testdb; --databases-Dumps
  # legen ihre Original-DB selbst an (USE-Statement enthalten).
  local restore_db="testdb"
  local use_line
  use_line="$(gunzip -c "$dump" | grep -am1 '^USE `')"
  if [[ -n "$use_line" ]]; then
    restore_db="$(sed -n 's/^USE `\([^`]*\)`.*$/\1/p' <<<"$use_line")"
    [[ -n "$restore_db" ]] || restore_db="testdb"
  fi
  if gunzip -c "$dump" | docker exec -i "$TEST_MY_NAME" mariadb -uroot -ptestpass "$restore_db" >/dev/null 2>&1; then
    local tables
    tables="$(docker exec "$TEST_MY_NAME" mariadb -uroot -ptestpass -NBe "SELECT count(*) FROM information_schema.tables WHERE table_schema='$restore_db'" 2>/dev/null)"
    if [[ "${tables:-0}" -gt 0 ]]; then
      log_ok "$svc: Restore-Test BESTANDEN ($tables Tabellen aus Stand $latest)"
    else
      log_fail "$svc: Dump eingespielt, aber 0 Tabellen — Dump pruefen!"
      cleanup_my_db "$restore_db"
      return 1
    fi
  else
    log_fail "$svc: mariadb-Import fehlgeschlagen"
    cleanup_my_db "$restore_db"
    return 1
  fi
  cleanup_my_db "$restore_db"
  return 0
}

cleanup_my_db() {
  local restore_db="$1"
  if [[ "$restore_db" != "testdb" ]]; then
    docker exec "$TEST_MY_NAME" mariadb -uroot -ptestpass -e "DROP DATABASE IF EXISTS \`$restore_db\`" >/dev/null 2>&1
  else
    docker exec "$TEST_MY_NAME" mariadb -uroot -ptestpass -e "DROP DATABASE testdb; CREATE DATABASE testdb;" >/dev/null 2>&1
  fi
}

FAILS=0
for svc in "${!TARGETS[@]}"; do
  load_service_env "${TARGETS[$svc]}"
  # Neuesten Dump suchen — v.0 ist der frischeste Stand (rsnapshot-Rotation)
  base="$BACKUP_ROOT/$SVC_NAME/db"
  dump_dir="$base/v.0"
  latest="v.0"
  [[ -d "$dump_dir" ]] || dump_dir=""
  if [[ -z "$dump_dir" ]]; then
    log_fail "$svc: kein Dump in $base gefunden — Backup vorher laufen lassen!"
    ((FAILS+=1)); continue
  fi
  dump="$dump_dir/${SVC_NAME}.sql.gz"
  [[ -f "$dump" ]] || { log_fail "$svc: Dump-Datei fehlt: $dump"; ((FAILS+=1)); continue; }

  case "${DB_TYPE:-}" in
    postgres)      test_postgres_restore "$svc" "$dump" || ((FAILS+=1)) ;;
    mysql|mariadb)  test_mysql_restore "$svc" "$dump" || ((FAILS+=1)) ;;
    *)              log_fail "$svc: DB_TYPE '$DB_TYPE' wird vom Restore-Test nicht unterstuetzt"; ((FAILS+=1)) ;;
  esac
done

docker rm -f "$TEST_PG_NAME" "$TEST_MY_NAME" >/dev/null 2>&1
docker network rm "$TESTNET" >/dev/null 2>&1 || true

if [[ $FAILS -gt 0 ]]; then
  log_fail "Restore-Test abgeschlossen mit $FAILS Fehlern"
  exit 1
fi
log_ok "Restore-Test abgeschlossen: alle Dienste bestanden"
exit 0
