#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# domovyk hw against fixtures: CPU, GPUs with drivers, memory, battery
# health, firmware and model; no battery; no serial numbers or UUIDs in the
# output (requirements 14.3, 14.4, 1.3, 1.4, 4.1, 4.3, 4.6).
#
# Fixtures: sysroot/hw-laptop with lspci/hw-laptop (captured on a 26.04
# laptop, cpuinfo cut to six CPUs), sysroot/hw-desktop with lspci/hw-desktop
# (no system battery, only a mouse's; serial and UUID files planted with
# MARKER values), sysroot/hw-energy (an energy-reporting battery, an empty
# second slot, no lspci, no DMI folder).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
}

check_doc() {
  assert_equal "$(jq -s length <<<"$1")" 1
  jq -e -f "$REPO/test/unit/schemas/envelope.jq" <<<"$1" >/dev/null || fail "Envelope check failed"
  jq -e -f "$REPO/test/unit/schemas/hw.jq" <<<"$1" >/dev/null || fail "hw predicate failed"
  local want got
  want=$(awk -F'\t' '$1 == "domovyk.hw.v1" { print $2 }' "$REPO/test/unit/schemas/keys.tsv" | tr ' ' '\n' | sort)
  [[ -n $want ]] || fail "domovyk.hw.v1 has no key list"
  got=$(jq -r 'keys[] | select(IN("schema", "generated", "host", "unavailable") | not)' <<<"$1" | sort)
  assert_equal "$got" "$want"
}

fits() {
  local long
  long=$(jq -Rr 'select(length > 100)' <<<"$output")
  [[ -z $long ]] || fail "lines over 100 columns: $long"
}

has() {
  jq -e "$1" <<<"$output" >/dev/null || fail "not true: $1"
}

# machine <case>: that sysroot, with lspci replaying the same case.
machine() {
  only_path
  use_fakes lspci
  export FAKE_CASE=$1
  use_sysroot "$1"
}

@test "hw reports the CPU, GPUs with drivers, memory, battery, firmware and model (14.3)" {
  machine hw-laptop
  run -0 "$DOMOVYK" hw --json
  check_doc "$output"
  has '.unavailable == []'
  has '.cpu == {model: "13th Gen Intel(R) Core(TM) i9-13900H", sockets: 1, cores: 4, threads: 6}'
  has '.gpus == [{slot: "0000:00:02.0", class: "VGA compatible controller", vendor: "Intel Corporation",
    vendor_id: "8086", device: "Raptor Lake-P [Iris Xe Graphics]", device_id: "a7a0", driver: "i915",
    modules: ["i915", "xe"]}]'
  has '.memory_bytes == 32667099136'
  has '.battery == [{name: "BAT0", unit: "uAh", design: 8442000, full: 7875000, health_percent: 93.3,
    capacity_percent: 100, status: "Not charging", cycle_count: 34, technology: "Li-poly"}]'
  has '.firmware == {vendor: "Dell Inc.", version: "1.32.0"}'
  has '.machine == {vendor: "Dell Inc.", model: "Precision 5680"}'
}

@test "the hw text view shows each fact and fits in 100 columns (14.3, 4.1)" {
  machine hw-laptop
  run -0 "$DOMOVYK" hw
  assert_line 'cpu       13th Gen Intel(R) Core(TM) i9-13900H (4 cores, 6 threads)'
  assert_line 'memory    30.4G'
  assert_line 'gpu       Intel Corporation Raptor Lake-P [Iris Xe Graphics] [8086:a7a0]'
  assert_line '          driver i915, modules i915, xe at 0000:00:02.0'
  assert_line 'battery   BAT0: health 93.3 %, 7.88 Ah of 8.44 Ah design, 100 % charged, not charging, 34 cycles'
  assert_line 'firmware  Dell Inc. 1.32.0'
  assert_line 'machine   Dell Inc. Precision 5680'
  fits
}

@test "only display controllers are listed as GPUs, each with its driver (14.3)" {
  machine hw-desktop
  run -0 "$DOMOVYK" hw --json
  check_doc "$output"
  has '[.gpus[] | {slot, class, driver}] == [
    {slot: "0000:01:00.0", class: "VGA compatible controller", driver: "nvidia"},
    {slot: "0000:12:00.0", class: "Display controller", driver: null}]'
  has '.gpus[0].modules == ["nvidiafb", "nouveau", "nvidia_drm", "nvidia"] and .gpus[1].modules == ["amdgpu"]'
  has '.gpus[0].device == "AD104 [GeForce RTX 4070]" and .gpus[1].vendor == "Advanced Micro Devices, Inc. [AMD/ATI]"'
  run -0 "$DOMOVYK" hw
  assert_line '          driver none, modules amdgpu at 0000:12:00.0'
  fits
}

@test "no battery: battery is null and nothing is reported missing (14.4)" {
  machine hw-desktop
  run -0 "$DOMOVYK" hw --json
  has '.battery == null and .unavailable == []'
  has '.cpu == {model: "AMD Ryzen 7 7700X 8-Core Processor", sockets: 1, cores: 2, threads: 4}'
  has '.firmware == {vendor: "American Megatrends International, LLC.", version: "1.A0"}'
  run -0 --separate-stderr "$DOMOVYK" hw
  assert_line 'battery   none'
  refute_output --partial 'hidpp'
  refute_output --partial 'unavailable'
  assert_equal "$stderr" ''
}

# no_markers: none of the planted serial numbers or UUIDs is printed, in
# text, JSON or unredacted JSON.
no_markers() {
  run -0 "$DOMOVYK" hw
  refute_output --partial MARKER
  run -0 "$DOMOVYK" hw --json
  refute_output --partial MARKER
  refute_output --partial 'a0a0a0a0-1111'
  run -0 "$DOMOVYK" hw --json --raw
  refute_output --partial MARKER
  refute_output --partial 'a0a0a0a0-1111'
}

@test "no DMI serial number or UUID, or a mouse's serial, reaches the output (14.3)" {
  machine hw-desktop
  no_markers
}

@test "no battery serial number reaches the output (14.3)" {
  only_path
  use_sysroot hw-energy
  no_markers
}

@test "an energy-reporting battery is in uWh, and an empty battery slot is skipped (14.3)" {
  only_path
  use_sysroot hw-energy
  run -0 "$DOMOVYK" hw --json
  check_doc "$output"
  has '.battery == [{name: "BAT0", unit: "uWh", design: 57020000, full: 45210000, health_percent: 79.3,
    capacity_percent: 81, status: "Discharging", cycle_count: 412, technology: "Li-ion"}]'
  has '.cpu == {model: "11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz", sockets: null, cores: null, threads: 2}'
  run -0 "$DOMOVYK" hw
  assert_line 'battery   BAT0: health 79.3 %, 45.21 Wh of 57.02 Wh design, 81 % charged, discharging, 412 cycles'
  assert_line 'cpu       11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz (2 threads)'
  fits
}

@test "without lspci, GPUs come from sysfs and lspci is reported missing (1.3, 1.4)" {
  only_path
  use_sysroot hw-energy
  run -0 "$DOMOVYK" hw --json
  has '.gpus == [{slot: "0000:00:02.0", class: null, vendor: null, vendor_id: "8086", device: null,
    device_id: "9a49", driver: "i915", modules: []}]'
  has '.unavailable | index([{source: "lspci", reason: "missing", package: "pciutils"}]) != null'
  run -0 "$DOMOVYK" hw
  assert_line 'gpu       PCI display device [8086:9a49]'
  assert_line '  lspci: missing (apt install pciutils)'
}

@test "without DMI, firmware and machine are null and reported missing (1.3, 1.4)" {
  only_path
  use_sysroot hw-energy
  run -0 "$DOMOVYK" hw --json
  has '.firmware == null and .machine == null'
  has '.unavailable | index([{source: "/sys/class/dmi/id", reason: "missing"}]) != null'
  run -0 "$DOMOVYK" hw
  assert_line 'firmware  unknown'
  assert_line 'machine   unknown'
}

@test "hw takes no arguments" {
  machine hw-laptop
  run -2 --separate-stderr "$DOMOVYK" hw extra
  [[ $stderr == *"unexpected argument: extra"* ]]
}
