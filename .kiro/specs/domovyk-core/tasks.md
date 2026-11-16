# Implementation Plan

Rules for every task:
- Nothing is built, installed, set up, removed or run with `sudo` on the development host.
- "26.04 VM" and "24.04 VM" mean throwaway Test_VMs started by `test/vm/`.
- Read-tier commands may run on the host from the working tree (`DOMOVYK_ROOT=$PWD bin/domovyk …`). Anything they capture becomes a fixture only after redaction and review.
- No task runs `git push` or publishes to the apt repo.

- [ ] 1. VM test harness
- [ ] 1.1 Port the harness core from Motanka `d076748`
  - Copy `test/vm/{lib.sh,up,down,run,push}`. Rename `MV_`→`DV_` and `MOTANKA_VM_`→`DOMOVYK_VM_`, move the cache to `~/.cache/domovyk-vm/`, and drop the Arch parity, `kde` and `multiuser` code and the Motanka guards.
  - Add `dv_require_guest` (exit 1 when `systemd-detect-virt` prints `none`) and `DOMOVYK_VM_IMAGE_DIR`.
  - _Requirements: 23.1, 23.2, 23.3_
- [ ] 1.2 Images: `resolute` and `noble`, variants `fresh` and `gnome-snaps`
  - Port `test/vm/image`. Keep `variants/gnome-snaps.sh` identical to Motanka's so base images are interchangeable; add an emulated NVMe data disk in `lib.sh`.
  - Builds and boots run in a 26.04 VM and a 24.04 VM.
  - _Requirements: 1.1, 23.3_
- [ ] 1.3 Fingerprint
  - Port `test/vm/fingerprint` and `tools/fpdiff.py`. Cut the Allowlist down to the Glossary's Fingerprint exclusions (`~/.cache`, `~/.claude/` except `settings.json`, compared as JSON).
  - Add `test/unit/fpdiff.bats`.
  - _Requirements: 3.1, 22.4_
- [ ] 1.4 Runner, lint and unit-test plumbing
  - Create `test/run-all` (`--release noble`), `.shellcheckrc`, and `test/unit/run`. Vendor `bats-core`, `bats-support` and `bats-assert` under `test/bats/`.
  - Add `test/unit/harness.bats`: the harness refuses outside a VM, and writes only under the repo and `~/.cache/domovyk-vm/`.
  - _Requirements: 23.1, 23.2, 23.3, 23.4_

- [ ] 2. Checkpoint: run `test/run-all` (lint only so far), confirm a 26.04 and a 24.04 VM boot and tear down, then stop for questions
  - _Requirements: 23.1, 23.3_

- [ ] 3. Feasibility spikes (each runs in a test VM and writes its result into `design.md`, Open Questions)
- [ ] 3.1 S1: Claude Code plugin mechanics in a 26.04 `gnome-snaps` VM
  - Install Claude Code with its native installer inside the VM. Answer every S1 question with a throwaway plugin under `spikes/s1/`.
  - Record the minimum Claude Code version, the permission-rule form and the `agent_type` value in `design.md`.
  - _Requirements: 17.1, 17.2, 18.4, 19.1, 20.1, 20.5, 21.7_
- [ ] 3.2 S2: Crash sources in 26.04 and 24.04 `gnome-snaps` VMs
  - Inject `kill -SEGV`, with and without `systemd-coredump`. Record the `/var/crash` contents, the `coredumpctl` output, `apport-unpack` run as the user, and gdb with debuginfod.
  - Keep scripts in `spikes/s2/`.
  - _Requirements: 10.1, 10.2, 10.4, 10.7_
- [ ] 3.3 S3: Sources without root in 26.04 and 24.04 VMs
  - Check UDisks2 SMART on the NVMe disk, apt phasing output, `fwupdmgr` and `ubuntu-drivers` in a VM, and `xdg-terminal-exec` on 24.04. Record the results and adjust the Sources table.
  - _Requirements: 8.1, 9.2, 9.4, 13.5, 21.2_

- [ ] 4. Checkpoint: review the spike results with the owner and update `design.md` sections they affect, then stop for questions
  - _Requirements: 17.1, 10.1, 13.5_

- [ ] 5. Foundations
- [ ] 5.1 Dispatcher, Command_Metadata, `commands` and `version`
  - Create `bin/domovyk`, `libexec/commands/domovyk-commands` and `domovyk-version`, with route resolution, the default-action table, suggestions for unknown routes, `--help` and the release warning.
  - Add `test/unit/cli.bats` and `test/unit/metadata.bats`.
  - _Requirements: 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 4.4_
- [ ] 5.2 Shared library and Envelope
  - Create `libexec/lib/domovyk.sh` with `dv_init`, `dv_have`, `dv_source` (timeouts), `dv_readable`, `dv_mktemp_dir`, `dv_emit`, `dv_die`, `dv_usage` and the Facts_Cache.
  - Add `test/unit/lib.bats` (timeout with a 15 s fake, missing tool, permission) and `test/unit/schemas.bats` with the Envelope predicate.
  - _Requirements: 1.2, 1.3, 1.4, 3.3, 4.2, 4.3, 4.5, 4.6_
- [ ] 5.3 Redactor
  - Create `libexec/py/redact.py` and `share/redact.tsv` with the rules in `design.md`.
  - Add `test/unit/py/test_redact.py` (seeded properties: secrets removed, clean text unchanged, idempotent) and `test/unit/redact.bats` (`--raw` line, missing or invalid rules file).
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_
- [ ] 5.4 Fake_Bin and fixture capture
  - Create `test/unit/fixtures/bin/` with fakes that replay `fixtures/<tool>/<case>` and honour `FAKE_CASE`. Create `tools/capture-fixtures`, which runs Sources read-only on a host and pipes them through the Redactor.
  - Capture the first fixtures from the development host, review them for personal data, and commit only reviewed files.
  - _Requirements: 1.3, 5.1_

- [ ] 6. Checkpoint: run `test/run-all` in a 26.04 VM, then stop for questions
  - _Requirements: 2.4, 4.6, 5.2_

- [ ] 7. Facts (one wave; each task owns its command, renderer, schema predicate and bats file)
- [ ] 7.1 `domovyk updates`
  - Create `libexec/commands/domovyk-updates`, `libexec/render/updates.jq`, `test/unit/schemas/updates.jq` and `test/unit/updates.bats`. Cases: none pending, security pending, phased, held, broken, stale lists, reboot required with packages, unattended-upgrades failure, fwupd missing.
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6_
- [ ] 7.2 `domovyk drivers`
  - Create `domovyk-drivers`, `render/drivers.jq`, `schemas/drivers.jq` and `drivers.bats`. Cases: the IPU6 candidate, a DKMS build failure with `make.log`, Secure Boot on with a MOK pending, no `ubuntu-drivers`.
  - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_
- [ ] 7.3 `domovyk crash list` and `crash info`
  - Create `libexec/py/apport_crash.py`, `domovyk-crash-list`, `domovyk-crash-info`, `render/crash.jq`, the schema predicates and `crash.bats`. Cases: apport only, coredump only, merged, unreadable file, OOM within 60 s, apt history in 24 h, unknown id.
  - _Requirements: 10.1, 10.2, 10.3, 10.6, 10.9_
- [ ] 7.4 `domovyk crash backtrace`
  - Create `domovyk-crash-backtrace` (temp directory with traps, gdb batch, frame parser, `--symbols`) and `crash-backtrace.bats`, using a fake gdb and fake `apport-unpack`. Cases: unsymbolized frames, `kill -INT` mid-run leaves no directory, no network use without `--symbols`.
  - _Requirements: 3.2, 10.4, 10.5, 10.6, 10.7, 10.8_
- [ ] 7.5 `domovyk logs`
  - Create `domovyk-logs` (`--boot`, `--unit`), `render/logs.jq`, the schema predicates and `logs.bats`. Cases: grouped errors, previous boot unclean, OOM, a kernel oops, suspend failure, user-only journal access.
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_
- [ ] 7.6 `domovyk perf`
  - Create `domovyk-perf` (`--boot`, `--sample`), `render/perf.jq`, `schemas/perf.jq` and `perf.bats`. Cases: pressure, throttling, no power-profiles-daemon, sample bounds.
  - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5_
- [ ] 7.7 `domovyk disk` and `disk usage`
  - Create `domovyk-disk`, `domovyk-disk-usage`, `render/disk.jq`, the schema predicates and `disk.bats`. Cases: a full filesystem, every reclaimable category with risk, SMART failing on UDisks2, no Docker access, a `du` timeout marked incomplete.
  - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5, 13.6_
- [ ] 7.8 `domovyk services` and `domovyk hw`
  - Create `domovyk-services`, `domovyk-services-status`, `domovyk-hw`, `render/services.jq`, `render/hw.jq`, the schema predicates and `services.bats` and `hw.bats`. Cases: failed system and user units, unit status, no battery, no serials in output.
  - _Requirements: 14.1, 14.2, 14.3, 14.4_

- [ ] 8. Checkpoint: run `test/run-all` in a 26.04 VM, run every Read_Command on the host from the working tree and compare with reality, then stop for questions
  - _Requirements: 1.1, 3.4, 4.1_

- [ ] 9. Summaries and handoff
- [ ] 9.1 Doctor and Checks
  - Create `domovyk-doctor`, `libexec/checks/*.jq` (the 13 Checks), `render/doctor.jq` and `doctor.bats` with a fixture facts set per Check, plus sorting and `--exit-code`.
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_
- [ ] 9.2 Status
  - Create `domovyk-status` (`--brief`, parallel collection and the Facts_Cache), `render/status.jq` and `status.bats`. Cases: 40-line cap, 2,000-character cap, findings in JSON, every Source unavailable.
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
- [ ] 9.3 Handoff
  - Create `domovyk-handoff-create`, `domovyk-handoff-list`, `domovyk-handoff-show`, `render/handoff.jq` and `handoff.bats`. Cases: header, mode 0600, the `! sudo bash` line, empty input, 64 KiB limit, `bash -n` failure, never executed.
  - _Requirements: 15.1, 15.2, 15.3, 15.4, 15.5, 15.6, 15.7_

- [ ] 10. Checkpoint: run `test/run-all` in a 26.04 VM, then stop for questions
  - _Requirements: 6.1, 7.3, 15.4_

- [ ] 11. Skills
- [ ] 11.1 Skills lint and the `ubuntu` Skill
  - Create `test/unit/skills.bats` (frontmatter keys, description ≤ 1,024 characters, routes exist, links exist). Write `skills/ubuntu/SKILL.md` and its topic files `logs.md`, `services.md`, `handoff.md` and `layout.md`.
  - _Requirements: 16.1, 16.2, 16.3, 16.4, 16.5, 16.7_
- [ ] 11.2 `diagnose-crash` Skill
  - Write `skills/diagnose-crash/{SKILL.md,symbols.md,reporting.md}`, ported from Omarchy's method for apport, coredump and Ubuntu debuginfod.
  - _Requirements: 16.1, 16.2, 16.4, 16.6_
- [ ] 11.3 `drivers` and `updates` Skills
  - Write `skills/drivers/{SKILL.md,nvidia.md,secure-boot.md,firmware.md}` and `skills/updates/{SKILL.md,phasing.md,third-party.md}`.
  - _Requirements: 16.1, 16.2, 16.4_
- [ ] 11.4 `disk` and `performance` Skills
  - Write `skills/disk/{SKILL.md,cleanup.md}` and `skills/performance/{SKILL.md,boot.md}`.
  - _Requirements: 16.1, 16.2, 16.4_

- [ ] 12. Claude Code plugin
- [ ] 12.1 Marketplace, Plugin manifest and Investigator
  - Create `share/claude/.claude-plugin/marketplace.json`, `plugins/domovyk/.claude-plugin/plugin.json`, `agents/domovyk-investigator.md`, `hooks/hooks.json` and the two hook wrapper scripts.
  - Add `plugin.bats`: JSON shape, no `bin/`, Investigator tools. Run `claude plugin validate --strict` in a 26.04 VM.
  - _Requirements: 17.1, 17.2, 17.3, 17.4, 17.5_
- [ ] 12.2 Guard_Hook
  - Create `libexec/py/guard.py`, `libexec/hooks/guard`, `test/unit/fixtures/guard-corpus.tsv` (≥ 150 lines), `test/unit/guard.bats` and `test/unit/py/test_guard.py` (seeded properties for inserting and removing `sudo`).
  - _Requirements: 18.1, 18.2, 18.3, 18.4, 18.5_
- [ ] 12.3 Context_Hook
  - Create `libexec/hooks/context` and `context.bats`. Cases: an Agent_Session, a non-session, a timeout with a fake slow `domovyk`.
  - _Requirements: 19.1, 19.2, 19.3_

- [ ] 13. Checkpoint: run `test/run-all` in a 26.04 VM, then stop for questions
  - _Requirements: 16.4, 17.1, 18.3_

- [ ] 14. Setup and Unsetup
- [ ] 14.1 User_Ledger, Setup and the self-contained Unsetup
  - Create `libexec/lib/ledger.sh`, `domovyk-setup-claude`, `libexec/unsetup` and `domovyk-unsetup`, plus a fake `claude` under `test/unit/fixtures/bin/`.
  - Add `setup.bats`. Cases: fresh setup, second run is a no-op, missing `claude`, invalid settings, ledger written before each step, interrupted setup, `--keep-handoffs`, `--purge`, Unsetup with the Package tree absent.
  - _Requirements: 20.1, 20.2, 20.3, 20.4, 20.6, 20.7, 20.8, 20.9_
- [ ] 14.2 Settings round-trip property
  - Create `test/unit/py/test_setup_roundtrip.py`: 500 seeded random valid `settings.json` documents are equal as JSON after Setup then Unsetup, with the fake `claude`.
  - _Requirements: 20.5_

- [ ] 15. Launcher
- [ ] 15.1 `domovyk agent`, `agent prompt`, `agent crash` and the Workspace
  - Create `domovyk-agent`, `domovyk-agent-prompt`, `domovyk-agent-crash`, `share/workspace/CLAUDE.md` and `agent.bats`, with a fake `claude` and a fake `xdg-terminal-exec`. Cases: inline and terminal, the permission-mode setting, the crash prompt fields, missing `claude`, Plugin not enabled.
  - _Requirements: 21.1, 21.2, 21.3, 21.4, 21.5, 21.6, 21.7_

- [ ] 16. Checkpoint: run `test/run-all` in a 26.04 VM, then stop for questions
  - _Requirements: 20.5, 21.1_

- [ ] 17. Packaging
- [ ] 17.1 Debian packaging
  - Create `debian/{control,rules,install,links,changelog,copyright,prerm}` and `debian/source/format`. Build with `dpkg-buildpackage -b -us -uc` and run `lintian` in a 26.04 VM. Install the result in a 24.04 VM.
  - _Requirements: 22.1, 22.2, 22.3, 22.5_
- [ ] 17.2 Package VM test
  - Create `test/vm/tests/package.sh`. On 26.04 and 24.04 VMs: take a Fingerprint, install, run Setup for a test user, run Unsetup, purge, and take a second Fingerprint. Then remove with a User_Ledger present and check the `prerm` message.
  - _Requirements: 22.4, 22.5_

- [ ] 18. VM integration tests
- [ ] 18.1 Read tier on real systems
  - Create `test/vm/tests/read-tier.sh`. On `fresh` and `gnome-snaps`, 26.04 and 24.04: run every Read_Command with and without `--json` and check the Fingerprint is unchanged. Repeat under `unshare -n`. Time each run against 30 s.
  - _Requirements: 1.1, 3.1, 3.2, 3.4, 4.1, 4.2_
- [ ] 18.2 Crash end-to-end
  - Create `test/vm/tests/crash.sh` on 26.04 and 24.04 `gnome-snaps`: SEGV injection, then list, info and backtrace, temp-directory cleanup after success and after SIGINT. Repeat with `systemd-coredump` installed.
  - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_
- [ ] 18.3 Setup with real Claude Code
  - Create `test/vm/tests/setup.sh` on 26.04 `gnome-snaps`: native Claude Code install, Setup twice, `claude plugin details domovyk` lists the Skills, the Investigator and the hooks, then Unsetup and compare the settings.
  - _Requirements: 17.2, 17.4, 20.1, 20.3, 20.4, 20.5_
- [ ] 18.4 Guard latency
  - Create `test/vm/tests/guard-latency.sh`: 1,000 guard runs over the corpus in a 26.04 VM, p95 < 100 ms.
  - _Requirements: 18.6_

- [ ] 19. Checkpoint: run `test/run-all` on 26.04 and `test/run-all --release noble`, then stop for questions
  - _Requirements: 1.1, 22.4_

- [ ] 20. Documentation and manual check
- [ ] 20.1 README
  - Write `README.md`: what Domovyk is, install, `domovyk setup claude`, `domovyk agent`, privacy (what reaches the model, redaction, `--raw`), Unsetup before removal, and the phase 1 limits (handoffs only).
  - _Requirements: 15.3, 20.9, 22.5_
- [ ] 20.2 Manual Agent_Session check in a 26.04 `gnome-snaps` VM
  - With the owner signed in to Claude Code inside the VM: the skills load, the Context_Hook output appears, `sudo` is denied with the handoff reason, and `domovyk agent crash` opens with the crash prompt. Record the result in `design.md`, Testing Strategy.
  - _Requirements: 17.2, 19.1, 21.2, 21.3, 21.4_
- [ ]* 20.3 Man page and shell completions
  - Create `docs/domovyk.1.md` (rendered at build time) and bash/zsh completions generated from `domovyk commands --json`.
  - _Requirements: 2.1_

- [ ] 21. Checkpoint: definition of done (`.kiro/steering/specs.md`): every required task checked, both releases green, every criterion verified or documented, spec files updated to match what was built; then stop for the owner's review
  - _Requirements: 1.1, 3.1, 22.4, 23.4_
