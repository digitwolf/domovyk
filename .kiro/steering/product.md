---
inclusion: always
---

# Product

Domovyk lets Claude look after an Ubuntu machine: drivers, updates, crashes, logs, performance and disk usage. It gives the agent a self-documenting `domovyk` command, Ubuntu-specific skills and a guarded path to every change, in the way Omarchy integrates agents into Omarchy.

- Supported hosts: Ubuntu 24.04 LTS (`noble`) and Ubuntu 26.04 LTS (`resolute`), amd64. The CLI works on any desktop and on servers. Desktop integration targets GNOME first.
- Primary agent: Claude Code. Claude Desktop (through MCP) and other agents come in later phases.
- Architecture and rationale: `#[[file:DESIGN.md]]`. Decisions the maintainer approved are listed in its "Decisions" section.
- Phases:
  1. Knowledge and read: spec `domovyk-core`.
  2. Safe changes and desktop: a later spec.
  3. Other surfaces: a later spec.
- Names:
  - The package and command are `domovyk`.
  - Polkit IDs use the prefix `com.digitwolf.domovyk.`.
  - The journal identifier is `domovyk`.
  - Never use "Omarchy", "Oma-", "Claude" or "Anthropic" in package, command, plugin or marketplace names. Claude Code reserves plugin names that read as Anthropic's own.
