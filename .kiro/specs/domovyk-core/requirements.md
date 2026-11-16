# Requirements Document

## Introduction

Domovyk lets Claude look after an Ubuntu machine. This spec covers phase 1 of `DESIGN.md`, "Knowledge and read":
- the read-tier `domovyk` CLI, with facts about updates, drivers, crashes, logs, performance, disks, services and hardware, plus status and doctor summaries;
- Handoff_Scripts for every change;
- the six agent skills;
- the Claude Code plugin with its hooks and investigator subagent;
- per-user setup and removal;
- the agent launcher;
- the Debian package.

Out of scope for this spec:

- Any privileged code: the pkexec Helper, polkit actions, the system ledger and `domovyk undo` (phase 2).
- The crash watcher, the daily checkup timer, keyboard shortcuts and app-grid launchers (phase 2).
- The MCP server, the Desktop Extension, skills for agents other than Claude Code, PCP history and the GNOME Shell indicator (phase 3).
- Integration with Motanka.
- Publishing to chumak.

## Glossary

- **Supported_Release**: Ubuntu 24.04 LTS (`noble`) or Ubuntu 26.04 LTS (`resolute`), amd64, at any point release.
- **Host**: the Ubuntu installation Domovyk runs on.
- **CLI**: the `domovyk` dispatcher command.
- **Command**: one `domovyk-<group>-<action>` program under `libexec/commands/`, run as `domovyk <group> <action>`.
- **Command_Metadata**: the `# domovyk:<key>=<value>` header lines at the top of a Command (`summary`, `args`, `tier`, `examples`).
- **Tier**: the Command_Metadata field that says what a Command may change. `read` changes nothing. `user` changes only the invoking user's home folder.
- **Read_Command**: a Command whose Tier is `read`.
- **Fact_Output**: what a Read_Command prints: text by default, JSON with `--json`.
- **Source**: one external tool or file a Read_Command reads, such as `ubuntu-drivers`, `/var/crash` or the journal.
- **Unavailable_Source**: a Source that is not installed, not readable by the invoking user, or did not answer within its timeout.
- **Finding**: one problem reported by `domovyk doctor`, with an identifier, a severity (`info`, `warning`, `critical`), a title, evidence and a suggestion.
- **Secret**: a string that matches a Redaction_Rule.
- **Redaction_Rule**: one line of `share/redact.tsv`, giving a rule name and a regular expression.
- **Redactor**: the component that replaces every Secret in Fact_Output with `[redacted:<rule>]`.
- **Crash_Record**: one crash merged from apport (`/var/crash/*.crash`) and systemd-coredump (`coredumpctl`), with a stable identifier.
- **Handoff_Script**: a Bash script that Domovyk writes for the owner to read and run with `sudo`. Domovyk never runs it.
- **Handoff_Dir**: `~/.local/state/domovyk/handoff/`.
- **Skill**: a directory holding `SKILL.md` and its topic files under `share/agents/skills/`.
- **Plugin**: the Claude Code plugin `domovyk`, in the local Marketplace.
- **Marketplace**: the local Claude Code marketplace `domovyk`, at `share/claude/`.
- **Guard_Hook**: the Plugin's `PreToolUse` hook on the Bash tool.
- **Context_Hook**: the Plugin's `SessionStart` hook.
- **Investigator**: the Plugin's read-only subagent, `domovyk-investigator`.
- **Agent_Session**: a Claude Code session started by the Launcher, marked by `DOMOVYK_SESSION=1`.
- **Launcher**: the `domovyk agent` Command.
- **Workspace**: `~/.local/share/domovyk/workspace`, the folder where the Launcher starts Claude Code.
- **Setup**: the `domovyk setup claude` Command.
- **Unsetup**: the `domovyk unsetup` Command.
- **User_Ledger**: `~/.local/state/domovyk/ledger`, the record of every change Setup made to the user's home folder.
- **Package**: the Debian package `domovyk`.
- **Fingerprint**: a snapshot of Host state:
  - the installed package list with versions;
  - checksums of every file under `/etc`, `/usr`, `/var/lib` (excluding apt and dpkg caches) and each home folder;
  - `dconf dump /` per user;
  - enabled system and user units.

  It excludes each user's `~/.cache` and `~/.claude/`, which is Claude Code's own state. The one exception is `~/.claude/settings.json`, which is compared as JSON.
- **Test_VM**: a throwaway virtual machine started by `test/vm/`.

## Requirements

### Requirement 1: Supported releases and runtime

**User Story:** As an Ubuntu user on 24.04 LTS or 26.04 LTS, I want Domovyk to work on my release without extra setup, so that I can start using it right after installing the package.

#### Acceptance Criteria

1. WHEN the Package is installed on a Supported_Release THEN every Read_Command SHALL exit with code 0 on a fresh `fresh` and a fresh `gnome-snaps` Test_VM.
2. THE CLI SHALL run every Read_Command as the invoking user without `sudo`, `pkexec` or setuid programs.
3. IF a Source is an Unavailable_Source THEN THE Read_Command SHALL report that Source in its Fact_Output with the reason (`missing`, `permission`, `timeout`) and, for `missing`, the apt package that provides it.
4. IF a Source is an Unavailable_Source THEN THE Read_Command SHALL still exit with code 0 and report every other Source.
5. IF the CLI runs on a release that is not a Supported_Release THEN THE CLI SHALL print one warning line to stderr naming the detected release and continue.

### Requirement 2: Command discovery

**User Story:** As an agent, I want to discover every Domovyk command and its arguments from the command itself, so that I use the documented interface instead of guessing.

#### Acceptance Criteria

1. WHEN `domovyk commands` runs THEN THE CLI SHALL list every Command with its route, Tier and summary.
2. WHEN `domovyk commands --json` runs THEN THE CLI SHALL print a JSON document whose `commands` array holds one object per Command with `route`, `tier`, `summary`, `args` and `examples`.
3. WHEN `domovyk <group> --help` or `domovyk <group> <action> --help` runs THEN THE CLI SHALL print the matching Command_Metadata without running any Command.
4. THE CLI SHALL list in `domovyk commands --json` exactly the set of Commands present under `libexec/commands/`.
5. IF a Command lacks `summary` or `tier` metadata, or its Tier is not `read` or `user`, THEN THE unit test suite SHALL fail naming that Command.
6. IF `domovyk` is given an unknown group or action THEN THE CLI SHALL exit with code 2 and print the closest existing routes.

### Requirement 3: Read tier changes nothing

**User Story:** As the owner, I want reading facts to never change my system, so that I can let the agent investigate without approving each step.

#### Acceptance Criteria

1. For any Read_Command and any arguments it accepts, THE Fingerprint taken after the Read_Command runs SHALL equal the Fingerprint taken before it, apart from paths under the invoking user's `~/.cache/domovyk`.
2. THE Read_Commands SHALL open no network connection, except `domovyk crash backtrace --symbols`.
3. WHEN a Read_Command calls a Source THEN THE CLI SHALL stop that call after 10 seconds and treat the Source as an Unavailable_Source with reason `timeout`.
4. WHEN any Read_Command runs without `--symbols` THEN it SHALL finish within 30 seconds on a Test_VM.

### Requirement 4: Output contract

**User Story:** As an agent, I want every command's output in a stable shape, so that I can rely on fields instead of parsing prose.

#### Acceptance Criteria

1. WHEN a Read_Command runs without `--json` THEN THE CLI SHALL print text with at most 100 columns per line.
2. WHEN a Read_Command runs with `--json` THEN THE CLI SHALL print exactly one JSON document that `jq` parses.
3. THE JSON document of every Read_Command SHALL contain `schema` (`domovyk.<group>.v<N>`), `generated` (RFC 3339 time), `host` (release codename) and `unavailable` (a list of Unavailable_Sources).
4. THE CLI SHALL exit with code 0 on success, 1 on an internal failure, and 2 on a usage error.
5. IF a Read_Command fails internally THEN THE CLI SHALL print one line to stderr naming the Command and the failing step.
6. For any Read_Command, the set of top-level JSON keys SHALL equal the set documented for its schema in `design.md`.

### Requirement 5: Redaction

**User Story:** As the owner, I want secrets kept out of what the agent reads, so that tokens and passwords in logs are not sent to the model.

#### Acceptance Criteria

1. THE Redactor SHALL replace every Secret in Fact_Output with `[redacted:<rule>]`, by default.
2. For any text that contains a string matching a Redaction_Rule, THE Fact_Output produced from it SHALL not contain that string.
3. For any text that contains no Secret, THE Redactor SHALL return it unchanged.
4. WHEN a Read_Command runs with `--raw` THEN THE CLI SHALL skip redaction and print `unredacted output` as the first line of stderr.
5. THE Redaction_Rules SHALL cover at least:
   - bearer and API tokens;
   - private key blocks;
   - passwords in URLs;
   - `password=`, `passwd=`, `secret=` and `token=` assignments;
   - Wi-Fi PSKs;
   - email addresses;
   - AWS access key IDs;
   - GitHub, Anthropic and OpenAI key prefixes.
6. IF `share/redact.tsv` is missing or contains an invalid regular expression THEN THE Read_Command SHALL exit with code 1 without printing any Fact_Output.

### Requirement 6: Status

**User Story:** As the owner or an agent, I want a one-screen summary of the machine's health, so that I see what needs attention without running every command.

#### Acceptance Criteria

1. WHEN `domovyk status` runs THEN THE CLI SHALL print at most 40 lines covering:
   - reboot required;
   - failed units;
   - pending updates by source;
   - crashes in the last 7 days;
   - the fullest filesystem;
   - the most severe Finding.
2. WHEN `domovyk status --brief` runs THEN THE CLI SHALL print at most 2,000 characters.
3. WHEN `domovyk status --json` runs THEN THE CLI SHALL include every Finding that `domovyk doctor --json` reports.
4. IF every Source of `domovyk status` is an Unavailable_Source THEN THE CLI SHALL print `status unknown` and the list of Unavailable_Sources.

### Requirement 7: Doctor

**User Story:** As the owner, I want concrete problems listed with evidence and a next step, so that I know what to fix first.

#### Acceptance Criteria

1. WHEN `domovyk doctor` runs THEN THE CLI SHALL report each Finding with its identifier, severity, title, evidence and suggestion.
2. THE CLI SHALL sort Findings by severity, `critical` first, then by identifier.
3. THE doctor SHALL check at least:
   - a reboot pending for more than 3 days;
   - failed system or user units;
   - any filesystem over 90 % of its blocks or inodes;
   - a drive whose SMART state is failing;
   - an `ubuntu-drivers` candidate not installed;
   - broken or half-configured packages;
   - held packages;
   - more than 3 crashes of one program in 7 days;
   - security updates pending for more than 7 days;
   - the journal over 4 GB;
   - an unattended-upgrades run that failed.
4. THE suggestion of every Finding SHALL name either a Read_Command or `domovyk handoff`.
5. WHEN `domovyk doctor --exit-code` runs THEN THE CLI SHALL exit with code 0 when no Finding is above `info`, 10 for `warning` and 20 for `critical`.

### Requirement 8: Update facts

**User Story:** As the owner, I want to know what updates are pending and why a reboot is needed, so that I can keep the machine current with confidence.

#### Acceptance Criteria

1. WHEN `domovyk updates` runs THEN THE CLI SHALL list pending apt updates with package, installed and candidate versions, origin, whether it is a security update, and phasing state.
2. WHEN `domovyk updates` runs THEN THE CLI SHALL list pending snap refreshes, flatpak updates and fwupd firmware updates.
3. WHEN `/run/reboot-required` exists THEN THE CLI SHALL report it with its modification time and the packages listed in `/run/reboot-required.pkgs`.
4. WHEN `domovyk updates` runs THEN THE CLI SHALL report held packages, broken packages, enabled third-party apt sources and PPAs, and the time and result of the last unattended-upgrades run.
5. THE CLI SHALL compute pending apt updates from the local package lists without refreshing them.
6. IF the local apt lists are older than 24 hours THEN THE CLI SHALL report their age and suggest `domovyk handoff` for `apt update`.

### Requirement 9: Driver facts

**User Story:** As the owner, I want to see which devices lack a driver and what Ubuntu offers for them, so that I can fix hardware that does not work.

#### Acceptance Criteria

1. WHEN `domovyk drivers` runs THEN THE CLI SHALL list each PCI and USB device with its vendor and product IDs, name and kernel driver in use.
2. WHEN `domovyk drivers` runs THEN THE CLI SHALL list every candidate package `ubuntu-drivers list` reports, marking which are installed and which are recommended.
3. WHEN `domovyk drivers` runs THEN THE CLI SHALL report DKMS module status, Secure Boot state and whether a MOK enrolment is pending.
4. WHEN `domovyk drivers` runs THEN THE CLI SHALL list fwupd devices with their firmware versions.
5. IF a DKMS module failed to build for the running kernel THEN THE CLI SHALL report the module, the kernel and the path to the build log.

### Requirement 10: Crash facts

**User Story:** As the owner, I want crashes listed and explained from evidence, so that I learn why a program died without exposing its memory.

#### Acceptance Criteria

1. WHEN `domovyk crash list` runs THEN THE CLI SHALL list every Crash_Record readable by the invoking user from `/var/crash` and from `coredumpctl`, newest first, with identifier, time, program, signal and source.
2. WHEN one crash appears in both apport and systemd-coredump THEN THE CLI SHALL list it once with both sources.
3. WHEN `domovyk crash info <id>` runs THEN THE CLI SHALL print:
   - the executable;
   - the package and version;
   - the command line;
   - the signal;
   - the time;
   - the number of earlier crashes of the same executable in 30 days;
   - whether an OOM kill was logged within 60 seconds before the crash;
   - apt history entries from the 24 hours before the crash.
4. WHEN `domovyk crash backtrace <id>` runs THEN THE CLI SHALL unpack the core into a new `mktemp -d` directory with mode 0700 and print the backtrace of every thread.
5. WHEN `domovyk crash backtrace <id>` finishes, fails or is interrupted with SIGINT or SIGTERM THEN THE CLI SHALL delete the directory it created.
6. THE CLI SHALL print no core memory contents other than backtraces, loaded library paths and signal information.
7. WHEN `domovyk crash backtrace <id> --symbols` runs THEN THE CLI SHALL fetch debug symbols from the debuginfod URLs configured in `/etc/debuginfod`.
8. IF a frame cannot be symbolized THEN THE CLI SHALL print its address and library, never an invented function name.
9. IF `<id>` matches no Crash_Record THEN THE CLI SHALL exit with code 2 and print `domovyk crash list` as the next step.

### Requirement 11: Log facts

**User Story:** As the owner, I want the errors that matter from the journal and kernel, so that I find the cause of a problem without reading thousands of lines.

#### Acceptance Criteria

1. WHEN `domovyk logs` runs THEN THE CLI SHALL print journal entries of priority `err` or more severe from the current boot, grouped by unit and identifier with a count and the first and last occurrence.
2. WHEN `domovyk logs --boot -1` runs THEN THE CLI SHALL report the same for the previous boot, and whether it ended in a clean shutdown.
3. WHEN `domovyk logs --unit <unit>` runs THEN THE CLI SHALL print at most 200 entries of that unit, newest last.
4. WHEN `domovyk logs` runs THEN THE CLI SHALL report OOM kills, kernel warnings and oopses, failed suspend and resume cycles, and journal disk usage.
5. IF the invoking user can read only their own journal THEN THE CLI SHALL report the system journal as an Unavailable_Source with reason `permission` and name the `adm` and `systemd-journal` groups.

### Requirement 12: Performance facts

**User Story:** As the owner, I want to know what is slowing the machine down, so that I can address the actual bottleneck.

#### Acceptance Criteria

1. WHEN `domovyk perf` runs THEN THE CLI SHALL report:
   - load averages and CPU count;
   - memory, swap and zram use;
   - CPU, memory and IO pressure stall information;
   - the 10 processes using the most CPU;
   - the 10 processes using the most memory.
2. WHEN `domovyk perf` runs THEN THE CLI SHALL report thermal zone temperatures, any CPU thermal throttling events since boot, and the active power profile.
3. WHEN `domovyk perf --boot` runs THEN THE CLI SHALL report the total boot time and the 10 slowest units from `systemd-analyze`.
4. WHEN `domovyk perf --sample <seconds>` runs with a value from 1 to 10 THEN THE CLI SHALL report CPU and IO utilisation averaged over that interval.
5. IF `--sample` is given a value outside 1 to 10 THEN THE CLI SHALL exit with code 2.

### Requirement 13: Disk facts

**User Story:** As the owner, I want to see where disk space goes and what can be reclaimed safely, so that I can free space without deleting the wrong thing.

#### Acceptance Criteria

1. WHEN `domovyk disk` runs THEN THE CLI SHALL list every mounted local filesystem with its size, block use and inode use.
2. WHEN `domovyk disk` runs THEN THE CLI SHALL report reclaimable bytes per category:
   - the apt cache;
   - the journal beyond 500 MB;
   - disabled snap revisions;
   - kernels other than the running one and the newest one;
   - the user's trash;
   - the user's `~/.cache`;
   - unused Docker images and build cache.
3. THE CLI SHALL attach a risk level (`none`, `low`, `medium`) and a one-line consequence to every reclaimable category.
4. WHEN `domovyk disk usage <path>` runs THEN THE CLI SHALL list the 20 largest entries under that path, skipping paths the user cannot read and other filesystems.
5. WHEN `domovyk disk` runs THEN THE CLI SHALL report each drive's SMART health from UDisks2 and whether the `fstrim.timer` unit is enabled.
6. IF `domovyk disk usage` has not finished after 25 seconds THEN THE CLI SHALL print partial results marked `incomplete`.

### Requirement 14: Service and hardware facts

**User Story:** As the owner, I want failed services and hardware details in one place, so that the agent can relate a symptom to its component.

#### Acceptance Criteria

1. WHEN `domovyk services` runs THEN THE CLI SHALL list failed system units and failed user units with their result and the last 10 journal lines of each.
2. WHEN `domovyk services status <unit>` runs THEN THE CLI SHALL print the unit's state, enablement, main PID, memory use, restart count and last 20 journal lines.
3. WHEN `domovyk hw` runs THEN THE CLI SHALL report:
   - the CPU model;
   - the GPUs with their drivers;
   - the memory size;
   - battery design and full capacity with health in percent;
   - the firmware vendor and version;
   - the machine model.
4. IF the Host has no battery THEN THE CLI SHALL omit battery fields and report no error.

### Requirement 15: Handoff scripts

**User Story:** As the owner, I want every system change prepared as a script I read and run myself, so that nothing runs as root without my eyes on it.

#### Acceptance Criteria

1. WHEN `domovyk handoff create --title <title>` reads a script on stdin THEN THE CLI SHALL write a Handoff_Script to the Handoff_Dir with mode 0600, named `<UTC time>-<slug>.sh`.
2. THE Handoff_Script SHALL start with `#!/bin/bash`, `set -euo pipefail`, a comment block holding the title, creation time and generating user, and the script body unchanged.
3. WHEN a Handoff_Script is written THEN THE CLI SHALL print its path and the line `! sudo bash <path>`.
4. THE CLI SHALL never execute a Handoff_Script.
5. WHEN `domovyk handoff list` runs THEN THE CLI SHALL list Handoff_Scripts newest first with title and creation time.
6. IF the script on stdin is empty, longer than 64 KiB, or fails `bash -n` THEN THE CLI SHALL exit with code 2 and write no file.
7. THE Tier of `domovyk handoff create` SHALL be `user`.

### Requirement 16: Skills

**User Story:** As an agent, I want Ubuntu-specific methods for each kind of problem, so that I investigate and propose changes the way an experienced Ubuntu administrator would.

#### Acceptance Criteria

1. THE Package SHALL ship the Skills `ubuntu`, `diagnose-crash`, `drivers`, `updates`, `disk` and `performance`.
2. THE frontmatter of every `SKILL.md` SHALL contain only the keys `name`, `description`, `license`, `compatibility`, `metadata` and `allowed-tools`.
3. THE `description` of every Skill SHALL be at most 1,024 characters and name its trigger topics.
4. For any `domovyk` route that a Skill mentions, THE route SHALL exist in `domovyk commands --json`.
5. THE `ubuntu` Skill SHALL state:
   - the decision order: Read_Command, then Handoff_Script;
   - that the agent never runs `sudo` or `pkexec`;
   - that every change is shown as a plan and approved before a Handoff_Script is written;
   - that files owned by dpkg under `/usr` are never edited.
6. THE `diagnose-crash` Skill SHALL require separating proven facts from inferences, ruling out OOM first, and reporting nothing upstream without the owner's explicit yes.
7. IF a Skill references a file that does not exist in its directory THEN THE unit test suite SHALL fail naming the Skill and the file.

### Requirement 17: Claude Code plugin

**User Story:** As a Claude Code user, I want Domovyk's skills, hooks and subagent installed as one plugin, so that they load together and update with the package.

#### Acceptance Criteria

1. THE Marketplace and the Plugin SHALL pass `claude plugin validate --strict`.
2. WHEN the Plugin is enabled THEN THE Skills SHALL be available as `domovyk:<skill>`.
3. THE Investigator SHALL list tools that exclude `Edit`, `Write`, `NotebookEdit` and `Agent`.
4. THE Plugin SHALL load its files in place from `/usr/share/domovyk/claude`, so that upgrading the Package upgrades the Plugin.
5. THE Plugin SHALL contain no `bin/` directory.

### Requirement 18: Guard hook

**User Story:** As the owner, I want the agent stopped before it runs privileged or destructive commands, so that a mistake cannot hang the session or damage the system.

#### Acceptance Criteria

1. WHEN the Bash tool is about to run a command that invokes `sudo`, `pkexec`, `su` or `doas` anywhere in a pipeline, list, subshell or command substitution THEN THE Guard_Hook SHALL deny it with a reason that names `domovyk handoff`.
2. WHEN the Bash tool is about to run a command matching the destructive list in `design.md` THEN THE Guard_Hook SHALL deny it with a reason naming the matched rule.
3. For any command that invokes neither a privilege tool nor an entry of the destructive list, THE Guard_Hook SHALL return no decision, leaving the normal permission flow in place.
4. WHILE the hook runs inside the Investigator THEN THE Guard_Hook SHALL deny every Bash command other than Read_Commands.
5. IF the Guard_Hook cannot parse its input THEN THE Guard_Hook SHALL deny the command with the reason `domovyk guard could not parse the command`.
6. THE Guard_Hook SHALL decide within 100 ms at the 95th percentile on a Test_VM.

### Requirement 19: Session context

**User Story:** As an agent started for system care, I want the machine's state at the start of the session, so that I begin from facts instead of spending turns discovering them.

#### Acceptance Criteria

1. WHEN an Agent_Session starts, is cleared or is compacted THEN THE Context_Hook SHALL print the output of `domovyk status --brief`.
2. WHEN a Claude Code session that is not an Agent_Session starts THEN THE Context_Hook SHALL print nothing.
3. IF `domovyk status --brief` has not finished within 5 seconds THEN THE Context_Hook SHALL print `domovyk status unavailable (timeout)` and exit with code 0.

### Requirement 20: Setup and removal of the user integration

**User Story:** As the owner, I want one command to connect Domovyk to Claude Code and one to disconnect it, so that I can try it without leaving traces.

#### Acceptance Criteria

1. WHEN Setup runs THEN it SHALL register the Marketplace, install the Plugin at user scope, and add the Read_Command allow rules to `~/.claude/settings.json`.
2. WHEN Setup changes a file in the user's home folder THEN it SHALL first record the change in the User_Ledger.
3. WHEN Setup runs a second time THEN it SHALL change no file and exit with code 0.
4. WHEN Unsetup runs THEN it SHALL reverse every User_Ledger entry, newest first, and then delete the User_Ledger.
5. For any `~/.claude/settings.json` that holds valid JSON before Setup, THE file after Setup and then Unsetup SHALL be equal to it as JSON.
6. IF the `claude` command is missing THEN Setup SHALL exit with code 1, print where to install Claude Code, and change no file.
7. IF `~/.claude/settings.json` is not valid JSON THEN Setup SHALL exit with code 1 and change no file.
8. IF Setup is interrupted THEN running Unsetup SHALL reverse the entries recorded so far.
9. WHEN Setup runs THEN it SHALL write a self-contained copy of Unsetup to `~/.local/state/domovyk/unsetup`, which works when the Package is no longer installed.

### Requirement 21: Agent launcher

**User Story:** As the owner, I want one command that opens Claude ready to look after the machine, so that I do not have to set up the context each time.

#### Acceptance Criteria

1. WHEN `domovyk agent` runs THEN THE Launcher SHALL create the Workspace from `share/workspace` if missing and start `claude` there with `DOMOVYK_SESSION=1`.
2. WHEN `domovyk agent` runs without `--inline` in a graphical session THEN THE Launcher SHALL start Claude Code in a new terminal through `xdg-terminal-exec`.
3. WHEN `domovyk agent prompt <text>` runs THEN THE Launcher SHALL start Claude Code with `<text>` as the first message.
4. WHEN `domovyk agent crash <id>` runs THEN THE Launcher SHALL start Claude Code with a first message that holds the Crash_Record's identifier, program, signal and time and names the `domovyk:diagnose-crash` Skill.
5. THE Launcher SHALL pass `--permission-mode default` unless `~/.config/domovyk/agent.conf` sets `permission_mode=auto`.
6. IF `claude` is not installed THEN THE Launcher SHALL exit with code 1 and print where to install Claude Code.
7. IF the Plugin is not enabled THEN THE Launcher SHALL print `run: domovyk setup claude` and exit with code 1.

### Requirement 22: Packaging and removal

**User Story:** As the owner, I want Domovyk installed and removed by apt, so that it leaves nothing behind.

#### Acceptance Criteria

1. THE Package SHALL build as `Architecture: all` and pass `lintian` with no errors or warnings.
2. THE Package SHALL own every file it installs under `/usr`.
3. THE Package SHALL write no file outside `/usr` during installation.
4. WHEN Unsetup has run for every user and the Package is purged THEN THE Fingerprint SHALL equal the Fingerprint taken before the Package was installed.
5. IF the Package is removed while any user has a User_Ledger THEN THE Package's `prerm` script SHALL print each such user and the command `bash ~/.local/state/domovyk/unsetup`, and change no file in any home folder.

### Requirement 23: Test isolation

**User Story:** As a contributor, I want all development testing confined to throwaway VMs, so that my own machine is never changed by Domovyk's development.

#### Acceptance Criteria

1. THE test scripts that install, set up or remove anything SHALL run only where `systemd-detect-virt` reports a virtual machine.
2. IF such a test script runs where `systemd-detect-virt` reports `none` THEN it SHALL exit with code 1 before changing anything.
3. THE VM harness SHALL write on the development host only under the repository folder and `~/.cache/domovyk-vm/`.
4. THE test suite SHALL never run `sudo` on the development host.
