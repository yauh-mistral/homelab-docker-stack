# Todos

Ausschließlich offene Aufgaben — erledigte Punkte und getroffene Entscheidungen werden hier nicht archiviert (bei Bedarf in der PR-Historie nachlesbar).

- [ ] **restore.sh testen & verifizieren** — wurde bisher nie getestet. Nur `test-restore.sh` (DB-Dumps in Wegwerf-Postgres) läuft grün; der echte Datei-/DB-Restore über `restore.sh` ist unverifiziert. Geplant: Restore einzelner Services in eine isolated Umgebung (Wegwerf-Container, eigenes Zielverzeichnis), nie gegen das Live-System.
- [ ] **Mermaid-Diagramm auf GitHub verifizieren** — prüfen, dass das README-Diagramm (Runtime-Sicht, TB-Layout) rendert.
- [ ] **SemVer-Übergang (Phase 2)** — E2E-Kriterium ist erfüllt (Discovery → Dry-Run → echter Lauf → `test-restore.sh --all` alles grün). Übergang von `v1.0.0` auf Semantic Versioning ist ein User-Entscheid; vermutlich `v1.1.0` beim nächsten inhaltlichen PR.
- [ ] **Cron auf dem Docker-Host bestätigen** — Cron-Zeilen sind geliefert und dokumentiert; Eintrag in der root-Crontab noch unbestätigt.
