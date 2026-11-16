#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # stub bodies and jq programs are single-quoted on purpose
# shellcheck disable=SC2030,SC2031 # each test sets its own environment
# domovyk perf against fixtures: load, memory, swap, zram, pressure, top
# processes, thermal zones, throttling, power profile, --boot and --sample
# (requirements 12.1-12.5, 1.3, 1.4, 4.1, 4.3, 4.6).
#
# Fixtures: sysroot/perf-laptop (captured on a 26.04 laptop, process table
# and blame list made generic), sysroot/perf-vm (a VM under memory pressure
# with zram and no thermal sensors), sysroot/perf-throttled (throttle
# counters on two packages, nothing else), sysroot/perf-sample-after (the
# second /proc/stat and /proc/diskstats snapshot, 2 s later).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
  : >"$FAKE_LOG"
}

# check_doc <json>: the Envelope, the perf predicate and the documented keys.
check_doc() {
  assert_equal "$(jq -s length <<<"$1")" 1
  jq -e -f "$REPO/test/unit/schemas/envelope.jq" <<<"$1" >/dev/null || fail "Envelope check failed"
  jq -e -f "$REPO/test/unit/schemas/perf.jq" <<<"$1" >/dev/null || fail "perf predicate failed"
  local want got
  want=$(awk -F'\t' '$1 == "domovyk.perf.v1" { print $2 }' "$REPO/test/unit/schemas/keys.tsv" | tr ' ' '\n' | sort)
  [[ -n $want ]] || fail "domovyk.perf.v1 has no key list"
  got=$(jq -r 'keys[] | select(IN("schema", "generated", "host", "unavailable") | not)' <<<"$1" | sort)
  assert_equal "$got" "$want"
}

# fits: no line of $output is longer than 100 characters (4.1).
fits() {
  local long
  long=$(jq -Rr 'select(length > 100)' <<<"$output")
  [[ -z $long ]] || fail "lines over 100 columns: $long"
}

# has <jq-filter>: the JSON in $output satisfies the filter.
has() {
  jq -e "$1" <<<"$output" >/dev/null || fail "not true: $1"
}

laptop() {
  only_path
  use_fakes nproc ps powerprofilesctl systemd-analyze journalctl
  export FAKE_CASE=perf-laptop
  use_sysroot perf-laptop
}

vm() {
  only_path
  use_fakes nproc ps powerprofilesctl journalctl
  export FAKE_CASE=perf-vm
  use_sysroot perf-vm
}

# A writable copy of perf-laptop whose sleep swaps in the second snapshot.
sampling() {
  laptop
  cp -r "$REPO/test/unit/fixtures/sysroot/perf-laptop" "$BATS_TEST_TMPDIR/sysroot"
  export DOMOVYK_SYSROOT="$BATS_TEST_TMPDIR/sysroot"
  export AFTER="$REPO/test/unit/fixtures/sysroot/perf-sample-after"
  stub sleep 'echo "$1" >"$HOME/slept"
cp "$AFTER/proc/stat" "$AFTER/proc/diskstats" "$DOMOVYK_SYSROOT/proc/"'
}

@test "perf reports load, CPU count, memory, swap, zram and pressure (12.1)" {
  laptop
  run -0 "$DOMOVYK" perf --json
  check_doc "$output"
  has '.unavailable == []'
  has '.load == {avg1: 2.57, avg5: 3.23, avg15: 3.96, running: 3, total: 2308}'
  has '.cpu_count == 20'
  has '.memory == {total_bytes: 32667099136, available_bytes: 16379981824,
    used_bytes: 16287117312, used_percent: 49.9}'
  has '.swap.total_bytes == 68719472640 and .swap.used_bytes == 9840140288 and .swap.used_percent == 14.3'
  has '.swap.devices == [{name: "/swap.img", type: "file", size_bytes: 68719472640,
    used_bytes: 9840140288, priority: -1}]'
  has '.zram == []'
  has '.pressure.memory.some == {avg10: 0.08, avg60: 0.04, avg300: 0.05, total_us: 282339166}'
  has '.pressure.io.full.avg300 == 0.01 and .pressure.cpu.full.total_us == 0'
}

@test "perf lists the 10 processes using the most CPU and the most memory (12.1)" {
  laptop
  run -0 "$DOMOVYK" perf --json
  has '[.top_cpu[].pid] == [6011, 6150, 5120, 4519, 2402, 4410, 7601, 4580, 7202, 3301]'
  has '[.top_memory[].pid] == [6150, 6011, 4519, 7601, 4410, 2402, 4580, 7650, 4472, 4602]'
  has '.top_cpu[0] == {pid: 6011, uid: 1000, command: "qemu-system-x86", cpu_percent: 118,
    rss_bytes: 1288699904, memory_percent: 3.9}'
  has '.top_memory[0].memory_percent == 6.6 and .top_memory[8].command == "Web Content"'
  run -0 "$DOMOVYK" perf
  assert_line '      6011   1000  118.0     1.2G  qemu-system-x86'
  assert_line '      4472   1000    0.5   162.5M  Web Content'
}

@test "the command's own ps and timeout are not listed as top processes" {
  laptop
  rm -f "$STUBS/ps"
  # Our ps runs under our timeout, which runs under the command's shell; both
  # are rated 100 % here, as ps rates a process that has just started.
  stub ps 'cat "$FIXTURES/ps/perf-laptop/-eo_pid__ppid__uid__pcpu__rss__comm_"
read -r _ _ _ grand _ </proc/$PPID/stat
printf "%7s %7s %5s %4s %7s %s\n" "$PPID" "$grand" 1000 100 2048 timeout "$$" "$PPID" 1000 100 4096 ps'
  run -0 "$DOMOVYK" perf --json
  has '[.top_cpu[].command] | index("ps") == null and index("timeout") == null'
  has '.top_cpu[0].pid == 6011'
}

@test "perf reports pressure, zram and swap on a VM under memory pressure (12.1)" {
  vm
  run -0 "$DOMOVYK" perf --json
  check_doc "$output"
  has '.pressure.memory == {some: {avg10: 62.15, avg60: 48.9, avg300: 30.12, total_us: 1734567890},
    full: {avg10: 41.02, avg60: 30.55, avg300: 18.4, total_us: 1201234567}}'
  has '.pressure.cpu.some.avg10 == 35.2 and .pressure.io.some.avg60 == 12.8'
  has '.zram == [{device: "zram0", disksize_bytes: 2054160384, algorithm: "zstd",
    orig_data_bytes: 1634205696, compr_data_bytes: 410128384, mem_used_bytes: 425984000}]'
  has '.swap.used_percent == 79.6 and .swap.devices[0].name == "/dev/zram0"'
  has '.memory.used_percent == 92.5 and .cpu_count == 4'
  run -0 "$DOMOVYK" perf
  assert_line '  memory   some 62.15 48.90 30.12   full 41.02 30.55 18.40'
  assert_line 'zram       zram0 zstd 1.9G: 1.5G stored in 406.2M'
  fits
}

@test "perf reports thermal zones, throttle counters and the power profile (12.2)" {
  laptop
  run -0 "$DOMOVYK" perf --json
  has '(.thermal | length) == 14'
  has '.thermal[0] == {zone: "thermal_zone0", type: "INT3400 Thermal", celsius: 20}'
  has '.thermal[13] == {zone: "thermal_zone13", type: "x86_pkg_temp", celsius: 47}'
  has '.throttling == {source: "sysfs", events: 0, core_events: 0, package_events: 0, cpus_throttled: 0}'
  has '.power_profile == "balanced"'
  run -0 "$DOMOVYK" perf
  assert_line 'throttling 0 events since boot (core 0, package 0; 0 CPUs throttled)'
  assert_line 'power      balanced'
  assert_line --regexp '^thermal    INT3400 Thermal 20\.0C, '
}

@test "throttling counts core events per CPU and package events once per package (12.2)" {
  only_path
  use_fakes nproc ps powerprofilesctl
  export FAKE_CASE=perf-laptop
  use_sysroot perf-throttled
  run -0 "$DOMOVYK" perf --json
  check_doc "$output"
  has '.throttling == {source: "sysfs", events: 29, core_events: 20, package_events: 9, cpus_throttled: 3}'
  run -0 "$DOMOVYK" perf
  assert_line 'throttling 29 events since boot (core 20, package 9; 3 CPUs throttled)'
}

@test "without throttle counters, throttling counts kernel log lines of this boot (12.2)" {
  vm
  run -0 "$DOMOVYK" perf --json
  has '.throttling == {source: "kernel-log", events: 2, core_events: null, package_events: null,
    cpus_throttled: null}'
  has '.thermal == []'
  run grep -c '^journalctl -k -b 0 --grep throttled -o cat --no-pager$' "$FAKE_LOG"
  assert_output 1
}

@test "missing /proc files and pressure information are reported and perf exits 0 (1.3, 1.4)" {
  only_path
  use_fakes nproc ps powerprofilesctl
  export FAKE_CASE=perf-laptop
  use_sysroot perf-throttled
  run -0 "$DOMOVYK" perf --json
  has '.pressure == null and .load == null and .memory == null and .swap == null'
  has '.unavailable | index([{source: "/proc/pressure", reason: "missing",
    hint: "the kernel runs without pressure stall information (boot option psi=1)"}]) != null'
  has '.unavailable | map(.source) | index("/proc/loadavg") != null'
  has '.top_cpu | length == 10'
}

@test "no power-profiles-daemon: the power profile is null and reported missing with its package (12.2, 1.3)" {
  only_path
  use_fakes nproc ps
  export FAKE_CASE=perf-laptop
  use_sysroot perf-laptop
  run -0 "$DOMOVYK" perf --json
  check_doc "$output"
  has '.power_profile == null'
  has '.unavailable == [{source: "powerprofilesctl", reason: "missing", package: "power-profiles-daemon"}]'
  run -0 "$DOMOVYK" perf
  assert_line 'power      unknown'
  assert_line '  powerprofilesctl: missing (apt install power-profiles-daemon)'
}

@test "a power-profiles-daemon that is not running is reported, and perf exits 0 (1.3, 1.4)" {
  vm
  run -0 "$DOMOVYK" perf --json
  has '.power_profile == null'
  has '.unavailable == [{source: "power-profiles-daemon", reason: "missing", package: "power-profiles-daemon",
    hint: "powerprofilesctl could not reach the daemon"}]'
}

@test "--boot reports the total boot time and the 10 slowest units (12.3)" {
  laptop
  run -0 "$DOMOVYK" perf --boot --json
  check_doc "$output"
  has '.boot.finished and .boot.total_seconds == 69.571 and .boot.message == null'
  has '.boot.phases == {firmware: 8.78, loader: 2.221, kernel: 0.987, initrd: 8.345, userspace: 49.238}'
  has '.boot.target == "graphical.target" and .boot.target_seconds == 25.19'
  has '[.boot.slowest[].unit] == ["snapd.seeded.service", "apport-autoreport.service",
    "kdump-tools.service", "systemd-binfmt.service", "proc-sys-fs-binfmt_misc.mount",
    "dracut-initqueue.service", "systemd-cryptsetup@dm_crypt\\x2d0.service",
    "NetworkManager-wait-online.service", "plymouth-quit-wait.service", "systemd-suspend.service"]'
  has '.boot.slowest[0].seconds == 61.25 and .boot.slowest[9].seconds == 2.717'
  has '.sample == null'
  run -0 "$DOMOVYK" perf --boot
  assert_line --regexp '^boot       69\.6 s total: firmware 8\.8 s, loader 2\.2 s, kernel 1\.0 s, '
  assert_line '           graphical.target reached after 25.2 s in userspace'
  assert_line '     61.3 s  snapd.seeded.service'
  fits
}

@test "--boot leaves out .device units, whose names carry disk serials and UUIDs" {
  laptop
  run -0 "$DOMOVYK" perf --boot --json
  has '[.boot.slowest[].unit | select(endswith(".device"))] == []'
  refute_output --partial 'SERIAL0000001'
  run -0 "$DOMOVYK" perf --boot
  refute_output --partial '.device'
}

@test "--boot while the boot is still running reports it as not finished" {
  laptop
  export FAKE_CASE_SYSTEMD_ANALYZE=perf-unfinished
  run -0 "$DOMOVYK" perf --boot --json
  check_doc "$output"
  has '.boot == {finished: false, total_seconds: null, phases: null, target: null, target_seconds: null,
    message: "Bootup is not yet finished (org.freedesktop.systemd1.Manager.FinishTimestampMonotonic=0).",
    slowest: null}'
  run -0 "$DOMOVYK" perf --boot
  assert_line --partial 'boot       not finished: Bootup is not yet finished'
}

@test "--boot without systemd-analyze reports it missing and exits 0 (1.3)" {
  only_path
  use_fakes nproc ps powerprofilesctl
  export FAKE_CASE=perf-laptop
  use_sysroot perf-laptop
  run -0 "$DOMOVYK" perf --boot --json
  has '.boot == null'
  has '.unavailable == [{source: "systemd-analyze", reason: "missing", package: "systemd"}]'
}

@test "without --boot and --sample, boot and sample are null and nothing is sampled" {
  laptop
  stub sleep 'touch "$HOME/slept"'
  run -0 "$DOMOVYK" perf --json
  has '.boot == null and .sample == null'
  run grep -c '^systemd-analyze' "$FAKE_LOG"
  assert_output 0
  [[ ! -e $HOME/slept ]]
}

@test "--sample reports CPU and per-disk utilisation averaged over the interval (12.4)" {
  sampling
  run -0 "$DOMOVYK" perf --sample 2 --json
  check_doc "$output"
  assert_equal "$(cat "$HOME/slept")" 2
  has '.sample == {seconds: 2, cpu_busy_percent: 25, cpu_iowait_percent: 2.5, disks: [
    {device: "dm-0", util_percent: 30, read_bytes_per_s: 1048576, write_bytes_per_s: 2097152},
    {device: "dm-1", util_percent: 35, read_bytes_per_s: 1048576, write_bytes_per_s: 2097152},
    {device: "nvme0n1", util_percent: 25, read_bytes_per_s: 1048576, write_bytes_per_s: 2097152}]}'
  has '.boot == null'
}

@test "--sample lists whole disks only, and its text fits in 100 columns (12.4, 4.1)" {
  sampling
  run -0 "$DOMOVYK" perf --sample=2 --boot
  assert_line 'sample     2 s: CPU 25.0 % busy, 2.5 % iowait'
  assert_line '  nvme0n1      util 25.0 %, read 1M/s, write 2M/s'
  refute_output --partial 'nvme0n1p'
  refute_output --partial 'loop0'
  fits
}

@test "--sample accepts 1 and 10 seconds (12.4)" {
  laptop
  stub sleep 'echo "$1" >>"$HOME/slept"'
  run -0 "$DOMOVYK" perf --sample 1 --json
  has '.sample.seconds == 1 and .sample.cpu_busy_percent == null'
  run -0 "$DOMOVYK" perf --sample 10 --json
  has '.sample.seconds == 10'
  assert_equal "$(cat "$HOME/slept")" $'1\n10'
}

@test "--sample outside 1 to 10 exits 2 and prints no facts (12.5)" {
  laptop
  stub sleep 'touch "$HOME/slept"'
  local v
  for v in 0 11 -1 100 abc 1.5 ''; do
    run -2 --separate-stderr "$DOMOVYK" perf --sample "$v"
    assert_output ''
    [[ $stderr == *"--sample takes whole seconds from 1 to 10"* ]] || fail "value '$v': $stderr"
  done
  run -2 --separate-stderr "$DOMOVYK" perf --sample=11 --json
  assert_output ''
  run -2 --separate-stderr "$DOMOVYK" perf --sample
  assert_output ''
  [[ $stderr == *"--sample needs a number of seconds from 1 to 10"* ]]
  [[ ! -e $HOME/slept ]]
}

@test "an unknown argument exits 2" {
  laptop
  run -2 --separate-stderr "$DOMOVYK" perf --bogus
  [[ $stderr == *"unexpected argument: --bogus"* ]]
}

@test "the text view fits in 100 columns (4.1)" {
  laptop
  run -0 "$DOMOVYK" perf --boot
  fits
}
