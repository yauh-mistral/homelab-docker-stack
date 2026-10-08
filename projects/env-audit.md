# env-audit — Schritt-3-Referenzcheck (Stand: nach Schritt 2 + 4 + 5)

Verbindlicher Katalog: `projects/env-details.md`. Dieser Report listet alle
`.env.example`-Variablen, die in der zugehörigen `compose.yaml` **nicht
referenziert** werden, mit Einschätzung. **Finale Entscheidung: Owner.**

Legende:
- ✂️ = vermutlich entfernbar
- ⚠️ = vermutlich benötigt, aber Compose-Referenz fehlt (Lücke im Compose)
- 🔁 = wird über `env_file: .env` komplett durchgereicht (nicht `${...}`-referenziert, aber aktiv genutzt)

## Entscheidungen, die bereits umgesetzt sind (Schritt 2)

Einheitliche DB-Credential-Namen nach offizieller Image-Konvention:
`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` (analytics-1, immich, sparkyfitness),
`MARIADB_USER`/`MARIADB_PASSWORD`/`MARIADB_ROOT_PASSWORD`/`MARIADB_DATABASE` (castopod),
`MYSQL_USER`/`MYSQL_PASSWORD`/`MYSQL_ROOT_PASSWORD` (ghost),
`POSTGRES_APP_USER`/`POSTGRES_APP_PASSWORD` (sparkyfitness App-User).
Compose-`${...}`-Referenzen mit umgezogen; **Container-ENV-Namen unangetastet**
(z. B. erwartet das Immich-Image `DB_PASSWORD` als Container-ENV — nur die
`.env`-Quelle heißt jetzt `POSTGRES_PASSWORD`).

Gefundener und gefixter Bug: `SMPT_SERVICE` → `SMTP_SERVICE` (ghost) — Compose
referenzierte `${SMTP_SERVICE}`, die .env hatte einen Tippfehler, Mailversand
der ActivityPub-App hätte still fehlgeschlagen.

## Fundliste „ungenutzt in Compose" mit Einschätzung

### vaultwarden (alle: 🔁 via `env_file: .env`)
`DOMAIN`, `VIRTUAL_HOST`, `VIRTUAL_PORT`, `SMTP_*` (alle), `ADMIN_TOKEN`,
`WEBAUTHN_ENABLED` — Compose reicht die komplette `.env` durch; alle Variablen
aktiv. **Nichts entfernen.** Hinweis: `VIRTUAL_HOST`/`VIRTUAL_PORT` werden vom
Reverse-Proxy-Stack gelesen (shared_proxy-Netzwerk), nicht von dieser compose.

### docker-gui (Komodo-Block: ⚠️)
`COMPOSE_KOMODO_IMAGE_TAG`, `COMPOSE_LOGGING_DRIVER`, `KOMODO_DB_USERNAME`,
`KOMODO_DB_PASSWORD`, `KOMODO_PASSKEY`, `KOMODO_HOST`, `KOMODO_TITLE`,
`KOMODO_FIRST_SERVER`, `KOMODO_DISABLE_*`, `KOMODO_ENABLE_*`,
`KOMODO_MONITORING_INTERVAL`, `KOMODO_RESOURCE_POLL_INTERVAL`,
`KOMODO_WEBHOOK_SECRET`, `KOMODO_JWT_SECRET`, `KOMODO_JWT_TTL`,
`KOMODO_LOCAL_AUTH`, `KOMODO_OIDC_ENABLED`, `KOMODO_*_OAUTH_ENABLED`,
`KOMODO_AWS_*`, `PERIPHERY_*` (alle).
Die compose.yaml enthält **nur Portainer + Dockge** — kein Komodo-Service.
Einschätzung: Wenn Komodo auf dem Host läuft, dann mit separatem Compose-File
(`komodo/compose.env`, siehe Kommentar im .env.example). Dann gehören diese
Variablen in **dessen** Verzeichnis, nicht in docker-gui. ✂️ aus docker-gui
verschiebbar, wenn Komodo-Stack eigenes Projekt-Verzeichnis bekommt. Wenn
Komodo ausgemustert ist: komplett ✂️.

### hardening (NGINX_HOST/NGINX_PORT/POSTGRES_*: ✂️ bzw. 🔁)
`NGINX_HOST`, `NGINX_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`,
`POSTGRES_PORT` — Compose definiert nur crowdsec (mit hartcodierten Werten).
Einschätzung: hardening ist eine Referenz-/Vorlagen-Datei (myapp/myuser sind
Platzhalter). Wenn der Postgres-Teil nie deployed wurde: ✂️. Wenn als Vorlage
gewollt: ⚠️ mit Hinweis „Referenz, nicht aktiv".

### network (PUID/PGID/NGINX_*/POSTGRES_*: ✂️)
`PUID`, `PGID`, `NGINX_HOST`, `NGINX_PORT`, `POSTGRES_DB`, `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_PORT` — Compose definiert nur omada-controller
(kea/dhcp und ein Postgres sind offenbar nie Teil geworden oder entfernt).
Einschätzung: ✂️ — Reste eines anderen Vorhabens. `POSTGRES_*`-Werte sind
Platzhalter (myapp/myuser) und als Passwort Replace-Marker gesetzt.

### monitoring (PUID/PGID/PORT- und GF_*-Variablen: ⚠️)
`PUID`, `PGID`, `DASHDOT_PORT`, `KUMA_PORT`, `GRAFANA_PORT` — Ports werden im
Compose hartcodiert (3080/3001/3000 als VIRTUAL_PORT), Host-Ports per
ports-Liste. `.env`-Werte (8011 etc.) weichen davon ab — möglich, dass die
ports-Liste die Werte übernehmen soll (aktuell nicht). ⚠️ Compose-Referenz
nachziehen oder ✂️.
`GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` — ⚠️ **Lücke im Compose**:
Grafana-Container bekommt die Credentials nicht gereicht (kein environment-Block
mit GF_*). Admin-Login läuft auf Image-Defaults (admin/admin). Compose sollte
`GF_SECURITY_ADMIN_USER`/`GF_SECURITY_ADMIN_PASSWORD` durchreichen.

### litellm (HERMES_M4PRO_KEY: ⚠️)
Compose referenziert nur LITELLM_*, POSTGRES_*, UI_*, OpenAI/Anthropic/OpenRouter.
`HERMES_M4PRO_KEY` (Garmin-Sync-Secret) wird nirgends durchgereicht. Entweder
✂️ oder Compose ergänzen, falls der Hermes-Container den braucht.

### mealie (SMTP_SENDER: ✂️)
Compose nutzt `SMTP_FROM` als From-Email; `SMTP_SENDER` wird nicht referenziert
(Mailie kennt SMTP_FROM_NAME etc.). ✂️ Duplikat.

### analytics-1 (SHYNET_PORT, CERT_EMAIL, SHYNET_BASE_PATH, SMTP_FROM: ⚠️/✂️)
`SHYNET_PORT` ✂️ (VIRTUAL_PORT hartcodiert 8080), `CERT_EMAIL` ✂️ (ACME-Cert
läuft über web-proxy-Stack, dort eigenes ACME_DEFAULT_EMAIL), `SHYNET_BASE_PATH`
🔁 übernimmt nur SHYNET_DATA_PATH/DB_DATA_PATH als Pfadbausteine — wird als
selbständige Variable nicht referenziert, aber aktiv in `${...}`-Interpolation
innerhalb der .env genutzt → **behalten**. `SMTP_FROM` ⚠️ — Compose nutzt
SMTP_SENDER für From; SMTP_FROM ungenutzt → ✂️.

### sparkyfitness (NODE_ENV, TZ, SPARKY_FITNESS_FORCE_EMAIL_LOGIN, SPARKY_FITNESS_MCP_PORT: 🔁/⚠️)
`NODE_ENV`, `TZ` ⚠️ — Compose reicht sie nicht explizit durch; wenn die App sie
braucht, environment-Block ergänzen. `SPARKY_FITNESS_FORCE_EMAIL_LOGIN`,
`SPARKY_FITNESS_MCP_PORT` ⚠️ — laut .env-Kommentaren aktiv genutzt, aber Compose
gereicht sie nicht in den Server-Container. Nachziehen oder ✂️.
`SPARKY_FITNESS_DB_HOST/DB_PORT/EXTRA_TRUSTED_ORIGINS` — in .env.example
auskommentiert, Compose hat Defaults → konsistent, OK.

### wanderer (PUBLIC_PRIVATE_INSTANCE: ⚠️)
Compose reicht PUBLIC_DISABLE_SIGNUP durch, `PUBLIC_PRIVATE_INSTANCE` aber
nicht. Laut Kommentar macht es die Instanz privat → wenn gewollt, Compose
nachziehen; sonst ✂️.

### web-proxy (WILDCARD_DOMAINS: ⚠️)
Compose nutzt DESEC_TOKEN (DEDYN_TOKEN-Container-ENV), aber `WILDCARD_DOMAINS`
wird nicht referenziert. Vermutlich für ein ACME-DNS-Challenge-Skript gedacht,
das außerhalb von Compose läuft. ⚠️ prüfen, wo Wildcard-Zertifikate konfiguriert
sind; evtl. gehört die Variable in ein Skript-Env statt .env.

## Schritt 5 — Compose-Format (erledigt, Skalpell)

- `version:`-Feld aus allen 11 Dateien entfernt (obsolete bei Docker Compose v2,
  erzeugt nur Warnungen; Docker-Compose v1 ist EOL). Keine funktionalen Änderungen.
- Indents: überall 2-Space, keine Tabs, keine Mischformen (geprüft).
- Reihenfolge `services:` → `networks:`/`volumes:` bereits einheitlich.
- Bewusst NICHT angefasst: Quote-Stil (`"3.8"` vs. '3.8' entfiel mit version:),
  Listen- vs. Map-Form von environment (beides valide, Services brauchen ihre
  Form), deploy-Blöcke, healthchecks.

## Schritt 4 — Format-Kommentare (erledigt)

Ambivalente Variablen haben jetzt Kommentar-Anweisungen: URL-Schema/trailing
slash (GHOST_URL, ORIGIN, CP_BASEURL MIT slash, DOMAIN, FRONTEND_URL, API-URLs),
Listen-Trennzeichen (ALLOWED_HOSTS, CSRF_TRUSTED_ORIGINS, WILDCARD_DOMAINS,
GHOST_DOMAIN, HOMEPAGE_ALLOWED_HOSTS), Booleans (true/false), Enumerationen
(SMTP_SECURITY, SMTP_AUTH_MECHANISM, NODE_ENV), Spezial-Rezepte
(LITELLM_MASTER_KEY mit sk-Praefix).
