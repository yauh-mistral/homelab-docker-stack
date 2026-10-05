#!/usr/bin/env bash
#
# make-env-examples.sh
# Finds every .env file (any depth) and creates a .env.example
# next to it, with secrets replaced by placeholders.

set -euo pipefail

while IFS= read -r -d '' envfile; do
  out="$(dirname "$envfile")/.env.example"

  awk -F'=' '
    /^[[:space:]]*#/ { print; next }   # keep comments untouched
    {
      key = $1
      if (toupper(key) ~ /(TOKEN|SECRET|KEY)/)
        print key "=REPLACE_ME"       # redact sensitive values
      else
        print                         # keep everything else as-is
    }
  ' "$envfile" > "$out"

  echo "created: $out"
done < <(find . -type f -name '.env' -print0 -not -path '*/node_modules/*')
