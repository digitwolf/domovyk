# Domovyk design

> A *domovyk* (домовик) is the house spirit of Ukrainian folklore who keeps the
> household in order. Here it is Claude, looking after an Ubuntu machine.

## Goal

Let Claude run an Ubuntu machine the way Omarchy lets agents run an Omarchy one:
drivers, updates, crashes, logs, performance and disk usage. The agent must know the
system, see clearly what is going on, and change the system only through steps that
are safe, confirmed by the owner, recorded and, where possible, reversible.

Targets Ubuntu 24.04 and 26.04 LTS with any desktop (GNOME first). Claude Code is the
primary agent. Claude Desktop and other agents come second.

## What Omarchy does, and what carries over

Omarchy v4.5.0 (vendored in Motanka at `.cache/upstream/omarchy`) wires agents into the
OS through six mechanisms:

| Omarchy mechanism | What it is | Domovyk equivalent |
|---|---|---|
| One self-documenting CLI | `omarchy <group> <action>`, `omarchy commands --json`, a `# omarchy:summary=` header in every script | `domovyk` CLI with the same metadata contract, plus a `tier` field (read/user/system) |
| Skills shipped by the OS | `default/agents/skills/{omarchy,diagnose-crash,omarchy-app}`, symlinked into `~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills`, … | Ubuntu skills in `/usr/share/domovyk/agents/skills`, delivered to Claude Code as a plugin and symlinked for other agents |
| Agent launcher | `omarchy agent [prompt]`, a default-agent picker, a fixed app-id and a work dir so trust is remembered | `domovyk agent [prompt]` in a dedicated workspace |
| Event to agent | `omarchy-crash-watch` follows systemd-coredump in the journal, shows a "Process crashed" toast, and a click runs `omarchy agent crash <pid>` with the diagnose-crash skill | The same idea for apport and systemd-coredump, plus a daily checkup that never uses the model on its own |
| Privilege rule | `sudo` in a visible terminal, `pkexec` when the agent cannot type a password | Every system change goes through **one pkexec helper with a fixed list of named actions**. No sudo from the agent. |
| Reset/rollback culture | `omarchy refresh <app>` backs up first, `omarchy reinstall` | A change ledger and `domovyk undo` for system actions |

What does not carry over: the 24-agent zoo, multi-account switching, usage meters, theme
sync and Hyprland specifics. Omarchy's diagnose-crash skill is also Arch-specific: it says
"This is Arch", uses `debuginfod.archlinux.org` and reads systemd-coredump only.

## Rules

1. **The CLI is the contract.** Agents call `domovyk` commands. Skills teach them how.
   Nothing below the skill layer is specific to one agent.
2. **Read freely, change through named actions.** Reads run without prompts. Every
   system change is a named action run by the pkexec helper. The polkit dialog, which
   shows the action and its exact arguments, is the owner's confirmation. No
   passwordless sudo, ever, and no arbitrary root shell.
3. **Plan before change.** Every action has `--plan`, which needs no root and prints the
   exact operations, including `apt-get -s` simulation output. The skills require the
   agent to show the plan and get a yes before running it.
4. **Every change is recorded.** Actions append to a system ledger with the state before
   the change and, where one exists, a reverse action.
5. **Evidence over stories.** Diagnosis reads and does not fix. Reports separate what the
   evidence proves from what is inferred, and say plainly when symbols or logs are
   missing. This rule comes from Omarchy's diagnose-crash skill.
6. **Removable.** dpkg owns every system file. Writes into the home folder are namespaced
   or recorded in a ledger. `domovyk unsetup` plus `apt purge domovyk` leave nothing
   behind. These are Motanka's rules 2, 4 and 5.

## Architecture

```
 entry points   keybinding · app-grid launcher · crash toast · daily checkup toast · `domovyk agent`
                     │
 agents         Claude Code (plugin)      Claude Desktop (MCP server)      other agents (~/.agents/skills)
                     │                          │
 knowledge      skills: ubuntu · diagnose-crash · drivers · updates · disk · performance
                     │
 contract       domovyk CLI ── read tier: facts as text or --json, redacted
                     │      └─ system tier: --plan, then pkexec helper <action> ──► ledger
                     │
 Ubuntu         apt · snap · flatpak · ubuntu-drivers · dkms · fwupd · apport · systemd-coredump
                journald · systemd · smartctl · powerprofilesctl · PCP (optional)
```

## Components

### 1. `domovyk` CLI

A Bash dispatcher over `domovyk-<group>-<action>` scripts in `/usr/libexec/domovyk/bin`,
as in Omarchy. Each script starts with a metadata header:

```bash
# domovyk:summary=Show pending updates across apt, snap, flatpak and firmware
# domovyk:args=[--json] [--security-only]
# domovyk:tier=read            # read | user | system
```

`domovyk commands --json` lists everything. `domovyk <group> --help` shows help without
running anything. Read commands print text, or a stable JSON shape with `--json`. That
shape is what the MCP server and the checkup consume.

| Group | Read tier (facts) | System tier (named actions) |
|---|---|---|
| `status` / `doctor` | One-screen summary. Findings with severity, evidence and a suggested action. | none |
| `updates` | Pending apt updates (with phased-update state), snap, flatpak and firmware updates. Held or broken packages. `/run/reboot-required` and which packages caused it. Last unattended-upgrades run and its errors. Third-party sources and PPAs. | `updates-apply [--security-only]`, `updates-hold <pkg>`, `snap-refresh [<snap>]`, `firmware-update <device>` |
| `drivers` | `ubuntu-drivers` candidates, the kernel module in use per PCI/USB device, DKMS status, Secure Boot and pending MOK state, fwupd devices | `driver-install <pkg>` (only packages `ubuntu-drivers` lists), `driver-remove <pkg>`, `dkms-rebuild` |
| `crash` | Crashes from apport (`/var/crash`) and systemd-coredump, merged: exe, signal, time, package and version, command line, recurrence | `crash-mute` (user tier). Reporting to Launchpad only with explicit consent, through `ubuntu-bug`. |
| `logs` | Errors this boot and the previous boot, by unit and priority; kernel messages; OOM kills; suspend/resume problems; journal disk usage | `journal-vacuum --size <n>` |
| `perf` | Load, CPU, memory, swap and zram, top processes, pressure stall info, thermal throttling, power profile, boot time (`systemd-analyze`), PCP history if installed | `power-profile <name>` (user tier, through `powerprofilesctl`) |
| `disk` | Filesystems and inodes, the largest directories, reclaimable space by category (apt cache, journal, old snap revisions, old kernels, trash, `~/.cache`, Docker), SMART health, fstrim timer | `clean-<category>`, one action per category, and `kernels-purge-old` |
| `services` | Failed system and user units, status, recent logs | `service-restart <unit>` |
| `hw` | CPU, GPU, memory, battery health, peripherals | none |

Read commands redact secrets by default: tokens, keys, Wi-Fi passphrases, and email
addresses in logs. Redaction is a table of patterns, the same idea as `linux-mcp-server`'s.
`--raw` turns it off.

### 2. Privileged helper and polkit

The only privileged entry point is `/usr/libexec/domovyk/helper`, run as
`pkexec /usr/libexec/domovyk/helper <action> [args]`.

- **One polkit action per named action.** Polkit picks the action with the
  `org.freedesktop.policykit.exec.path` and `org.freedesktop.policykit.exec.argv1`
  annotations; `pkexec(1)` on 26.04 documents both. IDs look like
  `com.digitwolf.domovyk.driver-install`. The messages use `$(command_line)`, so the GNOME
  dialog shows exactly what will run. The default is `auth_admin` for every action;
  `auth_admin_keep` is opt-in for batches.
- **The helper validates every argument.** Package names must exist in an enabled archive
  and must not be on a protected list (`ubuntu-desktop`, the running kernel, `systemd`,
  `apt`, …). Units must exist. Sizes must be in range. It never takes a free-form command.
- **Why pkexec and not sudo.** It needs no terminal, so it works from the Claude Code Bash
  tool, from an MCP server and from a notification click. Each action asks separately and
  names itself. And it cannot become a general root shell. On GNOME, the shell itself is
  the polkit agent.
- **Anything outside the list** becomes a handoff. The agent writes a script to
  `~/.local/state/domovyk/handoff/<time>-<slug>.sh` and shows it. The owner reads it and
  runs `! sudo bash <path>`. This matches how privileged work is done on this machine today.

### 3. Ledger and undo

The helper appends to `/var/lib/domovyk/ledger.jsonl`. Each record holds an id, time,
caller uid, the action and its arguments, the state before (versions of affected packages
from `dpkg-query`, holds, unit enablement), the state after, the matching
`/var/log/apt/history.log` entry, and a reverse action if one exists.

`domovyk history` lists the records. `domovyk undo <id>` runs the reverse as a named
action: a downgrade from the apt cache or the archive, reinstalling the previous driver,
re-enabling a unit, and so on. Some changes cannot be reversed: kernel and firmware
updates, cleanups, and `snap refresh` only as far as `snap revert` goes. Those records say
so, and their plan warns before they run.

Optional, later: an LVM snapshot before driver, kernel and release-upgrade actions when
the volume group has free extents. This machine has ext4 on LVM.

### 4. Skills

Shipped in `/usr/share/domovyk/agents/skills/`. Every skill is agent-neutral Markdown,
like Omarchy's.

| Skill | Covers |
|---|---|
| `ubuntu` | Core skill: system layout, the decision framework (stock `domovyk` command, then named action, then handoff), the privilege rules, command discovery, "never edit dpkg-owned files in `/usr`; use `/etc` drop-ins", example requests |
| `diagnose-crash` | Omarchy's method ported to Ubuntu. Merges apport `.crash` files and systemd-coredump. Unpacks into a `mktemp` directory and deletes it afterwards (cores hold passwords and tokens). Symbolizes with `debuginfod.ubuntu.com` (already in `/etc/debuginfod/elfutils.urls`) or `apport-retrace`. Rules out OOM first and correlates the crash with apt history. Never uploads without a yes. Offers a per-program mute. |
| `drivers` | `ubuntu-drivers`, DKMS, Secure Boot and MOK enrolment, NVIDIA and Intel IPU6 camera specifics, fwupd, the rollback path, and what to check after a reboot |
| `updates` | apt, snap, flatpak and fwupd; phased updates; holds; unattended-upgrades logs; needrestart and reboot-required; auditing PPAs and third-party sources. A release upgrade (`do-release-upgrade`) is always a handoff. |
| `disk` | A usage breakdown before any cleanup, with categories ranked by reclaimable size and risk. Clean one category at a time, each with its own plan. |
| `performance` | Bottleneck triage (CPU, memory, IO, thermal, power), boot-time analysis, and PCP history when it is installed |

Logs and services live in the core `ubuntu` skill, as topic files like Omarchy's
`hyprland.md`.

### 5. Claude Code integration

A Claude Code plugin, `domovyk`, in a local marketplace inside the package
(`/usr/share/domovyk/claude/`, containing `.claude-plugin/marketplace.json`).
`domovyk setup claude` uses the documented CLI:
`claude plugin marketplace add /usr/share/domovyk/claude`, then
`claude plugin install domovyk@domovyk --scope user`. `unsetup` reverses both. The same
user-scope plugin also loads in local sessions of Claude Desktop's Code tab, which reads
the same settings files.

For machines with several users there is an alternative: a dpkg-owned drop-in,
`/etc/claude-code/managed-settings.d/50-domovyk.json`, carrying `extraKnownMarketplaces`,
`enabledPlugins` and the permission rules. Managed settings are enforced, though, and a
user cannot turn the plugin off. So it is not the default.

- **Skills**: the six above, namespaced `domovyk:*`.
- **Subagent** `domovyk-investigator`: its `tools` list excludes Edit and Write, and its
  prompt confines it to read-tier commands. The main session sends it to dig through logs
  and crashes in parallel, and it returns findings. Plugin agents ignore `permissionMode`
  and `hooks`, so its real limit is the same as everyone's: no root except through the
  helper.
- **Hooks**:
  - `PreToolUse` on Bash denies `sudo …` with `permissionDecision: "deny"` and a
    `permissionDecisionReason`, which the model sees. With no terminal, sudo would hang.
    The reason tells the model to use a named action or a handoff instead. The same hook denies obviously destructive
    commands: `dd of=/dev/*`, `mkfs*`, `wipefs`, `parted`, `rm -rf` on system paths,
    edits to `sudoers`, purging essential packages. A hook is a guardrail, not a sandbox;
    the real boundary is that the agent has no root except through the helper.
  - `SessionStart` (only when `DOMOVYK_SESSION=1`) adds the output of
    `domovyk status --brief`: reboot required, failed units, pending updates, new
    crashes, disk pressure. The agent starts informed and pays a few hundred tokens.
- **Permissions**: read-tier `domovyk` commands are allow-listed so investigation does not
  prompt. The docs say nothing about a plugin carrying `permissions.allow`, so
  `domovyk setup claude` adds the rules (for example `Bash(domovyk status*)`) to
  `~/.claude/settings.json` and records them in the user ledger.
- **Skill frontmatter** is limited to the fields claude.ai accepts on upload: `name`,
  `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. The same
  `SKILL.md` can then be uploaded for Cowork and Claude Desktop chat, which do not read
  local skills.
- **Workspace**: `domovyk agent` starts Claude Code in `~/.local/share/domovyk/workspace`.
  Its `CLAUDE.md` says "you are the caretaker of this machine; load `domovyk:ubuntu`".
  Like Omarchy, it avoids `$HOME`, because agents will not remember trust there.

### 6. Claude Desktop and other MCP clients

`domovyk mcp` is a stdio MCP server written against the Python standard library only.
`mcp` is not in the Ubuntu archive, and the package must not need pip.

- Its tools are generated from `domovyk commands --json`: one tool per read command, with
  `readOnlyHint` (Claude Code runs those in parallel). Each system action is a tool that
  takes `plan` and `confirm` arguments and sets
  `_meta["anthropic/requiresUserInteraction"]: true`. That forces a prompt on every call,
  even in auto mode. Execution still goes through pkexec, so the polkit dialog remains the
  final gate.
- The skills are exposed as MCP prompts and resources, so Desktop gets the method as well
  as the tools.
- It is delivered to Claude Desktop as a Desktop Extension,
  `/usr/share/domovyk/domovyk.mcpb`, installed under Settings › Extensions › Install
  Extension. That is the documented route. The docs give no `claude_desktop_config.json`
  path for Linux, so Domovyk does not edit that file. Whether the Linux beta accepts
  `.mcpb` is not documented either; verify it on a VM.

Other agents get the skills through symlinks in `~/.agents/skills`, as Omarchy does. The
Claude Code plugin is not duplicated into `~/.claude/skills`.

### 7. Desktop integration (GNOME first)

- **Crash watcher** (`domovyk-crash-watch.service`, a user unit, `PartOf=graphical-session.target`).
  It follows the systemd-coredump journal (`MESSAGE_ID=fc2e22bc6ee647b6b90729ab34a250b1`,
  when installed) and new `*.crash` files in `/var/crash` owned by the user (apport is
  the default handler: `core_pattern` pipes to apport). For each crash it sends
  `notify-send --action=diagnose=Diagnose…` and runs `domovyk agent crash <id>` on click.
  It ports Omarchy's guards: dedupe window, per-program mute, on/off toggle, never
  announcing itself. Apport's own dialog keeps handling reports to errors.ubuntu.com;
  Domovyk adds diagnosis.
- **Daily checkup** (`domovyk-checkup.timer`, a user timer). It runs `domovyk doctor --json`,
  which costs no model tokens, diffs it against the last run, and notifies only about new
  findings: "3 things need attention — Review with Claude". Examples: a reboot pending
  for more than 3 days, failed units, a disk over 90 %, SMART warnings, a driver available,
  broken packages, repeated crashes.
- **Launchers**: a GNOME custom shortcut (recorded in the user ledger), an app-grid entry
  "Domovyk" with actions (Checkup, Last crash, Updates), and a terminal opened through
  `xdg-terminal-exec` (Ptyxis on 26.04).
- **Later**: a GNOME Shell indicator showing the doctor state. It is held back by
  GNOME Shell API churn.

### 8. Privacy

Whatever the agent reads goes to Anthropic as conversation context. Therefore:
- read commands redact by default (section 1);
- the crash skill reads backtraces and maps, never core memory wholesale;
- nothing is reported to Launchpad, errors.ubuntu.com or upstream projects without an
  explicit yes on the exact text;
- the checkup never calls the model on its own. A headless summary through `claude -p`
  is opt-in.

## Worked examples (from this machine, 2026-11-15)

- **"My webcam doesn't work."** `domovyk drivers` shows the Intel IPU6 camera with no
  driver bound and `intel-ipu6-dkms` offered by `ubuntu-drivers`. Secure Boot is off, so
  there is no MOK step. `driver-install intel-ipu6-dkms --plan` shows the apt simulation
  and the DKMS build. After a yes, the polkit dialog appears, a ledger entry is written,
  and the agent asks for a reboot and a re-check afterwards.
- **"Why did the SDK Manager crash?"** `/var/crash` has
  `_opt_nvidia_sdkmanager_sdkmanager-gui.1000.crash` (15:00) and a `mpris-proxy` crash
  (Nov 10). diagnose-crash unpacks the first into a temporary directory and symbolizes
  what it can. That will be little for a vendor binary in `/opt`, and the report says so.
  It also checks for an OOM kill and for apt changes around 15:00.
- **"Restart required" since an update.** `domovyk updates` reads
  `/run/reboot-required.pkgs` and says which packages need the reboot and since when,
  along with 2 pending apt and 2 pending snap updates.
- **"Clean up disk."** The root filesystem is 70 % of 1.9 T. The journal holds 1.2 G.
  The breakdown ranks the journal, snap revisions, the apt cache and Docker, and each
  category is cleaned only after its own plan is approved.

## Packaging

| Item | Owner | Undone by |
|---|---|---|
| CLI, helper, polkit policy, skills, plugin, MCP server, user units | `domovyk` (deb, Architecture: all) | `apt purge` |
| System ledger `/var/lib/domovyk` | `domovyk` (kept on remove, deleted on purge) | `apt purge` |
| Plugin and marketplace registration, permission rules in `~/.claude/settings.json`, skill symlinks, shortcut, enabled user units | user ledger `~/.local/state/domovyk/ledger` | `domovyk unsetup` |
| Desktop Extension | the owner, through Claude Desktop | removing it under Settings › Extensions |
| Packages installed by actions | system ledger | listed by `domovyk history`; kept on removal |

- Depends: `bash`, `jq`, `python3`, `pkexec` / `polkitd`, `libnotify-bin`.
- Recommends: `systemd-coredump`, `gdb`, `debuginfod`, `smartmontools`. Not `pcp`, which is
  heavy; the performance skill offers it.
- Published from chumak, Motanka's apt repo, with the same signing key. Built and tested
  for 24.04 and 26.04.

### Relationship to Motanka

Domovyk is a separate package and is useful on stock Ubuntu GNOME. It also fills a Motanka
gap: upstream Omarchy's crash watcher and diagnose-crash skill assume Arch and
systemd-coredump. A Motanka override can point `omarchy-agent-crash` at Domovyk's Ubuntu
skill, and `motanka-core` can recommend `domovyk`.

## Testing

All on VMs, reusing Motanka's QEMU/KVM harness (`test/vm`). The one exception is running
read-tier commands from the working tree on the development host (decision 4).

- Unit tests: argument validation in the helper, plus parsers checked against recorded
  fixtures of `ubuntu-drivers`, `apt`, `snap`, `fwupdmgr`, `coredumpctl` and apport output.
- A deny-list suite: commands the `PreToolUse` hook must block, and commands it must allow.
- Crash injection: `sleep 300 & kill -SEGV $!` must produce a toast, an agent prompt, and a
  temporary directory that is gone afterwards.
- Polkit: each action runs end to end in the VM with a test-only polkit rule. Ledger
  records and undo round-trips are checked.
- MCP: the initialize, `tools/list` and `tools/call` handshake against the MCP inspector.

## Phases

1. **Knowledge and read.** Read-tier CLI, the six skills, the Claude Code plugin with
   hooks, `domovyk agent`, and handoff scripts for every change. Useful on its own.
2. **Safe changes and desktop.** The pkexec helper and polkit actions with `--plan`, the
   ledger and undo, the crash watcher, the daily checkup, and the launchers.
3. **Other surfaces.** The MCP server for Claude Desktop, skills for other agents, PCP
   history, the Motanka integration, and the GNOME Shell indicator.

## Sources

- Omarchy v4.5.0 source: `bin/omarchy-agent*`, `bin/omarchy-crash-watch`,
  `default/agents/skills/`, `manual/17-ai.md`.
- Claude Code docs: [plugins](https://code.claude.com/docs/en/plugins/install.md),
  [plugin components](https://code.claude.com/docs/en/plugins/components.md),
  [hooks](https://code.claude.com/docs/en/hooks.md),
  [permissions](https://code.claude.com/docs/en/permissions.md),
  [managed settings](https://code.claude.com/docs/en/managed-settings.md),
  [MCP](https://code.claude.com/docs/en/mcp.md),
  [skills](https://code.claude.com/docs/en/skills.md),
  [Desktop on Linux](https://code.claude.com/docs/en/desktop-linux.md).
- Host checks, 2026-11-15: `core_pattern`, `/var/crash`, `ubuntu-drivers list`,
  `/etc/debuginfod`, `pkexec(1)`, `notify-send --help`.

## Alternatives considered

| Option | Verdict |
|---|---|
| `pazuzu1w/ubuntu_mcp_server` | Rejected. Its secure policy forbids `/var/log`, `/proc` and `/sys`, has no `journalctl`, no sudo path and no Ubuntu knowledge. Last commit June 2025. |
| `rhel-lightspeed/linux-mcp-server` | Well built (Apache-2.0, 1.8.0 on 2026-10-28) and works on Ubuntu, but read-only, generic and without Ubuntu tools. A fallback for Claude Desktop until phase 3. |
| `linux-sysadmin-mcp` | Rejected. Every change needs passwordless sudo. |
| Plain Claude Code with Bash | Works today, but has no Ubuntu knowledge, no guarded path to root, no record of changes and no desktop entry points. |
| Omarchy itself | Needs Arch. That is what Motanka exists for. |

## Decisions

Approved by the owner on 2026-11-15:

1. **Name:** Domovyk.
2. **Permission mode for `domovyk agent`:** `default`, with the read-tier allow-list, and
   `auto` as an opt-in setting. The mode is passed as a flag, because `auto` cannot come
   from project settings.
3. **Repository:** its own repo (`~/digitwolf/domovyk`), publishing to chumak. The VM
   harness is ported from Motanka, and base images can be shared with it.

Taken while writing the spec (2026-11-15). Flag them if revisited:

4. **Read-tier commands may run on the development host** from the working tree. They
   change nothing, and a VM has no real drivers, crashes or disks to compare against. Unit
   tests, builds, installs and `domovyk setup` stay in VMs (`.kiro/steering/testing.md`).
5. **Phase 1 runs no privileged code at all.** Every change is a Handoff_Script. pkexec
   is denied by the guard hook until phase 2 ships the helper.
6. **SMART health comes from UDisks2 over D-Bus**, because `smartctl` needs root. That
   keeps it in the read tier.

## Open items

1. Does apport's `apport-coredump-hook@.service` keep producing `.crash` files once
   `systemd-coredump` is installed? Verify on a VM before choosing which source the
   watcher prefers.
2. Does the Claude Desktop Linux beta install `.mcpb` extensions? Until that is verified,
   phase 3 can fall back to `linux-mcp-server` for read-only Desktop access.
