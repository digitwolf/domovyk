---
inclusion: always
---

# How specs are written in this repository

## Scope and vocabulary
- Product context is in `product.md`, the stack in `tech.md`, the layout in `structure.md`, and the test environment in `testing.md`. Do not restate them in specs.
- Always out of scope unless a requirement says otherwise:
  - releases other than 24.04 LTS and 26.04 LTS, and architectures other than amd64;
  - bootloader, initramfs, partitioning and disk-encryption changes;
  - release upgrades, which are always a Handoff_Script.
- Define any new term in the spec's Glossary before using it in a criterion.

## requirements.md
- EARS only, one SHALL per criterion, one observable response.
- Numbers, not adjectives. Never "fast", "large", "appropriate", "user-friendly", "secure", "handle".
- Every happy-path criterion has an IF twin for failure, interruption, a missing tool or a missing permission.
- Write invariants as universal statements so they can become property tests.
- Never renumber existing requirements; append new ones.

## design.md
- Follow `DESIGN.md` at the repo root. A departure from it needs a stated reason.
- Interfaces concrete enough to implement from: command-line syntax, exit codes, JSON shapes, file formats, paths.
- Error handling listed per IF criterion.
- A new dependency needs a one-line justification and must be added to `tech.md`.
- The testing strategy uses `bats-core`, `shellcheck` and the VM harness in `test/vm/`.
- Diagrams in Mermaid.

## tasks.md
- Every task ends with `_Requirements: <ids>_`.
- Task size 15–90 minutes, one coherent set of files per task. Tasks in the same wave must not touch the same files.
- Tests live in the same task as the code they cover, or the next one.
- Order: VM harness → spikes → foundations → facts → integration → packaging → polish.
- Every task that installs, removes or builds anything says it runs in a test VM and names the release.
- Add a `Checkpoint` task after every 3–5 tasks: run `test/run-all`, then stop for questions.
- No task may run `git push`, or run `sudo`, `apt` or `domovyk setup` on the development host.

## Definition of done
- All required tasks are checked.
- Lint and `test/run-all` are green on 26.04, and release-specific tests are green on 24.04.
- Every acceptance criterion is verified by a test, or by a manual check in a VM documented in `design.md`.
- The spec files are updated to match what was built, then committed with the code.
