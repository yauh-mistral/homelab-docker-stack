#!/usr/bin/env bash
# make-env-examples.sh — Migration .env -> maskierte .env.example
#
# Liest die produktiven .env-Dateien der Stacks (STACKS_DIR) und erzeugt daraus
# .env.example-Dateien mit maskierten Secrets. Nicht-Secrets bleiben als
# Referenzwerte stehen (sie sind Teil der Dokumentation), Secrets werden durch
# REPLACE_ME ersetzt und bekommen eine Kommentar-Zeile mit Herstellungsanweisung.
#
# Welche Variablen Secrets sind, ist katalogisiert in projects/env-details.md;
# die Erkennung hier laeuft ueber Namensmuster (SECRET_PATTERNS) plus eine
# Ausschlussliste fuer False Positives (z.B. AI_MAX_TOKENS). Werte werden nie
# in die Ausgabe geschrieben.
#
# Usage:
#   ./make-env-examples.sh [--stacks-dir DIR] [--out DIR] [--force]
#   ./make-env-examples.sh --check   # nur anzeigen, was als SECRET erkannt wird
#
set -u
set -o pipefail

STACKS_DIR="/opt/docker/arcane/projects"
OUT_DIR=""
FORCE=false
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stacks-dir) shift; STACKS_DIR="${1:?--stacks-dir braucht Pfad}" ;;
    --out)        shift; OUT_DIR="${1:?--out braucht Pfad}" ;;
    --force)      FORCE=true ;;
    --check)      CHECK_ONLY=true ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -d "$STACKS_DIR" ]] || { echo "Stacks-Verzeichnis nicht gefunden: $STACKS_DIR" >&2; exit 2; }

# --- Secret-Erkennung: Variablenname matcht eines dieser Muster (ERE) ---
SECRET_PATTERNS='PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PASSKEY|ENCRYPTION_KEY|SALT|CREDENTIALS|SMTP_PASS|EMAIL_PASS|JWT_SECRET|MASTER_KEY|_KEY$'

# --- Explizite Nicht-Secrets, die ein Muster faelschlich treffen wuerde ---
FALSE_POSITIVES='AI_MAX_TOKENS|PORTKEY_API_BASE|CP_EMAIL_SMTP_CRYPTO|SMTP_AUTH_MECHANISMS|COMPOSE_KOMODO_IMAGE_TAG|GHOST_DB_NAME|DB_NAME|DB_DATABASE_NAME|CHECK_FOR_UPDATES|TDARR_DRI_DEVICE|VIRTUAL_PORT|MEDIA_PATH|DB_DATA_PATH'

is_secret() {
  local var="$1"
  [[ "$var" =~ ^($FALSE_POSITIVES)$ ]] && return 1
  [[ "$var" =~ ^($SECRET_PATTERNS)$ ]] && return 0
  # Muster auch infix erlauben (z.B. KOMODO_AWS_SECRET_ACCESS_KEY, CP_ANALYTICS_SALT)
  [[ "$var" =~ ($SECRET_PATTERNS) ]] && return 0
  return 1
}

# --- Herstellungsanweisung pro Variablenklasse (erste Treffer gewinnt) ---
# SMTP- und Provider-Credentials kommen vom Mail-/Account-Provider, nicht random.
gen_hint() {
  local var="$1"
  case "$var" in
    *SMTP_PASSWORD*|*SMTP_PASS*|*EMAIL_PASS*|*EMAIL_PASSWORD*)
      echo "# Vom Mail-Provider vorgegeben (Webmail-/SMTP-Passwort) - NICHT selbst generieren" ;;
    *ENCRYPTION_KEY*)
      echo "# Erzeugen: openssl rand -hex 32" ;;
    *SALT*)
      echo "# Erzeugen: openssl rand -hex 32" ;;
    *JWT_SECRET*|*WEBHOOK_SECRET*|*PROXY_SECRET*|*SECRET_KEY*|*MASTER_KEY*|*AUTH_SECRET*)
      echo "# Erzeugen: openssl rand -hex 32" ;;
    *ROOT_PASSWORD*|*PASSWORD*|*PASSWD*)
      echo "# Erzeugen: openssl rand -base64 24" ;;
    *PASSKEYS*)
      echo "# Pro Periphery-Instanz ein Key, Komma-getrennt; Erzeugen: openssl rand -base64 24" ;;
    *API_KEY*|*API_TOKEN*)
      echo "# Erstellen beim jeweiligen Anbieter (Konsole/Dashboard) - nicht selbst generieren" ;;
    *TOKEN*)
      # Self-hosted-Services (vaultwarden ADMIN_TOKEN, crawl4ai): Token einmalig
      # selbst setzen/rotieren; kein externer Anbieter noetig
      echo "# Einmalig selbst festlegen/rotieren: openssl rand -base64 48 (self-hosted, kein Anbieter)" ;;
    *)
      echo "# Secret - maskiert; Herkunft/Konvention siehe projects/env-details.md" ;;
  esac
}

process_env() {
  local envfile="$1" out="" project="" var="" line=""
  project="$(basename "$(dirname "$envfile")")"
  if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "== $project =="
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      var="${line%%=*}"
      if is_secret "$var"; then
        echo "  SECRET: $var"
      fi
    done < "$envfile"
    return 0
  fi
  # Ohne --out: .env.example NEBEN die .env schreiben (In-Place-Doku im Stack),
  # mit --out: zentrale Sammelstelle (z.B. zum Hochladen ins Repo).
  if [[ -n "$OUT_DIR" ]]; then
    out="$OUT_DIR/$project/.env.example"
    mkdir -p "$OUT_DIR/$project"
  else
    out="$(dirname "$envfile")/.env.example"
  fi
  if [[ -e "$out" && "$FORCE" != "true" ]]; then
    echo "UEBERSPRUNGEN (existiert, --force zum Ueberschreiben): $out"
    return 0
  fi
  : > "$out"
  # Vorherige Zeile merken: Wenn bereits ein Kommentar ueber der Variablen
  # steht, der die Herstellung erklaert, keinen zusaetzlichen Hint anbringen.
  local prev=""
  # while-or-read verliert die letzte Zeile, wenn die Datei keinen
  # abschliessenden Zeilenumbruch hat -> read haengt nachfolgenden Code an,
  # daher die letzte (umbruchlose) Zeile explizit behandeln.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
      echo "$line" >> "$out"
      prev="$line"
      continue
    fi
    var="${line%%=*}"
    if is_secret "$var"; then
      # Nur ergaenzen, wenn die Vorzeile kein Kommentar ist (keine Duplikate)
      if [[ "$prev" =~ ^[[:space:]]*# ]]; then
        echo "$var=REPLACE_ME" >> "$out"
      else
        echo "$(gen_hint "$var")" >> "$out"
        echo "$var=REPLACE_ME" >> "$out"
      fi
    else
      echo "$line" >> "$out"
    fi
    prev="$line"
  done < "$envfile"
  echo "Erzeugt: $out"
}

shopt -s nullglob
for envfile in "$STACKS_DIR"/*/.env; do
  process_env "$envfile"
done
if [[ "$CHECK_ONLY" == "true" ]]; then
  echo "Check-Modus: keine Dateien geschrieben."
fi
