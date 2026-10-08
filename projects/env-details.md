env-Details

.env Dateien werden nie mit ausgeliefert, immer nur .env.example.
Für diese ist wichtig:
- Alle Environment-Variablen mit gleichem Purpose (Postgres DB User/Maria DB Password/JWT Secret) müssen auch möglichst gleich heißen, sofern der Service das nicht komplett individualisiert benötigt. Die Namen in der env-Datei werden im Compose miteinander verbunden, die Compose environment variable names dürfen und sollen an den jeweiligen Service angepasst sein.

Folgende env var Namen aus den .env Dateien sind aktuell bekannt als Secrets:
- CRAWL4AI_API_TOKEN
- KOMODO_DB_PASSWORD
- KOMODO_PASSKEY
- KOMODO_WEBHOOK_SECRET
- KOMODO_JWT_SECRET
- PERIPHERY_PASSKEYS
- FORGEJO_TOKEN
- DB_PASSWORD (Ghost)
- DB_ROOT_PASSWORD (Ghost)
- ACTIVITYPUB_WEBHOOK_SECRET (Ghost)
- SMTP_PASSWORD
- POSTGRES_PASSWORD (hardening)
- DB_PASSWORD (Immich)
- LITELLM_MASTER_KEY
- UI_PASSWORD (LiteLLM)
- POSTGRES_PASSWORD (LiteLLM)
- HERMES_M4PRO_KEY (LiteLLM)
- GF_SECURITY_ADMIN_PASSWORD (Monitoring/Grafana)
- POSTGRES_PASSWORD (network)
- ADMIN_TOKEN (vaultwarden)
- MEILI_MASTER_KEY
- POCKETBASE_ENCRYPTION_KEY
- POCKETBASE_PROXY_SECRET
- DESEC_TOKEN
