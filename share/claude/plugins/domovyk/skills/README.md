# Domovyk skills

Each folder here is one agent skill: a `SKILL.md` with a short frontmatter, plus
topic files it links to. They are plain Markdown and agent-neutral. Claude Code
loads them through the Domovyk plugin as `domovyk:<name>`.

| Skill | Teaches the agent |
|---|---|
| `ubuntu` | How to look after an Ubuntu machine with Domovyk: read first, plan, hand off every change |
| `diagnose-crash` | Explaining a crash from apport and systemd-coredump evidence |
| `drivers` | `ubuntu-drivers`, DKMS, Secure Boot and firmware |
| `updates` | apt, snap, flatpak and firmware updates, phasing, reboots |
| `disk` | Finding what uses space and reclaiming it safely |
| `performance` | Finding the real bottleneck: CPU, memory, IO, thermal, power |

Rules for skill files (checked by `test/unit/skills.bats`):

- Frontmatter holds only `name`, `description`, `license`, `compatibility`,
  `metadata` and `allowed-tools`, so the same file can be uploaded to claude.ai.
- `description` is at most 1,024 characters and names the topics that trigger it.
- Every `domovyk …` command a skill mentions must exist (`domovyk commands`).
- Every relative link must point at a file in the skill's folder.
