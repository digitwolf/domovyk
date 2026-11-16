# shellcheck shell=bash disable=SC2034,SC2329
# (Library file: its variables and functions are used by the scripts that
# source it.)
#
# Shared code for the Domovyk VM test harness (test/vm/*, test/run-all).
# Ported from Motanka's test/vm/lib.sh at commit d076748.
#
# Every host-side script that sources this file:
# - refuses to run as root and never calls sudo;
# - writes only inside the repository and ~/.cache/domovyk-vm/
#   (requirement 23.3);
# - needs /dev/kvm to be readable and writable by the current user
#   before it starts a VM.
# Test scripts that run inside a VM and change it call dv_require_guest
# first (requirements 23.1, 23.2).
#
# State under ~/.cache/domovyk-vm/:
#   base/                cloud images downloaded and verified here, and
#                        variant base images built here
#   vms/<name>/          overlay.qcow2, nvme.qcow2, pid, ssh.port, seed/,
#                        serial.log, qemu.log, http.log, backing, release,
#                        variant
#   ssh/                 ed25519 key, generated on first use
#   fp/<name>/<label>/   Fingerprints
#   results/<run-id>/    logs for the implementer
#
# Environment:
#   DOMOVYK_VM_CPUS       vCPUs per VM (default 4)
#   DOMOVYK_VM_RAM        memory per VM, QEMU syntax (default 6G)
#   DOMOVYK_VM_DISK       virtual size of a VM's overlay disk (default 40G;
#                         the overlay only grows as the guest writes)
#   DOMOVYK_VM_GPU_ARGS   QEMU display and GPU arguments, split on spaces
#                         (default "-vga none -device virtio-vga -display none")
#   DOMOVYK_VM_RESULTS    if set, serial and QEMU logs of every VM that is
#                         torn down are copied there; must be a folder under
#                         ~/.cache/domovyk-vm/results/
#   DOMOVYK_VM_IMAGE_DIR  if set, a folder of base images that is searched
#                         first and only read, never written or locked, for
#                         example Motanka's ~/.cache/motanka-vm/base: the
#                         verified ubuntu-<version>-server-cloudimg-amd64.img
#                         (used only next to its .sha256, which it must
#                         match) and <release>-<variant>.qcow2. Images that
#                         are not found there are still downloaded or built
#                         into ~/.cache/domovyk-vm/base/.
#
# Every VM also gets an emulated NVMe data disk (nvme.qcow2, empty, 1 GiB),
# so that UDisks2 in the guest has a drive with NVMe SMART data.

DV_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DV_REPO=$(cd "$DV_LIB_DIR/../.." && pwd)

DV_STATE="$HOME/.cache/domovyk-vm"
DV_BASE="$DV_STATE/base"
DV_VMS="$DV_STATE/vms"
DV_SSH_DIR="$DV_STATE/ssh"
DV_KEY="$DV_SSH_DIR/id_ed25519"
DV_FP="$DV_STATE/fp"
DV_RESULTS="$DV_STATE/results"

DV_RELEASES=(resolute noble)
DV_VARIANTS=(fresh gnome-snaps)
DV_NAME_RE='^(resolute|noble)-(fresh|gnome-snaps)-[0-9a-f]{6}$'
DV_GUEST_USER=tester
DV_GUEST_REPO=/home/tester/domovyk
DV_DISK_SIZE=${DOMOVYK_VM_DISK:-40G}
DV_NVME_SIZE=1G
DV_BOOT_TIMEOUT=600
DV_DOWN_TIMEOUT=60
DV_DEFAULT_GPU_ARGS="-vga none -device virtio-vga -display none"
DV_CLOUDIMG_URL=https://cloud-images.ubuntu.com/releases
DV_CLOUDIMG_KEYRING=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg

DV_PROG=${DV_PROG:-vm}
DV_USAGE=${DV_USAGE:-}
DV_CLEANUP_VMS=()
DV_CLEANUP_PATHS=()
DV_BOOTED=""
DV_HTTP_PORT=""
DV_SSH_OPTS=()
DV_SSH_DEST=""
DV_SSH=()

# --- messages ---------------------------------------------------------------

dv_log() {
  printf '%s: %s\n' "$DV_PROG" "$*" >&2
}

dv_die() {
  dv_log "error: $*"
  exit 1
}

# dv_usage [message]: print the message and the script's usage, exit 2.
dv_usage() {
  if (($# > 0)); then
    dv_log "$1"
  fi
  printf 'usage: %s\n' "$DV_USAGE" >&2
  exit 2
}

# --- guest guard ------------------------------------------------------------

# dv_require_guest: for test scripts that run inside a test VM and install,
# set up or remove anything. Exits 1 before anything is changed unless
# systemd-detect-virt reports a virtual machine (requirements 23.1, 23.2).
# --vm makes a container on a bare-metal host count as "none" too.
dv_require_guest() {
  local virt
  virt=$(systemd-detect-virt --vm 2>/dev/null || true)
  if [[ -z $virt || $virt == none ]]; then
    printf '%s: refusing to run outside a virtual machine (systemd-detect-virt --vm: %s); run it inside a test VM (test/vm/up, test/vm/run)\n' \
      "$(basename -- "$0")" "${virt:-unavailable}" >&2
    exit 1
  fi
}

# --- setup and cleanup ------------------------------------------------------

dv_init() {
  DV_PROG=$(basename "$0")
  umask 077
  if [[ $(id -u) -eq 0 ]]; then
    dv_die "refusing to run as root; run the test harness as your normal user"
  fi
  dv_check_results_env
  dv_check_image_dir_env
  mkdir -p "$DV_BASE" "$DV_VMS" "$DV_FP" "$DV_RESULTS"
  trap dv_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# Destroys every VM and removes every temporary path still registered.
dv_on_exit() {
  local rc=$? item
  trap - EXIT
  for item in "${DV_CLEANUP_VMS[@]}"; do
    dv_log "cleaning up VM $item"
    dv_destroy "$item" || true
  done
  for item in "${DV_CLEANUP_PATHS[@]}"; do
    if [[ $item == "$DV_STATE"/* ]]; then
      rm -rf -- "$item" || true
    fi
  done
  exit "$rc"
}

dv_unregister() {
  local keep=() n
  for n in "${DV_CLEANUP_VMS[@]}"; do
    if [[ $n != "$1" ]]; then
      keep+=("$n")
    fi
  done
  DV_CLEANUP_VMS=("${keep[@]}")
}

dv_check_results_env() {
  local r=${DOMOVYK_VM_RESULTS:-}
  if [[ -z $r ]]; then
    return 0
  fi
  if [[ $r != "$DV_RESULTS"/* || $r == *..* ]]; then
    dv_die "DOMOVYK_VM_RESULTS must be a folder under $DV_RESULTS/, got '$r'"
  fi
}

dv_check_image_dir_env() {
  local d=${DOMOVYK_VM_IMAGE_DIR:-}
  if [[ -z $d ]]; then
    return 0
  fi
  if [[ $d != /* || ! -d $d ]]; then
    dv_die "DOMOVYK_VM_IMAGE_DIR must be an absolute path to a folder, got '$d'"
  fi
}

# --- checks -----------------------------------------------------------------

dv_check_kvm() {
  if [[ ! -e /dev/kvm ]]; then
    dv_die "/dev/kvm does not exist; enable hardware virtualisation (KVM) on this host"
  fi
  if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    dv_die "/dev/kvm is not readable and writable by user $(id -un); the user must be in the kvm group (add it, then log in again)"
  fi
}

dv_need() {
  local c missing=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if ((${#missing[@]} > 0)); then
    dv_die "missing host tools: ${missing[*]}"
  fi
}

dv_release_version() {
  case $1 in
    resolute) printf '26.04\n' ;;
    noble) printf '24.04\n' ;;
    *) return 1 ;;
  esac
}

dv_check_release() {
  if ! dv_release_version "$1" >/dev/null; then
    dv_usage "unknown release '$1' (expected one of: ${DV_RELEASES[*]})"
  fi
}

dv_check_variant() {
  local v
  for v in "${DV_VARIANTS[@]}"; do
    if [[ $1 == "$v" ]]; then
      return 0
    fi
  done
  dv_usage "unknown variant '$1' (expected one of: ${DV_VARIANTS[*]})"
}

dv_valid_name() {
  [[ $1 =~ $DV_NAME_RE ]]
}

# dv_require_vm <name>: the name is valid and its state folder exists.
dv_require_vm() {
  if ! dv_valid_name "$1"; then
    dv_usage "invalid VM name '$1' (expected <release>-<variant>-<6 hex digits>)"
  fi
  if [[ ! -d $DV_VMS/$1 ]]; then
    dv_die "no such VM: $1"
  fi
}

# dv_require_running <name>
dv_require_running() {
  dv_require_vm "$1"
  if ! dv_qemu_pid "$1" >/dev/null; then
    dv_die "VM $1 is not running"
  fi
}

# --- shared base images -----------------------------------------------------

# dv_shared_image <file name>: prints the path of the base image in
# DOMOVYK_VM_IMAGE_DIR, or returns 1 if that is unset or has no such file.
# Only reads the folder.
dv_shared_image() {
  local d=${DOMOVYK_VM_IMAGE_DIR:-}
  if [[ -z $d || ! -f $d/$1 || ! -r $d/$1 ]]; then
    return 1
  fi
  printf '%s\n' "${d%/}/$1"
}

# --- small helpers ----------------------------------------------------------

dv_hex6() {
  python3 -c 'import secrets; print(secrets.token_hex(3))'
}

# Prints a TCP port on 127.0.0.1 that is free at the time of the call.
dv_free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# dv_pid_matches <pid> <text>: the process is alive and its command line
# contains <text>. Guards against killing a reused pid.
dv_pid_matches() {
  local pid=$1 needle=$2 cmd
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  [[ -r /proc/$pid/cmdline ]] || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  [[ -n $cmd && $cmd == *"$needle"* ]]
}

# Prints the QEMU pid of a running VM, or returns 1.
dv_qemu_pid() {
  local dir=$DV_VMS/$1 pid
  [[ -r $dir/pid ]] || return 1
  pid=$(<"$dir/pid") || return 1
  pid=${pid//[^0-9]/}
  dv_pid_matches "$pid" "$dir/overlay.qcow2" || return 1
  printf '%s\n' "$pid"
}

# dv_wait_exit <name> <seconds>: returns 1 if QEMU still runs afterwards.
dv_wait_exit() {
  local deadline=$((SECONDS + $2))
  while dv_qemu_pid "$1" >/dev/null; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 1
  done
}

# --- SSH --------------------------------------------------------------------

# Generates the harness key on first use. Two harness processes may race
# here, so the key is created in a temporary folder that is then renamed.
dv_ensure_key() {
  local tmp
  if [[ -f $DV_KEY && -f $DV_KEY.pub ]]; then
    return 0
  fi
  dv_need ssh-keygen
  tmp=$(mktemp -d "$DV_STATE/.ssh.XXXXXX")
  ssh-keygen -q -t ed25519 -N '' -C domovyk-vm -f "$tmp/id_ed25519" </dev/null
  if ! mv -T "$tmp" "$DV_SSH_DIR" 2>/dev/null; then
    rm -rf -- "$tmp"
  fi
  if [[ ! -f $DV_KEY || ! -f $DV_KEY.pub ]]; then
    dv_die "could not create the SSH key in $DV_SSH_DIR"
  fi
  dv_log "generated SSH key $DV_KEY"
}

# dv_ssh_args <name>: fills DV_SSH_OPTS, DV_SSH_DEST and DV_SSH (the full
# ssh command line without the remote command).
dv_ssh_args() {
  local dir=$DV_VMS/$1 port
  if [[ ! -r $dir/ssh.port ]]; then
    dv_die "VM $1 has no SSH port recorded"
  fi
  port=$(<"$dir/ssh.port")
  if [[ ! $port =~ ^[0-9]+$ ]]; then
    dv_die "VM $1 has an invalid SSH port '$port'"
  fi
  DV_SSH_OPTS=(
    -F /dev/null
    -i "$DV_KEY"
    -p "$port"
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=8
    -o ForwardAgent=no
    -o ForwardX11=no
  )
  DV_SSH_DEST="$DV_GUEST_USER@127.0.0.1"
  DV_SSH=(ssh "${DV_SSH_OPTS[@]}" "$DV_SSH_DEST")
}

# --- cloud-init seed --------------------------------------------------------

dv_write_seed() {
  local name=$1 dir=$DV_VMS/$1 pub
  pub=$(<"$DV_KEY.pub")
  cat >"$dir/seed/meta-data" <<EOF
instance-id: domovyk-$name
local-hostname: $name
EOF
  cat >"$dir/seed/user-data" <<EOF
#cloud-config
users:
  - name: $DV_GUEST_USER
    gecos: Domovyk test user
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "$pub"
ssh_pwauth: false
disable_root: true
package_update: false
package_upgrade: false
package_reboot_if_required: false
EOF
  # Harness-wide defaults: no background apt runs, so two Fingerprints of
  # the same VM differ only by what the test did. The file name avoids
  # "domovyk" so tests looking for Domovyk leftovers do not match it.
  cat >"$dir/seed/vendor-data" <<'EOF'
#cloud-config
write_files:
  - path: /etc/apt/apt.conf.d/99harness-no-periodic
    permissions: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "0";
      APT::Periodic::Unattended-Upgrade "0";
  # needrestart would restart ssh.service during an apt run over SSH and
  # drop the session (seen on 24.04): list only, never restart.
  - path: /etc/needrestart/conf.d/99harness-list-only.conf
    permissions: "0644"
    content: |
      $nrconf{restart} = 'l';
# fwupd sets its configuration to mode 0640 when it runs (the package ships
# 0644; seen on 26.04 with fwupd 2.1), and whether it first runs during a
# test depends on its timer: the VM starts with the mode fwupd sets.
runcmd:
  - [sh, -c, "if [ -f /etc/fwupd/fwupd.conf ]; then chmod 0640 /etc/fwupd/fwupd.conf; fi"]
  # Every SSH login runs the dynamic motd, and its landscape-sysinfo part
  # rewrites /var/lib/landscape/landscape-sysinfo.cache (at most once a
  # minute), so each harness command would change the Fingerprint.
  - [rm, -f, /etc/update-motd.d/50-landscape-sysinfo]
EOF
}

# dv_start_http <vm-dir>: serves <vm-dir>/seed on 127.0.0.1 and sets
# DV_HTTP_PORT. The server picks its own port, so there is no race.
dv_start_http() {
  local dir=$1 pid port="" i
  python3 -u -m http.server --bind 127.0.0.1 --directory "$dir/seed" 0 \
    </dev/null >"$dir/http.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$dir/http.pid"
  for ((i = 0; i < 50; i++)); do
    port=$(sed -n 's/.* port \([0-9][0-9]*\).*/\1/p' "$dir/http.log" | head -n 1)
    if [[ -n $port ]] || ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if [[ -z $port ]]; then
    cat "$dir/http.log" >&2 || true
    dv_die "the cloud-init seed HTTP server did not start"
  fi
  DV_HTTP_PORT=$port
}

dv_stop_http() {
  local dir=$1 pid
  if [[ ! -f $dir/http.pid ]]; then
    return 0
  fi
  pid=$(<"$dir/http.pid")
  if dv_pid_matches "$pid" "$dir/seed"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f -- "$dir/http.pid"
}

# --- QEMU -------------------------------------------------------------------

# dv_start_qemu <name> <http-port>: starts QEMU in its own session, records
# the pid (QEMU writes it) and the SSH port. Retries with a new port if the
# chosen one was taken in the meantime.
dv_start_qemu() {
  local name=$1 http_port=$2 dir=$DV_VMS/$1
  local cpus=${DOMOVYK_VM_CPUS:-4} ram=${DOMOVYK_VM_RAM:-6G}
  local attempt port launcher i started
  local -a gpu args
  if [[ ! $cpus =~ ^[1-9][0-9]*$ ]]; then
    dv_die "DOMOVYK_VM_CPUS must be a positive integer, got '$cpus'"
  fi
  if [[ ! $ram =~ ^[1-9][0-9]*[MG]?$ ]]; then
    dv_die "DOMOVYK_VM_RAM must look like 6G or 6144M, got '$ram'"
  fi
  read -r -a gpu <<<"${DOMOVYK_VM_GPU_ARGS-$DV_DEFAULT_GPU_ARGS}"

  for attempt in 1 2 3; do
    port=$(dv_free_port)
    rm -f -- "$dir/pid"
    # shellcheck disable=SC2054 # commas belong to QEMU option values
    args=(
      -name "$name"
      -machine q35
      -enable-kvm
      -cpu host
      -smp "$cpus"
      -m "$ram"
      -nographic
      -serial "file:$dir/serial.log"
      -monitor none
      -parallel none
      # Overlays are thrown away, so guest flushes can be skipped. The base
      # image is opened without QEMU's image locks: base images are never
      # written in place, and one from DOMOVYK_VM_IMAGE_DIR belongs to
      # another harness, whose folder Domovyk does not lock.
      -drive "file=$dir/overlay.qcow2,if=virtio,format=qcow2,cache=unsafe,discard=unmap,backing.file.locking=off"
      # The NVMe data disk (see the header).
      -drive "file=$dir/nvme.qcow2,if=none,id=nvme0,format=qcow2,cache=unsafe,discard=unmap"
      -device nvme,drive=nvme0,serial=domovyk-nvme0
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22"
      -device virtio-net-pci,netdev=net0
      -device virtio-rng-pci
      # NoCloud over HTTP. i= lets cloud-init trust its cache on reboot,
      # when the seed server is gone.
      -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$http_port/;i=domovyk-$name"
      -pidfile "$dir/pid"
      "${gpu[@]}"
    )
    setsid qemu-system-x86_64 "${args[@]}" </dev/null >"$dir/qemu.log" 2>&1 &
    launcher=$!
    started=false
    for ((i = 0; i < 30; i++)); do
      sleep 0.2
      if dv_qemu_pid "$name" >/dev/null; then
        # Alive 2 s after start: device and network setup succeeded.
        if ((i >= 10)); then
          started=true
          break
        fi
      elif ! kill -0 "$launcher" 2>/dev/null; then
        break
      fi
    done
    if ! $started && dv_qemu_pid "$name" >/dev/null; then
      started=true
    fi
    if $started; then
      printf '%s\n' "$port" >"$dir/ssh.port"
      return 0
    fi
    kill "$launcher" 2>/dev/null || true
    if grep -qi 'host forwarding' "$dir/qemu.log" && ((attempt < 3)); then
      dv_log "SSH port $port was taken, retrying"
      continue
    fi
    cat "$dir/qemu.log" >&2 || true
    dv_die "QEMU failed to start $name"
  done
}

dv_boot_failed() {
  local name=$1 msg=$2
  dv_log "serial console of $name (last 60 lines):"
  tail -n 60 "$DV_VMS/$name/serial.log" >&2 || true
  dv_die "$name: $msg"
}

# dv_wait_ready <name>: waits until SSH answers and cloud-init has finished.
dv_wait_ready() {
  local name=$1 dir=$DV_VMS/$1 deadline remaining rc
  deadline=$((SECONDS + DV_BOOT_TIMEOUT))
  dv_ssh_args "$name"
  dv_log "waiting for SSH on 127.0.0.1:$(<"$dir/ssh.port")"
  until timeout 30 "${DV_SSH[@]}" true </dev/null >/dev/null 2>&1; do
    if ! dv_qemu_pid "$name" >/dev/null; then
      dv_boot_failed "$name" "QEMU exited during boot"
    fi
    if ((SECONDS >= deadline)); then
      dv_boot_failed "$name" "timed out after $DV_BOOT_TIMEOUT s waiting for SSH"
    fi
    sleep 3
  done
  remaining=$((deadline - SECONDS))
  if ((remaining < 1)); then
    remaining=1
  fi
  dv_log "waiting for cloud-init to finish"
  rc=0
  timeout "$remaining" "${DV_SSH[@]}" cloud-init status --wait </dev/null >/dev/null 2>&1 || rc=$?
  case $rc in
    0) ;;
    2)
      dv_log "warning: cloud-init finished with recoverable errors:"
      "${DV_SSH[@]}" cloud-init status --long </dev/null >&2 || true
      ;;
    124)
      dv_boot_failed "$name" "timed out after $DV_BOOT_TIMEOUT s waiting for cloud-init"
      ;;
    *)
      "${DV_SSH[@]}" cloud-init status --long </dev/null >&2 || true
      dv_boot_failed "$name" "cloud-init failed (exit code $rc)"
      ;;
  esac
}

# dv_boot <release> <variant> <backing-image>: creates an overlay and the
# NVMe data disk, boots them and waits until the VM is ready. Sets DV_BOOTED
# to the VM name. The VM stays registered for cleanup; callers that keep it
# call dv_unregister.
dv_boot() {
  local release=$1 variant=$2 backing=$3 name dir
  name="$release-$variant-$(dv_hex6)"
  dir="$DV_VMS/$name"
  mkdir "$dir"
  DV_CLEANUP_VMS+=("$name")
  mkdir "$dir/seed"
  printf '%s\n' "$release" >"$dir/release"
  printf '%s\n' "$variant" >"$dir/variant"
  printf '%s\n' "$backing" >"$dir/backing"
  if [[ ! $DV_DISK_SIZE =~ ^[1-9][0-9]*G$ ]]; then
    dv_die "DOMOVYK_VM_DISK must look like 40G, got '$DV_DISK_SIZE'"
  fi
  # -u: qemu-img does not open (or lock) the backing image.
  qemu-img create -q -f qcow2 -F qcow2 -b "$backing" -u "$dir/overlay.qcow2" "$DV_DISK_SIZE"
  qemu-img create -q -f qcow2 "$dir/nvme.qcow2" "$DV_NVME_SIZE"
  dv_write_seed "$name"
  dv_start_http "$dir"
  dv_log "booting $name from $backing"
  dv_start_qemu "$name" "$DV_HTTP_PORT"
  dv_wait_ready "$name"
  # The seed server keeps running until dv_destroy: a reboot inside the VM
  # fetches the same seed (same instance-id), so cloud-init does not treat
  # the VM as new and regenerate its SSH host keys.
  DV_BOOTED=$name
}

# dv_save_logs <name>: copies the VM's logs to DOMOVYK_VM_RESULTS, if set.
dv_save_logs() {
  local name=$1 dir=$DV_VMS/$1 r=${DOMOVYK_VM_RESULTS:-}
  if [[ -z $r ]]; then
    return 0
  fi
  mkdir -p "$r"
  if [[ -f $dir/serial.log ]]; then
    cp -f "$dir/serial.log" "$r/$name.serial.log"
  fi
  if [[ -s $dir/qemu.log ]]; then
    cp -f "$dir/qemu.log" "$r/$name.qemu.log"
  fi
}

# dv_destroy <name>: stops the seed server, kills QEMU if it still runs and
# deletes the VM's state folder, including the overlay and the NVMe disk.
dv_destroy() {
  local name=$1 dir=$DV_VMS/$1 pid i
  dv_valid_name "$name" || return 1
  if [[ ! -d $dir ]]; then
    dv_unregister "$name"
    return 0
  fi
  dv_stop_http "$dir"
  if pid=$(dv_qemu_pid "$name"); then
    kill "$pid" 2>/dev/null || true
    for ((i = 0; i < 25; i++)); do
      dv_qemu_pid "$name" >/dev/null || break
      sleep 0.2
    done
    if pid=$(dv_qemu_pid "$name"); then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
  fi
  dv_save_logs "$name" || true
  rm -rf -- "$dir"
  dv_unregister "$name"
}

# dv_poweroff <name> <seconds>: clean shutdown over SSH. Returns 1 if QEMU
# still runs after <seconds>.
dv_poweroff() {
  local name=$1 seconds=$2
  if ! dv_qemu_pid "$name" >/dev/null; then
    return 0
  fi
  if [[ -r $DV_VMS/$name/ssh.port ]]; then
    dv_ssh_args "$name"
    timeout 30 "${DV_SSH[@]}" sudo systemctl poweroff </dev/null >/dev/null 2>&1 || true
  fi
  dv_wait_exit "$name" "$seconds"
}

# dv_rsync_rsh: prints the ssh command line for rsync -e. rsync splits it on
# spaces and honours quotes but not backslashes.
dv_rsync_rsh() {
  local out=ssh arg
  for arg in "${DV_SSH_OPTS[@]}"; do
    if [[ $arg =~ ^[A-Za-z0-9_./:=@,+-]+$ ]]; then
      out+=" $arg"
    elif [[ $arg != *"'"* ]]; then
      out+=" '$arg'"
    else
      dv_die "cannot pass '$arg' to rsync"
    fi
  done
  printf '%s\n' "$out"
}

# --- file copies ------------------------------------------------------------

# dv_copy_to_vm <name> <host-dir> <guest-dir>: copies the content of a host
# folder into a guest folder (created if needed) with tar over SSH.
dv_copy_to_vm() {
  local name=$1 src=$2 dest=$3 q
  dv_ssh_args "$name"
  printf -v q '%q' "$dest"
  tar -C "$src" -cf - . | "${DV_SSH[@]}" "mkdir -p -- $q && tar -C $q -xf -"
}

# dv_copy_from_vm <name> <guest-dir> <host-dir>: copies the content of a
# guest folder into a host folder (created if needed) with tar over SSH.
# The host folder must be inside ~/.cache/domovyk-vm/.
dv_copy_from_vm() {
  local name=$1 src=$2 dest=$3 q
  if [[ $dest != "$DV_STATE"/* || $dest == *..* ]]; then
    dv_die "refusing to copy into $dest: not under $DV_STATE/"
  fi
  dv_ssh_args "$name"
  printf -v q '%q' "$src"
  mkdir -p "$dest"
  "${DV_SSH[@]}" "tar -C $q -cf - ." </dev/null | tar -C "$dest" --no-same-owner -xf -
}
