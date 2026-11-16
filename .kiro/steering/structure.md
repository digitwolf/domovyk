---
inclusion: always
---

# Structure

```
bin/domovyk                     dispatcher, installed as /usr/bin/domovyk
libexec/commands/               domovyk-<group>-<action> scripts, one per command (→ /usr/libexec/domovyk/commands)
libexec/lib/                    shared Bash libraries: domovyk.sh (output, JSON, timeouts, sources), checks/ (doctor checks)
libexec/py/                     Python stdlib helpers: redact.py, apport_crash.py
libexec/hooks/                  Claude Code hook programs: guard, context
share/redact.tsv                Redaction_Rules
share/claude/                   local Claude Code marketplace
  .claude-plugin/marketplace.json
  plugins/domovyk/              the plugin: .claude-plugin/plugin.json, skills/, agents/, hooks/hooks.json
    skills/<name>/              the agent-neutral skills (SKILL.md plus topic files); canonical location
share/agents/skills             symlink → claude/plugins/domovyk/skills, for agents other than Claude Code (phase 3)
share/workspace/                template for the agent Workspace (CLAUDE.md)
debian/                         Debian packaging
test/unit/                      bats tests, fixtures/ (redacted captures)
test/vm/                        VM harness, ported from Motanka
test/bats/{core,support,assert} vendored bats-core and helpers
test/run-all                    shellcheck, then unit and VM tests
```

The skills live inside the plugin because Claude Code refuses a component path that resolves outside the plugin root.

Installed paths are `/usr/bin/domovyk`, `/usr/libexec/domovyk/` and `/usr/share/domovyk/`. The dispatcher finds its tree through `DOMOVYK_ROOT`, set from the working tree for tests or from `/usr` once installed. No command hardcodes `/usr`.
