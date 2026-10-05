#!/usr/bin/env bash
# test-restore.sh — Restore-Test: spielt den DB-Dump eines Services in einen
# Wegwerf-Postgres-Container ein und prueft, dass Tabellen angelegt wurden.
# Testet die Dump-Methode (nicht die Produktivdaten). Produktiv-DB wird nicht beruehrt.
#
# Usage:
#   test-restore.sh [service]      # default: litellm (kleinste Postgres-DB)
#   test-restore.sh --all           # testet alle postgres-Services
#
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SERVICES_DIR="${SERVICES_DIR:-$SCRIPT_DIR/services.d}"
if [[ -f /etc/backup.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/backup.conf
fi
TEST_IMAGE="${TEST_IMAGE:-postgres:16-alpine}"
TESTNET="backup-restore-test"
TEST_PG_NAME="backup-restore-test-pg"

ALL=false
if [[ "${1:-}" == "--all" ]]; then ALL=true; fi
TARGETS=()
if [[ $ALL == "true" ]]; then
  local_svc=""
  for f in "$SERVICES_DIR"/*.env; do
    local_svc="$(source "$f" 2>/dev/null; [[ "${DB_TYPE:-}" == "postgres" ]] && echo "${SVC_NAME:-$(basename "$f" .env)}" || true)"
    [[ -n "$local_svc" ]] && TARGETS+=("$local_svc")
  done
else
  TARGETS=("${1:-litellm}")
fi

log_info "Restore-Test fuer: ${TARGETS[*]} (Wegwerf-Container, keine Produktiv-DB)"

# Docker-Netzwerk und Wegwerf-Postgres
if ! docker network inspect "$TESTNET" >/dev/null 2>&1; then
  docker network create "$TESTNET" >/dev/null 2>&1 || { log_fail "Kann Test-Netzwerk nicht anlegen"; exit 1; }
fi
if docker inspect "$TEST_PG_NAME" >/dev/null 2>&1; then
  docker rm -f "$TEST_PG_NAME" >/dev/null 2>&1
fi
docker run -d --rm --name "$TEST_PG_NAME" --network "$TESTNET" \
  -e POSTGRES_PASSWORD=testpass -e POSTGRES_USER=test -e POSTGRES_DB=testdb \
  "$TEST_IMAGE" >/dev/null 2>&1 || { log_fail "Kann Test-Postgres nicht starten"; exit 1; }

# Auf Bereitschaft warten
for i in $(seq 1 30); do
  if docker exec "$TEST_PG_NAME" pg_isready -U test >/dev/null 2>&1; then break; fi
  sleep 1
  if [[ $i -eq 30 ]]; then log_fail "Test-Postgres nicht bereit"; docker rm -f "$TEST_PG_NAME"; exit 1; fi
done

FAILS=0
for svc in "${TARGETS[@]}"; do
  decl="$SERVICES_DIR/$svc.env"
  [[ -f "$decl" ]] || { log_fail "$svc: keine Deklaration"; ((FAILS+=1)); continue; }
  load_declaration "$decl"
  # Neuesten Dump suchen
  base="$BACKUP_ROOT/$SVC_NAME/db"
  dump_dir=""
  latest=""
  for d in "$base"/*; do
    [[ -d "$d" ]] || continue
    [[ -z "$latest" || "$(basename "$d")" > "$latest" ]] && latest="$(basename "$d")" && dump_dir="$d"
  done
  if [[ -z "$dump_dir" ]]; then
    log_fail "$svc: kein Dump in $base gefunden — Backup vorher laufen lassen!"
    ((FAILS+=1)); continue
  fi
  dump="$dump_dir/${SVC_NAME}.sql.gz"
  [[ -f "$dump" ]] || { log_fail "$svc: Dump-Datei fehlt: $dump"; ((FAILS+=1)); continue; }

  log_info "$svc: spiele Dump $dump in Test-DB ein..."
  if gunzip -c "$dump" | docker exec -i "$TEST_PG_NAME" psql -U test -d testdb --set ON_ERROR_STOP=off >/dev/null 2>&1; then
    tables="$(docker exec "$TEST_PG_NAME" psql -U test -d testdb -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null)"
    if [[ "${tables:-0}" -gt 0 ]]; then
      log_ok "$svc: Restore-Test BESTANDEN ($tables Tabellen aus Stand $latest)"
    else
      log_fail "$svc: Dump eingespielt, aber 0 Tabellen — Dump pruefen!"
      ((FAILS+=1))
    fi
  else
    log_fail "$svc: psql-Import fehlgeschlagen"
    ((FAILS+=1))
  fi
  # Test-DB fuer naechsten Service leeren
  docker exec "$TEST_PG_NAME" psql -U test -d testdb -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
done

docker rm -f "$TEST_PG_NAME" >/dev/null 2>&1
docker network rm "$TESTNET" >/dev/null 2>&1 || true
if [[ $FAILS -gt 0 ]]; then
  log_fail "Restore-Test abgeschlossen mit $FAILS Fehlern"
  exit 1
fi
log_ok "Restore-Test abgeschlossen: alle Dienste bestanden"
exit 0
