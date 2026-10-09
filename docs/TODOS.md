# Todos

Ausschließlich offene Aufgaben — erledigte Punkte und getroffene Entscheidungen werden hier nicht archiviert (bei Bedarf in der PR-Historie nachlesbar).

- [ ] **restore.sh testen & verifizieren** — der Restore-Test der DB-Dumps ist vollständig (alle 5 DB-Services, Postgres + MariaDB, in Wegwerf-Containern). Unverifiziert bleibt der echte Restore über `restore.sh`: Dateien zurück in Produktiv-Pfade + Dump einspielen gegen die Produktiv-DB. Ein vollautomatisierter Test ist schwer ohne das Live-System zu gefährden — Optionen:
  - **Manueller Probe-Restore** (empfohlen): einzelne Dateien und DB-Dumps per Hand in eine isolierte Sandbox bzw. auf ein Wegwerf-Zielverzeichnis zurückspielen und verifizieren (Entpacken der `*.sql.gz`, Struktur-Check der Files-Stände), ohne `docker compose` des Live-Systems anzufassen.
  - Alternativ bleibt dieses Todo bestehen, bis ein isolierter Testaufbau (zweiter Host / Wegwerf-VM) verfügbar ist.
