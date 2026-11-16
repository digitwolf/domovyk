---
inclusion: always
---

# Tech

- **Language:** Bash (`set -euo pipefail`) for the CLI, commands, hooks and package scripts. Python 3 standard library only where Bash is a poor fit: the Redactor, the apport crash-file parser and the Guard_Hook's shell parser. Run Python with `python3 -I`. It must stay compatible with Python 3.12 (24.04). No pip, no third-party Python modules.
- **JSON:** `jq` ≥ 1.7 (24.04 ships 1.7.1, 26.04 ships 1.8.1). Every `--json` output carries `"schema": "domovyk.<group>.v<N>"`.
- **Runtime dependencies:** `bash`, `coreutils`, `jq`, `python3`, `systemd`, `util-linux`. Every other tool a command uses is optional. A missing tool is reported as unavailable, never as a failure.
- **Packaging:** one Debian package, `domovyk`, `Architecture: all`, `debhelper` compat 13, checked with `lintian`. The same .deb serves both releases. Builds run in a test VM, never on the host.
- **Claude Code:** the plugin is checked with `claude plugin validate --strict`. Hooks use exec form (`command` plus `args`). The minimum Claude Code version the plugin needs is recorded in `design.md`.
- **Logging:** systemd journal, identifier `domovyk` (`logger -t domovyk`). No log files.
- **Data files:** line-oriented TSV for the User_Ledger. Redaction rules live in `share/redact.tsv`.
- **Style:** `shfmt -i 2 -ci` and `shellcheck` clean. Quote associative-array subscripts that contain `-` or `/`, because shfmt otherwise rewrites them as arithmetic.
- **Commits:** Conventional Commits v1.0.0, no attribution trailers. Nothing is pushed without the owner's OK.
