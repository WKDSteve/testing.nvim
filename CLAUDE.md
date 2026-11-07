# testing.nvim (Test-Runner, CI-Pipeline, Cache)

Lua-Plugin für Neovim; zusätzlich die Verträge `testing-export/1`, `testing-ci/1`, `testing-ci-commit/1`, `testing-ci-release/1`,
`testing-sheet-session/1` und `testing-sheet-driver/1` (`schemas/`). Konventionen wie in der Vorlage `nvim-plugin`.

## Vor jedem Commit (alles muss grün sein)

```
stylua --check lua TESTS
luacheck lua TESTS                    # 0 Warnungen: eine Warnung macht die CI rot
scripts/test.sh                       # die ganze Suite (Dogfood), Einzelnes: scripts/test.sh --file <teil>
```

- Ein Fix ohne Spec, der ohne den Fix rot wird, gilt nicht als fertig (Sabotage-Probe: Fix kurz entfernen, Spec muss rot
  werden).
- Während ein Lauf geht, keine Datei des Repos bearbeiten: der Datei-Wächter meldet es als Fehler der laufenden Specs.
- Mehrere Sitzungen teilen den Rechner: eine Suite unter Last kann Timeouts und die bekannten Lastflakes zeigen
  (`child_run_spec`, `sheet_spec`); erst bei Ruhe wiederholen, bevor ein Fehler gesucht wird.
- Fremde uncommittete Änderungen nie committen oder zurücksetzen; nur eigene Dateien mit Pfad stagen.
- Auf einen sauberen Baum wird nicht gewartet: die Pipeline läuft auf einem Schnappschuss, ohne Arbeitsbaum und ohne die
  Änderungen anderer Sitzungen. Vor dem Commit: `scripts/test.sh ci --snapshot --profile=<p> --with=<meine,pfade>`
  (Stand plus eigene Änderungen, nie ein Beweis); nach dem Commit: `scripts/test.sh ci --snapshot --profile=<p>` oder
  `ci commit <sha>`.

## Doku

- Nutzer-Docs im Repo: `docs/` (`CI.md`, `CACHE.md`, `BINDINGS.md`), `doc/testing.txt`. Wer ein Verhalten ändert, zieht sie
  im selben Commit nach.
- Backlogs, Roadmaps und Notizen stehen im Vault `$REPOS_DIR/tasks-vault/testing.nvim`, nie im Repo. Tasks dort nur mit
  `tasks done` schließen.

## Commits prüfen

**Commits prüfen: `testing ci commit`.** Wenn du einen Commit reviewst oder prüfen sollst, ob er etwas kaputt macht,
prüfe ihn mit `scripts/test.sh ci commit <sha>` im Repo (ohne Template-Skript:
`nvim -n -i NONE --headless -u NONE -l "$REPOS_DIR/testing.nvim/scripts/testing.lua" ci commit <sha> --root=<repo>`),
nie mit `scripts/test.sh` oder `testing ci` im Arbeitsbaum. Mehrere: `ci commit <a> <b>`, `--range=<von>..<bis>` oder
`--since=<zeit>` (alle Nicht-Merge-Commits seit dann); über mehrere Repos: `--repos-root=<dir> --since=<zeit>`. Im Editor:
`:Testing ci commit`.
Das Urteil gilt nur für das System, auf dem der Befehl lief: nach dem Push `scripts/test.sh ci remote` (die CI je System),
fertig ist ein Commit erst, wenn sie grün ist.
Der Befehl prüft jeden Commit in einem eigenen Git-Worktree, andere Chats im selben Checkout stören also nicht, und
er vergleicht Rot mit dem Parent. Lies die erste Zeile: `CLEAN`, `KNOWN-RED` und `FLAKY` heißen "der Commit macht nichts
neu kaputt" (Exit 0), `REGRESSION` listet darunter die neuen Befunde (`new ...`, Exit 1; beheben oder melden),
`UNCLASSIFIED` (Root-Commit oder Basis lief nicht) prüfst du von Hand, `DOCS-ONLY` lief bewusst nicht. **Lass nie
einen Commit aus, weil eine Suite rot ist**; `known-red` ist ein Ergebnis, kein Grund zum Überspringen, und im
Bericht steht das Urteil je Commit. Ein schon geprüfter Commit kommt sofort aus dem Gedächtnis (`(kept result)`);
`--force` nur, wenn sich Werkzeuge oder Abhängigkeiten geändert haben. `--json=<datei>` liefert das Dokument
`testing-ci-commit/1`, `--keep` lässt die Worktrees zum Nachstellen stehen (die `rerun`-Zeile nennt den Befehl).
Mit `-- --cached` teilen Commit und Basis einen Cache und laufen schneller. Auf der Workstation läuft es nicht (wie jeder Lauf).

**Sofort prüfen, nicht am Ende.** Jeden Commit gleich nach dem Erstellen mit `scripts/test.sh ci commit <sha>` im
Hintergrund prüfen und währenddessen weiterarbeiten (immer nur ein `ci commit` zur Zeit); das Urteil vor dem Push und
im Review lesen. Am Ende alle auf einmal (`--range`) kostet je Commit einen vollen Lauf plus den der Basis, mehrere
am Stück dauern schnell 40 Minuten. Ein umgeschriebener Commit (Rebase, Amend) mit gleichem Baum behält sein Urteil.
