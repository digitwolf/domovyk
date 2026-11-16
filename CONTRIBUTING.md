# Contributing to Domovyk

Thank you for helping. Domovyk is young, so every bug report, skill
improvement and pull request makes a real difference. This guide gets you from
zero to a merged change.

## The one rule

**Never test Domovyk on your own computer.** Domovyk looks after real systems,
so all development testing happens in throwaway virtual machines. The repo
includes a QEMU/KVM harness that does this for you. CI runs the same tests on
every pull request. Running *read* commands from your checkout is fine, because
they change nothing (see [tiers](#tiers)).

## Ways to help

| You have… | Do this |
|---|---|
| 5 minutes | Run `domovyk commands` or any read command and [open an issue](https://github.com/digitwolf/domovyk/issues/new/choose) when the output is wrong, confusing or too long. Include `domovyk version`. |
| Ubuntu know-how | Improve a skill in `share/claude/plugins/domovyk/skills/`. Skills are plain Markdown: how to diagnose a driver problem, when a cleanup is safe, what a log line means. |
| An odd machine | Send a fixture. NVIDIA, hybrid graphics, unusual disks and old firmware are all welcome. See [fixtures](#fixtures). |
| An evening | Pick an issue labelled `good first issue`, or add a `doctor` check (one `jq` file). |
| A bigger idea | Open a discussion first. Bigger features go through the spec (see [How changes are planned](#how-changes-are-planned)). |

## Getting set up

You need an Ubuntu 24.04 or 26.04 machine (or any Linux with KVM) with:

```bash
sudo apt install git jq shellcheck qemu-system-x86 qemu-utils
```

and your user in the `kvm` group (`sudo usermod -aG kvm $USER`, then log in
again). Then:

```bash
git clone https://github.com/digitwolf/domovyk.git
cd domovyk
make lint            # shellcheck, safe anywhere
DOMOVYK_ROOT=$PWD bin/domovyk commands   # read commands are safe to run from the checkout
test/run-all         # unit tests inside a throwaway 26.04 VM
test/run-all --release noble             # the same on 24.04
```

The first `test/run-all` downloads and verifies an Ubuntu cloud image (about
600 MB) into `~/.cache/domovyk-vm/`. Later runs reuse it. Each run boots a
copy-on-write overlay and deletes it afterwards.

## How the code is laid out

```
bin/domovyk                 the dispatcher: finds domovyk-<group>-<action> and runs it
libexec/commands/           one executable per command
libexec/lib/domovyk.sh      shared helpers: sources with timeouts, the JSON envelope, output
libexec/render/<name>.jq    turns a command's JSON into its text view
libexec/checks/<id>.jq      doctor checks
libexec/py/                 small Python helpers (standard library only)
libexec/hooks/              Claude Code hooks (the guard and the session context)
share/claude/               the Claude Code plugin: skills, the investigator agent, hooks
test/unit/                  bats tests and fixtures
test/vm/                    the VM harness
.kiro/                      the spec: requirements, design, tasks, and project steering
```

### Tiers

Every command declares a tier in its header:

- **`read`** commands only look. They never write outside a temporary
  directory or `~/.cache/domovyk`, and never need root.
- **`user`** commands change only the user's home folder, such as writing a
  handoff script.

Domovyk has no command that runs as root. Changes to the system are handoff
scripts that the user runs. Phase 2 adds approved actions through polkit.

## Adding a read command

1. **Create `libexec/commands/domovyk-<group>[-<action>]`** with the metadata
   header:

   ```bash
   #!/bin/bash
   # domovyk:summary=One line that says what it shows
   # domovyk:tier=read
   # domovyk:args=[--json] [--raw]
   # domovyk:examples=domovyk thing | domovyk thing --json
   set -euo pipefail
   source "$DOMOVYK_LIBEXEC/lib/domovyk.sh"
   dv_init domovyk.thing.v1 "" "$@"
   ```

2. **Gather facts with the helpers, never directly:**
   - `dv_source <name> --package <apt-pkg> -- <cmd…>` runs a program with a
     timeout. A missing program, a timeout or a permission error is recorded
     for you.
   - `dv_path /proc/…` reads a file, so tests can swap in a fixture tree.
   - A missing optional tool is never an error. It becomes an entry under
     `unavailable` with the package that provides it.

3. **Build one JSON body and call `dv_emit`.** It adds the envelope, redacts
   secrets, and prints JSON or renders text with
   `libexec/render/<group>.jq`. Emit raw numbers (bytes, percent); the renderer
   formats them. Text lines must fit in 100 columns (`include "lib"; … | fit`).

4. **Document the schema.** Add its top-level keys to
   `test/unit/schemas/keys.tsv`, and a field-level `jq` predicate to
   `test/unit/schemas/<schema>.jq`.

5. **Test it** in `test/unit/<group>.bats` with fixtures: no real system
   output in assertions, a fixture for each edge case (tool missing, permission
   denied, empty, huge), and the envelope check.

6. **Mention it in a skill** if the agent should use it, and run the skills
   lint.

### Fixtures

Tests never depend on the machine they run on:

- **Programs** are replaced by `test/unit/fixtures/bin/fake`, which replays
  `test/unit/fixtures/<tool>/<case>/<args>`.
- **Files** under `/proc`, `/sys`, `/run`, `/var` and `/etc` are read from
  `test/unit/fixtures/sysroot/<case>/`.

To record real output from a machine, read-only and redacted:

```bash
tools/capture-fixtures my-case ubuntu-drivers list
tools/capture-fixtures --file my-case /proc/pressure/memory
```

**Review every captured file before committing it.** Remove anything personal
that redaction cannot know about: hostnames, user names in paths, serial
numbers, MAC and IP addresses, Wi-Fi network names.

## Style

- **Bash:** `set -euo pipefail`, `shellcheck` clean, formatted with
  `shfmt -i 2 -ci`. Quote everything. Quote associative-array subscripts that
  contain `-` or `/`.
- **Python:** standard library only, run with `python3 -I`, compatible with
  Python 3.12.
- **Dependencies:** a new one needs a reason and a line in
  `.kiro/steering/tech.md`. Domovyk depends only on what a fresh Ubuntu
  install has, plus `jq`.
- **Output:** short, plain and specific. Numbers, not adjectives.

## Commits and pull requests

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
  `feat(drivers): report DKMS build failures`, `fix(guard): catch sudo inside xargs`,
  `docs(skills): explain phased updates`.
- Keep pull requests focused: one command, one skill or one fix.
- CI must be green: shellcheck plus unit tests on 24.04 and 26.04.
- If you change behaviour, update the spec in the same pull request (next
  section).

## How changes are planned

Domovyk uses spec-driven development (the [Kiro](https://kiro.dev) format, but
any editor works):

- [`requirements.md`](.kiro/specs/domovyk-core/requirements.md) says *what*,
  as testable [EARS](https://alistairmavin.com/ears/) statements.
- [`design.md`](.kiro/specs/domovyk-core/design.md) says *how*.
- [`tasks.md`](.kiro/specs/domovyk-core/tasks.md) is the plan. Every task names
  the requirements it covers.

Small fixes don't need a spec change. A new command, a new rule for the guard
or a change to what is redacted does: add or adjust the requirement, then the
design, then the code and tests. Requirements are never renumbered; new ones
are appended.

## Security

The guard and the redactor are security features. If you find a way to get
`sudo`, a destructive command or a secret past them, please **don't** open a
public issue. Follow [SECURITY.md](SECURITY.md).

## Code of conduct

Be kind and assume good intent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
