# env-details — Verbindliches Variablen-Verzeichnis

Wahrheit für den Inhalt einer `.env` lebt **ausschließlich** auf dem Host in
`/opt/docker/arcane/projects/<project>/.env`. Dieses Repo enthält nur
`.env.example`-Dateien mit maskierten Werten und Anweisungen zur Herstellung.

Grundsatz (verbindlich):
- `.env`-Dateien werden **nie** mit ausgeliefert, immer nur `.env.example`.
- Alle Environment-Variablen mit gleichem Purpose (Postgres-DB-User,
  MariaDB-Passwort, JWT-Secret) heißen möglichst gleich, sofern der Service
  es nicht zwingend individualisiert braucht. Die Namen in der `.env` sind
  die **übergreifende Konvention**; die Compose-`environment:`-Namen dürfen
  und sollen service-spezifisch sein (Compose mappt `.env`-Name → Service-Name).

Dieses Dokument ist der verbindliche Katalog: Welche Variablen existieren,
welche sind Secrets (maskieren), und wie wird ein Wert erzeugt/geformatiert.
Es ersetzt die frühere Inline-Liste (env-Details) und führt sie mit der
Muster-Erkennung des Skripts zusammen.

Kategorien:
- **SECRET**   — Wert wird maskiert (`REPLACE_ME`), Herstellungsanweisung required
- **CRED**     — Benutzername/Account (nicht verräterisch, aber persönlich): maskiert, aber wiederverwendbar/leichter erratbar
- **URL**      — Format-Anweisung (Schema, trailing slash, Trennzeichen bei Listen)
- **PLAIN**    — unkritisch, bleibt im Beispiel stehen

## 1. Secrets — verbindliche Liste (aus env-Details, ergänzt um Muster-Erkennung)

Bekannte Secret-Variablen aus den produktiven `.env`-Dateien (verbindlich):

| Variable | Projekt(e) |
|---|---|
| `CRAWL4AI_API_TOKEN` | crawl4ai |
| `KOMODO_DB_PASSWORD` | docker-gui |
| `KOMODO_PASSKEY` | docker-gui |
| `KOMODO_WEBHOOK_SECRET` | docker-gui |
| `KOMODO_JWT_SECRET` | docker-gui |
| `PERIPHERY_PASSKEYS` | docker-gui |
| `FORGEJO_TOKEN` | forgejo |
| `DB_PASSWORD` | ghost (App-User), immich, weitere |
| `DB_ROOT_PASSWORD` | ghost (Backup/Dump als root) |
| `ACTIVITYPUB_WEBHOOK_SECRET` | ghost |
| `SMTP_PASSWORD` | übergreifend |
| `POSTGRES_PASSWORD` | hardening, litellm, network, weitere |
| `LITELLM_MASTER_KEY` | litellm |
| `UI_PASSWORD` | litellm (UI-Login) |
| `HERMES_M4PRO_KEY` | litellm (Garmin-Sync) |
| `GF_SECURITY_ADMIN_PASSWORD` | monitoring (Grafana) |
| `ADMIN_TOKEN` | vaultwarden |
| `MEILI_MASTER_KEY` | open-notebook (Meilisearch) |
| `POCKETBASE_ENCRYPTION_KEY` | wanderer |
| `POCKETBASE_PROXY_SECRET` | wanderer |
| `DESEC_TOKEN` | dnd (deSEC DNS) |

Zusätzlich erkennt `make-env-examples.sh` per Namensmuster weitere
Secret-artige Variablen (z. B. `N8N_ENCRYPTION_KEY`, `OPENAI_API_KEY`,
`PAPERLESS_DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `WOPI_JWT_SECRET`,
`BETTER_AUTH_SECRET`, `INITIAL_ADMIN_PASSWORD`) — die Muster-Liste ist eine
**Obermenge**: Liebes nachtragen, was auf dem Host als Secret erkannt wird und
hier fehlt, wird hier ergänzt und gilt dann als verbindlich.

### Datenbank-Passwörter (Ziel-Konvention Schritt 2) (Zugangsdaten, einheitlich pro DB-System)
| Projekt | Variable | Ziel-Konvention (Schritt 2) |
|---|---|---|
| castopod | `MYSQL_ROOT_PASSWORD` | `MARIADB_ROOT_PASSWORD` |
| ghost | `DB_PASSWORD` (Ghost-App-User) | `MYSQL_PASSWORD` |
| ghost | `DB_ROOT_PASSWORD` (Backup root) | `MYSQL_ROOT_PASSWORD` |
| docker-gui | `KOMODO_DB_PASSWORD` | `KOMODO_POSTGRES_PASSWORD` |
| litellm | `LITELLM_MASTER_KEY` | bleibt |
| n8n | `N8N_ENCRYPTION_KEY` | bleibt |
| paperless | `PAPERLESS_DB_PASSWORD` | `POSTGRES_PASSWORD` |
| hardening | `POSTGRES_PASSWORD` | bleibt (Referenz-Stack) |
| analytics | `DB_PASSWORD` (shynet) | `POSTGRES_PASSWORD` |
| sparkyfitness | `SPARKY_FITNESS_DB_PASSWORD` | `POSTGRES_PASSWORD` |
| open-notebook | `DB_PASSWORD` (surreal) | bleibt |
| wanderer | `DB_PASSWORD` (pocketbase) | bleibt |

### App-Admin-Passwörter
| Projekt | Variable |
|---|---|
| collabora | `COLLABORA_ADMIN_PASSWORD` |
| forgejo | (kein Secret in .env; `GITEA_TOKEN` nicht enthalten) |
| grafana (monitoring) | `GF_SECURITY_ADMIN_PASSWORD` |
| paperless | `PAPERLESS_ADMIN_PASSWORD` |
| sparkyfitness | `INITIAL_ADMIN_PASSWORD` |
| litellm | `ADMIN_TOKEN` |
| crawl4ai | `ADMIN_TOKEN` |
| codex/ui | `UI_PASSWORD` |
| dnd | `ADMIN_TOKEN` |

### API-Keys / Tokens (Drittanbieter)
| Projekt | Variable |
|---|---|
| paperless | `PAPERLESS_API_TOKEN` (paperless-ai) |
| castopod | `CP_ANALYTICS_SALT` (Shynet-Mathe-Salt) |
| dnd | `DESEC_TOKEN` (deSEC DNS) |
| forgejo | `FORGEJO_TOKEN` (Runner-Registrierung) |
| dnd | `HERMES_M4PRO_KEY` |
| docker-gui | `KOMODO_AWS_ACCESS_KEY_ID`, `KOMODO_AWS_SECRET_ACCESS_KEY` |
| docker-gui | `KOMODO_PASSKEY` (Anmeldung), `KOMODO_WEBHOOK_SECRET`, `KOMODO_JWT_SECRET` |
| docker-gui | `PERIPHERY_PASSKEYS` |
| dnd | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `PORTKEY_API_KEY` |
| node-red | `SECRET_KEY` (Flow-Credentials-Verschlüsselung) |
| n8n | `N8N_ENCRESSION_KEY` → `N8N_ENCRYPTION_KEY` |
| ghost | `DB_SECRET_KEY` (MySQL-Schema-Verschlüsselung) |
| crawl4ai | `CRAWL4AI_API_TOKEN` |
| open-notebook | `MEILI_MASTER_KEY` |
| wanderer | `POCKETBASE_ENCRYPTION_KEY`, `POCKETBASE_PROXY_SECRET` |
| wanderer | `WOPI_JWT_SECRET` (Collabora-Integration) |
| opencloud | `OC_CONFIG_DIR`/`OC_DATA_DIR` enthalten keine Secrets |

### SMTP-Zugangsdaten
| Projekt | Variable |
|---|---|
| castopod | `CP_EMAIL_SMTP_PASSWORD` |
| sparkyfitness | `SMTP_PASSWORD`, `SPARKY_FITNESS_EMAIL_PASS` |

### Sonstige
| Projekt | Variable |
|---|---|
| immich | `DB_SECRET_KEY`-Äquivalent: `IMMICH_DB_PASSWORD` (in env vorhanden, Postgres) |
| litellm | `PORTKEY_API_BASE` ist keine Secret, aber URL-Format beachten |
| sparkyfitness | `SPARKY_FITNESS_API_ENCRYPTION_KEY` |
| ghost | `ACTIVITYPUB_WEBHOOK_SECRET` |
| forgejo | `I_AM_KNOX_PASSWORD` nicht enthalten; `LDAP_BIND_PASSWORD` (falls genutzt) |
| vaultwarden | (Secrets in DB, keine .env-Secrets) |

## 2. Cred-Usernames (maskieren, aber sprechend lassen)
`DB_USER`, `DB_USERNAME`, `MYSQL_USER`, `POSTGRES_USER`, `KOMODO_DB_USERNAME`,
`GF_SECURITY_ADMIN_USER`, `COLLABORA_ADMIN_USER`, `PAPERLESS_ADMIN_USER`,
`SMTP_USERNAME`, `CP_EMAIL_SMTP_USERNAME`, `LDAP_BIND_DN` (kein Passwort), `UI_USERNAME`,
`PAPERLESS_ADMIN_MAIL` (Mail = personenbezogen)

## 3. URL-/Format-Variablen (keine Secrets, aber Format-Anweisung nötig)
| Variable | Format |
|---|---|
| `GHOST_URL`, `VIRTUAL_HOST`, `DOMAIN` | `https://host.tld` **ohne** trailing slash, **eine** URL |
| `CSRF_TRUSTED_ORIGINS` | Liste, **Komma-getrennt**, mit Schema `https://a.tld,https://b.tld` |
| `ALLOWED_HOSTS` | Komma-getrennt, ohne Schema |
| `GARMIN_MICROSERVICE_URL`, `VALHALLA_URL`, `NOMINATIM_URL`, `OLLAMA_API_URL` | `http://host:port` **ohne** trailing slash |
| `SMTP_HOST` | Hostname oder IP ohne Schema/Port |
| `SMTP_SENDERS` | Komma-getrennte Mail-Adressen |
| `SMTP_TRANSPORT_ENCRYPTION` | `none` \| `starttls` \| `tls` |
| `SMTP_SECURITY` | `none` \| `starttls` \| `ssl` |
| `OVERPASS_API_URL` | `https://...` mit Pfad, ohne trailing slash |
| `PUID`/`PGID`/`TZ` | Zahlen/`Europe/Berlin` |

## 4. Herstellungsanweisungen (Standard-Rezepte)
- Passwörter: `openssl rand -base64 24`
- API-Keys/Tokens: vom Anbieter generieren, nicht selbst erfinden
- Encryption-Keys (n8n, pocketbase, sparky): `openssl rand -hex 32` (n8n) bzw. `openssl rand -base64 32`
- Salze: `openssl rand -hex 16`
- `CP_ANALYTICS_SALT` (Shynet): gleicher Salt wie in der Shynet-Instanz, `openssl rand -hex 16`
