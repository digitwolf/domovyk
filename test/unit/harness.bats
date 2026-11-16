#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and teardown are called by bats
# shellcheck disable=SC2016 # fake scripts are single-quoted on purpose
# The VM harness, test/vm/ (requirement 23): the guest guard refuses to run
# outside a VM, host-side scripts refuse root, and a whole VM lifecycle with
# fake QEMU and SSH writes only under the repository and ~/.cache/domovyk-vm/,
# reads DOMOVYK_VM_IMAGE_DIR without writing to it, and never runs sudo.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  VM="$REPO/test/vm"
  FAKE="$BATS_TEST_TMPDIR/fakebin"
  FAKE_DATA="$BATS_TEST_TMPDIR/fakedata"
  mkdir -p "$FAKE" "$FAKE_DATA"
  export FAKE_DATA
  export HOME="$BATS_TEST_TMPDIR/home"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$HOME" "$TMPDIR"
  export PATH="$FAKE:$PATH"
  unset DOMOVYK_VM_IMAGE_DIR DOMOVYK_VM_RESULTS DOMOVYK_VM_CPUS DOMOVYK_VM_RAM \
    DOMOVYK_VM_DISK DOMOVYK_VM_GPU_ARGS DOMOVYK_VM_UPGRADE
}

teardown() {
  local f
  # bats removes the test folder, which needs the read-only one writable.
  if [[ -n ${SHARED:-} && -d $SHARED ]]; then
    chmod -R u+w "$SHARED"
  fi
  # Fake QEMU and seed servers a failed test left running.
  for f in "$HOME"/.cache/domovyk-vm/vms/*/pid "$HOME"/.cache/domovyk-vm/vms/*/http.pid; do
    if [[ -f $f ]]; then
      kill "$(<"$f")" 2>/dev/null || true
    fi
  done
}

# fake <name> <body>: an executable on PATH for this test only.
fake() {
  printf '#!/bin/bash\n%s\n' "$2" >"$FAKE/$1"
  chmod +x "$FAKE/$1"
}

# as_user [tool...]: skips the test where the harness cannot run: as root,
# which every host-side script refuses (CI runs the unit tests as root in a
# container), or without the named tools.
as_user() {
  local t
  if [[ $(id -u) -eq 0 ]]; then
    skip "the VM harness refuses to run as root"
  fi
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      skip "needs $t"
    fi
  done
}

# guard_script: a guest test script that calls dv_require_guest and then
# changes something.
guard_script() {
  cat >"$BATS_TEST_TMPDIR/guest-test" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$VM/lib.sh"
dv_require_guest
touch "$BATS_TEST_TMPDIR/changed"
EOF
  chmod +x "$BATS_TEST_TMPDIR/guest-test"
}

# --- the guest guard (23.1, 23.2) -------------------------------------------

@test "dv_require_guest exits 1 before any change where systemd-detect-virt prints none" {
  fake systemd-detect-virt 'echo none; exit 1'
  guard_script
  run "$BATS_TEST_TMPDIR/guest-test"
  assert_failure 1
  assert_output --partial 'guest-test: refusing to run outside a virtual machine (systemd-detect-virt --vm: none)'
  assert [ ! -e "$BATS_TEST_TMPDIR/changed" ]
}

@test "dv_require_guest asks for a virtual machine: a container on bare metal is refused" {
  fake systemd-detect-virt '[[ ${1:-} == --vm ]] && { echo none; exit 1; }; echo lxc'
  guard_script
  run "$BATS_TEST_TMPDIR/guest-test"
  assert_failure 1
  assert [ ! -e "$BATS_TEST_TMPDIR/changed" ]
}

@test "dv_require_guest refuses when systemd-detect-virt gives no answer" {
  fake systemd-detect-virt 'exit 127'
  guard_script
  run "$BATS_TEST_TMPDIR/guest-test"
  assert_failure 1
  assert_output --partial '(systemd-detect-virt --vm: unavailable)'
  assert [ ! -e "$BATS_TEST_TMPDIR/changed" ]
}

@test "dv_require_guest lets the script run inside a VM" {
  fake systemd-detect-virt 'echo kvm'
  guard_script
  run "$BATS_TEST_TMPDIR/guest-test"
  assert_success
  assert_output ''
  assert [ -e "$BATS_TEST_TMPDIR/changed" ]
}

@test "test/unit/run refuses to run bats outside a VM" {
  fake systemd-detect-virt 'echo none; exit 1'
  run "$REPO/test/unit/run" "$BATS_TEST_FILENAME"
  assert_failure 1
  assert_output --partial 'run: refusing to run outside a virtual machine'
  refute_output --partial '1..'
}

@test "collect-fingerprint.sh refuses to run outside a VM" {
  fake id '[[ ${1:-} == -u ]] && { echo 0; exit 0; }; exec /usr/bin/id "$@"'
  fake systemd-detect-virt 'echo none; exit 1'
  run --separate-stderr bash "$VM/collect-fingerprint.sh"
  assert_failure 1
  assert_output ''
  assert_equal "$stderr" 'collect-fingerprint: refusing to run outside a virtual machine (systemd-detect-virt --vm: none)'
}

# --- host-side scripts ------------------------------------------------------

@test "every host-side script refuses to run as root" {
  local s
  fake id '[[ ${1:-} == -u ]] && { echo 0; exit 0; }; exec /usr/bin/id "$@"'
  for s in test/vm/image test/vm/up test/vm/down test/vm/run test/vm/push test/vm/fingerprint test/run-all; do
    run "$REPO/$s" --help
    assert_failure 1
    assert_output --partial 'refusing to run as root'
  done
  assert [ ! -e "$HOME/.cache" ]
}

@test "dv_require_vm: an invalid name is a usage error, an unknown VM an error" {
  as_user
  run "$VM/down" not-a-vm
  assert_failure 2
  assert_output --partial "invalid VM name 'not-a-vm'"
  run "$VM/down" resolute-fresh-abc123
  assert_failure 1
  assert_output --partial 'no such VM: resolute-fresh-abc123'
  run "$VM/up" resolute kde
  assert_failure 2
  assert_output --partial "unknown variant 'kde' (expected one of: fresh gnome-snaps)"
  run "$VM/up" arch omarchy
  assert_failure 2
  assert_output --partial "unknown release 'arch'"
}

@test "DOMOVYK_VM_RESULTS outside ~/.cache/domovyk-vm/results/ is refused" {
  as_user
  DOMOVYK_VM_RESULTS=$BATS_TEST_TMPDIR/results run "$VM/down" --help
  assert_failure 1
  assert_output --partial 'DOMOVYK_VM_RESULTS must be a folder under'
}

@test "DOMOVYK_VM_IMAGE_DIR must be an absolute path to a folder" {
  as_user
  DOMOVYK_VM_IMAGE_DIR=relative/dir run "$VM/image" resolute fresh
  assert_failure 1
  assert_output --partial 'DOMOVYK_VM_IMAGE_DIR must be an absolute path to a folder'
}

# --- base images from DOMOVYK_VM_IMAGE_DIR ----------------------------------

# shared_images: a read-only DOMOVYK_VM_IMAGE_DIR with a cloud image, its
# .sha256 and a gnome-snaps image.
shared_images() {
  SHARED="$BATS_TEST_TMPDIR/shared"
  mkdir -p "$SHARED"
  printf 'not really a disk image\n' >"$SHARED/ubuntu-26.04-server-cloudimg-amd64.img"
  printf '%s *ubuntu-26.04-server-cloudimg-amd64.img\n' \
    "$(sha256sum "$SHARED/ubuntu-26.04-server-cloudimg-amd64.img" | cut -d' ' -f1)" \
    >"$SHARED/ubuntu-26.04-server-cloudimg-amd64.img.sha256"
  printf 'qcow2\n' >"$SHARED/resolute-gnome-snaps.qcow2"
  chmod 0444 "$SHARED"/*
  chmod 0555 "$SHARED"
  export DOMOVYK_VM_IMAGE_DIR="$SHARED"
}

# listing <folder>: every entry under the folder, the folder included, with
# its mode, size and modification time.
listing() {
  find "$1" -printf '%p %M %s %T@\n' | LC_ALL=C sort
}

@test "test/vm/image finds a verified cloud image in DOMOVYK_VM_IMAGE_DIR" {
  as_user gpgv flock
  shared_images
  run --separate-stderr "$VM/image" resolute fresh
  assert_success
  assert_output "$SHARED/ubuntu-26.04-server-cloudimg-amd64.img"
  assert [ ! -e "$HOME/.cache/domovyk-vm/base/.ubuntu-26.04-server-cloudimg-amd64.img.lock" ]
}

@test "test/vm/image finds a gnome-snaps image in DOMOVYK_VM_IMAGE_DIR without building one" {
  as_user gpgv flock
  shared_images
  fake qemu-system-x86_64 'echo "qemu must not run" >&2; exit 99'
  run --separate-stderr "$VM/image" resolute gnome-snaps
  assert_success
  assert_output "$SHARED/resolute-gnome-snaps.qcow2"
}

@test "test/vm/image refuses a shared cloud image that does not match its .sha256" {
  as_user gpgv flock
  shared_images
  chmod 0755 "$SHARED"
  chmod 0644 "$SHARED/ubuntu-26.04-server-cloudimg-amd64.img"
  printf 'changed\n' >>"$SHARED/ubuntu-26.04-server-cloudimg-amd64.img"
  run "$VM/image" resolute fresh
  assert_failure 1
  assert_output --partial 'checksum mismatch'
}

# --- a whole lifecycle with fake QEMU and SSH (23.3, 23.4) -------------------

# fake_vm_tools: QEMU that writes its pid file and waits to be killed,
# qemu-img that creates empty files, ssh that answers like a ready guest,
# rsync that does nothing, and sudo that records any call and fails.
fake_vm_tools() {
  fake qemu-system-x86_64 'printf "%s\n" "$*" >>"$FAKE_DATA/qemu.args"
pidfile=""
while (($# > 0)); do
  if [[ $1 == -pidfile ]]; then pidfile=$2; fi
  shift
done
printf "%s\n" "$$" >"$pidfile"
trap "exit 0" TERM
while :; do sleep 0.1; done'
  fake qemu-img 'printf "%s\n" "$*" >>"$FAKE_DATA/qemu-img.args"
if [[ $1 == create ]]; then
  : >"${@: -2:1}"
fi'
  fake ssh 'port="" remote=()
while (($# > 0)); do
  case $1 in
    -p) port=$2; shift 2 ;;
    -F | -i | -o) shift 2 ;;
    *@*) shift; remote=("$@"); break ;;
    *) shift ;;
  esac
done
printf "%s\n" "${remote[*]}" >>"$FAKE_DATA/ssh.commands"
case ${remote[*]} in
  *"systemctl poweroff"*)
    for f in "$HOME"/.cache/domovyk-vm/vms/*/ssh.port; do
      if [[ $(<"$f") == "$port" ]]; then kill "$(<"${f%/ssh.port}/pid")"; fi
    done ;;
  *"bash -s"*)
    cat >/dev/null
    tar -C "$FAKE_DATA/fp" -cf - . ;;
esac
exit 0'
  fake rsync 'printf "%s\n" "$*" >>"$FAKE_DATA/rsync.args"'
  fake sudo 'printf "%s\n" "$*" >>"$FAKE_DATA/sudo.calls"; exit 1'
  mkdir -p "$FAKE_DATA/fp"
  printf 'bash\t5.2\tinstalled\n' >"$FAKE_DATA/fp/packages.tsv"
  # test/vm/up checks /dev/kvm, which a test VM does not give its user, so
  # the boot goes through the same library calls as test/vm/up.
  cat >"$BATS_TEST_TMPDIR/boot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1/test/vm/lib.sh"
dv_init
dv_ensure_key
backing=$("$DV_LIB_DIR/image" resolute fresh | tail -n 1)
dv_boot resolute fresh "$backing"
dv_unregister "$DV_BOOTED"
printf '%s\n' "$DV_BOOTED"
EOF
  chmod +x "$BATS_TEST_TMPDIR/boot"
}

# writes_outside <marker>: prints every path owned by this user that changed
# after <marker> and is neither in the repository, nor under
# ~/.cache/domovyk-vm/, nor a folder that holds it, nor bats' own folder.
writes_outside() {
  local marker=$1 p
  {
    find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
      -o -path "$BATS_RUN_TMPDIR" \) -prune -o \
      -user "$(id -u)" -newer "$marker" -print 2>/dev/null || true
    find "$HOME" "$TMPDIR" -newer "$marker" -print 2>/dev/null || true
  } | while IFS= read -r p; do
    case $p in
      "$REPO" | "$REPO"/* | "$HOME" | "$HOME/.cache" | "$HOME/.cache/domovyk-vm" | "$HOME/.cache/domovyk-vm"/*) ;;
      "$TMPDIR") ;;
      *) printf '%s\n' "$p" ;;
    esac
  done
}

@test "up, run, push, fingerprint and down write only under the repo and ~/.cache/domovyk-vm, and never run sudo" {
  local name dir before_shared
  as_user gpgv flock ssh-keygen setsid timeout
  shared_images
  fake_vm_tools
  before_shared=$(listing "$SHARED")
  touch "$BATS_TEST_TMPDIR/marker"

  run --separate-stderr "$BATS_TEST_TMPDIR/boot" "$REPO" 3>&-
  assert_success
  name=$output
  assert_regex "$name" '^resolute-fresh-[0-9a-f]{6}$'
  dir="$HOME/.cache/domovyk-vm/vms/$name"
  assert [ -f "$dir/overlay.qcow2" ]
  assert [ -f "$dir/nvme.qcow2" ]

  run "$VM/run" "$name" -- 'systemd-detect-virt; lsblk' 3>&-
  assert_success
  run "$VM/push" "$name" 3>&-
  assert_success
  run --separate-stderr "$VM/fingerprint" "$name" before 3>&-
  assert_success
  assert_output "$HOME/.cache/domovyk-vm/fp/$name/before"
  assert [ -s "$output/packages.tsv" ]
  run "$VM/down" "$name" 3>&-
  assert_success
  assert [ ! -e "$dir" ]

  # The overlay sits on the shared image, which qemu-img does not open and
  # QEMU opens without image locks; the NVMe disk is attached.
  run cat "$FAKE_DATA/qemu-img.args"
  assert_line --partial -- "-b $SHARED/ubuntu-26.04-server-cloudimg-amd64.img -u $dir/overlay.qcow2 40G"
  assert_line "create -q -f qcow2 $dir/nvme.qcow2 1G"
  run cat "$FAKE_DATA/qemu.args"
  assert_output --partial 'backing.file.locking=off'
  assert_output --partial "file=$dir/nvme.qcow2,if=none,id=nvme0"
  assert_output --partial -- '-device nvme,drive=nvme0,serial=domovyk-nvme0'
  # The guest got its commands, sudo ones included; the host ran no sudo.
  run cat "$FAKE_DATA/ssh.commands"
  assert_line 'systemd-detect-virt; lsblk'
  assert_line 'sudo bash -s'
  assert_line 'sudo systemctl poweroff'
  assert [ ! -e "$FAKE_DATA/sudo.calls" ]

  assert_equal "$(listing "$SHARED")" "$before_shared"
  run writes_outside "$BATS_TEST_TMPDIR/marker"
  assert_success
  assert_output ''
}

@test "the write check notices files outside the repo and ~/.cache/domovyk-vm" {
  local stray
  touch "$BATS_TEST_TMPDIR/marker"
  mkdir -p "$HOME/.cache/domovyk-vm/vms" "$HOME/.cache/other"
  touch "$HOME/.cache/domovyk-vm/vms/allowed" "$HOME/.cache/other/stray" "$TMPDIR/stray"
  stray=$(mktemp /var/tmp/domovyk-harness-test.XXXXXX)
  run writes_outside "$BATS_TEST_TMPDIR/marker"
  rm -f -- "$stray"
  assert_line "$HOME/.cache/other"
  assert_line "$HOME/.cache/other/stray"
  assert_line "$TMPDIR/stray"
  assert_line "$stray"
  refute_line --partial 'allowed'
}
