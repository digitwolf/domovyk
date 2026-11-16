---
inclusion: always
---

# Testing: virtual machines only

The development host is the owner's daily-use Ubuntu 26.04 laptop, with encrypted LVM and personal data. Domovyk is not installed, set up or tested on it until the owner decides to install a release.

## Hard rules

- No task, script, hook or agent may run any of these on the development host:
  - `domovyk setup` or `domovyk unsetup`;
  - `apt install`, `apt purge`, `dpkg -i`;
  - `claude plugin` commands that change state;
  - any `sudo` command.
- No task may write outside the repository folder on the development host, except VM disk images and caches under `~/.cache/domovyk-vm/`.
- Package builds run inside a VM, because build dependencies must not be installed on the host.
- Allowed on the host:
  - editing files, `shellcheck`, `git`, `jq`;
  - starting or stopping QEMU VMs as the current user;
  - **running read-tier commands from the working tree** (`DOMOVYK_ROOT=$PWD bin/domovyk status`), because they change nothing and a VM has no real drivers, crashes or disks. Captured output becomes a fixture only after redaction and a manual review for personal data.
- Unit tests (`bats`) and `shfmt` run inside a VM, never on the host.
- Every test script that changes a system refuses to run unless `systemd-detect-virt` is not `none`.

## Test VMs

- **Primary:** Ubuntu 26.04 LTS (`resolute`) cloud image, amd64. All development testing runs here.
- **Secondary:** Ubuntu 24.04 LTS (`noble`) cloud image, for release-specific tests.
- Base image variants:
  - `fresh`: the server cloud image;
  - `gnome-snaps`: the GNOME desktop with snaps, identical to Motanka's variant, for the launcher and crash tests.
- VMs are started with `qemu-system-x86_64 -enable-kvm` as the current user, with user-mode networking, SSH forwarded to a local port, and cloud-init seeded over NoCloud HTTP.
- Each test starts from a copy-on-write overlay of a base image and deletes the overlay afterwards.
- The repo is copied into the VM (rsync over SSH). The VM never mounts the host home folder.
- Base images may be shared read-only with Motanka's harness: set `DOMOVYK_VM_IMAGE_DIR=~/.cache/motanka-vm/base`.

## Commands (under `test/vm/`, ported from Motanka at commit `d076748`)

- `test/vm/up <release> <variant>`: create an overlay and boot it.
- `test/vm/run <name> -- <command>`: run a command in the VM over SSH.
- `test/vm/push <name>`: copy the repo into the VM.
- `test/vm/fingerprint <name>`: capture the Fingerprint.
- `test/vm/down <name>`: stop the VM and delete the overlay.
- `test/run-all`: `shellcheck` on the host, then unit and VM tests inside 26.04 VMs. `--release noble` runs them on 24.04.
- `bats-core`, `bats-support` and `bats-assert` are vendored under `test/bats/{core,support,assert}`.
- Test logs are copied to `~/.cache/domovyk-vm/results/<run-id>/`.
