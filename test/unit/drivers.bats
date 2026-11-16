#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2030,SC2031 # each test sets its own environment
# domovyk drivers: devices, ubuntu-drivers candidates, DKMS, Secure Boot and
# MOK, fwupd devices, missing Sources (requirements 9.1-9.5, with 1.3, 1.4,
# 4.1-4.4 and 4.6). Sources are Fake_Bins replaying fixtures/<tool>/drivers-*
# (redacted captures from a laptop with an Intel IPU6 camera, plus synthetic
# cases); sysfs and /var/lib/dkms come from fixtures/sysroot/drivers-*.

bats_require_minimum_version 1.5.0

TOOLS=(lspci lsusb ubuntu-drivers dpkg-query dkms mokutil fwupdmgr)

setup() {
  load helpers
  dv_setup
  export FAKE_CASE=drivers-host
  use_sysroot drivers-host
}

# with_tools <tool...>: these Sources are Fake_Bins; every other Source is
# missing, so the real machine never leaks into a test.
with_tools() {
  (($#)) && use_fakes "$@"
  only_path
}

# check_doc <predicate>: $output is one JSON document that passes the
# Envelope, test/unit/schemas/<predicate>.jq and its schema's key list.
check_doc() {
  local schema want got
  assert_equal "$(jq -s length <<<"$output")" 1
  jq -e -f "$REPO/test/unit/schemas/envelope.jq" <<<"$output" >/dev/null || fail "Envelope check failed"
  jq -e -f "$REPO/test/unit/schemas/$1.jq" <<<"$output" >/dev/null || fail "schema predicate $1 failed"
  schema=$(jq -r .schema <<<"$output")
  want=$(awk -F'\t' -v s="$schema" '$1 == s { print $2 }' "$REPO/test/unit/schemas/keys.tsv" | tr ' ' '\n' | sort)
  [[ -n $want ]] || fail "schema $schema has no key list"
  got=$(jq -r 'keys[] | select(IN("schema", "generated", "host", "unavailable") | not)' <<<"$output" | sort)
  assert_equal "$got" "$want"
}

# assert_fits: every line of $output is at most 100 columns (4.1). Counts
# characters, not bytes, because "…" is one column but three bytes.
assert_fits() {
  local wide
  wide=$(python3 -I -c 'import sys
for i, l in enumerate(sys.stdin.read().splitlines(), 1):
    if len(l) > 100:
        print(f"line {i} has {len(l)} columns: {l}")' <<<"$output")
  [[ -z $wide ]] || fail "$wide"
}

# jqo <program>: a jq predicate that must hold for $output (kept as is).
jqo() {
  jq -e "$1" <<<"$output" >/dev/null || fail "does not hold: $1"
}

@test "PCI and USB devices carry their IDs, names and kernel drivers (9.1)" {
  with_tools "${TOOLS[@]}"
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '.unavailable == []'
  jqo '([.devices[] | select(.bus == "pci")] | length) == 27 and ([.devices[] | select(.bus == "usb")] | length) == 6'
  # The Intel IPU6 camera, bound to the in-kernel intel-ipu6 driver.
  jqo '.devices[] | select(.address == "0000:00:05.0")
    == {bus: "pci", address: "0000:00:05.0", vendor_id: "8086", product_id: "a75d", class: "0480",
        class_name: "Multimedia controller", vendor: "Intel Corporation", name: "Raptor Lake IPU",
        driver: "intel-ipu6"}'
  jqo '.devices[] | select(.address == "0000:00:08.0") | .driver == null and .name == "GNA Scoring Accelerator module"'
  # A USB device's driver is the one bound to its interfaces; its name comes from lsusb.
  jqo '.devices[] | select(.address == "3-7")
    | .vendor_id == "8086" and .product_id == "0b63" and .driver == "ljca" and .name == "Intel Corp. USB Bridge"'
  jqo '.devices[] | select(.address == "3-9") | .driver == null and .vendor == "Goodix Technology Co., Ltd."'
}

@test "device names fall back to sysfs, and IDs stay, without lspci and lsusb (9.1, 1.3)" {
  with_tools ubuntu-drivers dpkg-query dkms mokutil fwupdmgr
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '[.unavailable[] | [.source, .package]] == [["lspci", "pciutils"], ["lsusb", "usbutils"]]'
  jqo '.devices[] | select(.address == "0000:00:05.0") | .name == null and .driver == "intel-ipu6" and .product_id == "a75d"'
  jqo '.devices[] | select(.address == "3-9") | .name == "Goodix USB2.0 MISC"'
}

@test "the IPU6 candidate from ubuntu-drivers is listed as installed and recommended (9.2)" {
  with_tools "${TOOLS[@]}"
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  jqo '.candidates == [{package: "intel-ipu6-dkms", installed: true, recommended: true,
    version: "0~git202603270946.51fe7248-0ubuntu1", kernel_modules: null}]'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_line --regexp '^  intel-ipu6-dkms +installed 0~git.* recommended$'
}

@test "a candidate dpkg does not know is not installed (9.2)" {
  with_tools "${TOOLS[@]}"
  export FAKE_CASE_DPKG_QUERY=drivers-not-installed
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '.candidates == [{package: "intel-ipu6-dkms", installed: false, recommended: true, version: null,
    kernel_modules: null}]'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_line --regexp '^  intel-ipu6-dkms +not installed +recommended$'
}

@test "DKMS status is reported per module, version and kernel (9.3)" {
  with_tools "${TOOLS[@]}"
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  jqo '.dkms.kernel == "7.0.0-43-generic"
    and ([.dkms.modules[] | [.module, .kernel, .state]]
      == [["ipu6-drivers", "7.0.0-42-generic", "installed"], ["ipu6-drivers", "7.0.0-43-generic", "installed"]])'
}

@test "a DKMS module that failed to build for the running kernel names its make.log (9.5)" {
  with_tools "${TOOLS[@]}"
  export FAKE_CASE_DKMS=drivers-dkms-failed
  use_sysroot drivers-dkms-failed
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '.dkms.kernel == "7.0.0-43-generic"'
  jqo '.dkms.modules[] | select(.module == "ipu6-drivers" and .kernel == "7.0.0-43-generic")
    | .state == "build-failed"
      and .log == "/var/lib/dkms/ipu6-drivers/0~git202603270946.51fe7248/build/make.log"'
  # Installed for an older kernel only; added but never built; fine.
  jqo '.dkms.modules[] | select(.module == "ipu6-drivers" and .kernel == "7.0.0-42-generic") | .state == "installed"'
  jqo '.dkms.modules[] | select(.module == "nvidia") | .state == "not-built" and .kernel == "7.0.0-43-generic" and .log == null'
  jqo '.dkms.modules[] | select(.module == "v4l2loopback") | .state == "installed"'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_fits
  assert_line --regexp '^  ipu6-drivers/0~git202603270946\.51fe7248 +7\.0\.0-43-generic +build-failed$'
  assert_line '      build log: /var/lib/dkms/ipu6-drivers/0~git202603270946.51fe7248/build/make.log'
}

@test "Secure Boot state and a pending MOK enrolment are reported (9.3)" {
  with_tools "${TOOLS[@]}"
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  jqo '.secure_boot == {state: "disabled", mok_pending: false, mok_new_keys: 0}'
  export FAKE_CASE_MOKUTIL=drivers-sb-mok
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '.secure_boot == {state: "enabled", mok_pending: true, mok_new_keys: 1}'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_line 'secure boot: enabled; MOK enrolment pending: yes (1 key)'
  # The key itself stays out of the output.
  refute_output --partial 'Fingerprint'
  refute_output --partial 'CN='
}

@test "a refused mokutil --list-new is recorded as permission (9.3, 1.3)" {
  with_tools "${TOOLS[@]}"
  export FAKE_CASE_MOKUTIL=drivers-mok-permission
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '.secure_boot == {state: "enabled", mok_pending: null, mok_new_keys: null}'
  jqo '.unavailable == [{source: "mokutil --list-new", reason: "permission"}]'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_line 'secure boot: enabled; MOK enrolment pending: unknown'
  assert_line '  mokutil --list-new: permission'
}

@test "fwupd devices are listed with firmware versions and no serials or GUIDs (9.4)" {
  with_tools "${TOOLS[@]}"
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '(.firmware_devices | length) == 9'
  jqo '.firmware_devices[] | select(.name == "System Firmware")
    == {name: "System Firmware", vendor: "Dell", version: "1.32.0", plugin: "uefi_capsule", updatable: true}'
  refute_output --partial 'FIXTURE-SERIAL'
  refute_output --partial '00000000-0000-4000-8000-000000000000'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_line --regexp '^  System Firmware +Dell +1\.32\.0 +updatable$'
}

@test "without ubuntu-drivers the candidates are unknown and the package is named (1.3, 1.4)" {
  with_tools lspci lsusb dpkg-query dkms mokutil fwupdmgr
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '.unavailable == [{source: "ubuntu-drivers", reason: "missing", package: "ubuntu-drivers-common"}]'
  jqo '.candidates == null and (.devices | length) == 33 and .dkms != null and .firmware_devices != null'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_line 'candidates (ubuntu-drivers): unknown'
  assert_line '  ubuntu-drivers: missing (apt install ubuntu-drivers-common)'
}

@test "without fwupdmgr the firmware devices are unknown and fwupd is named (1.3, 1.4)" {
  with_tools lspci lsusb ubuntu-drivers dpkg-query dkms mokutil
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '.unavailable == [{source: "fwupdmgr", reason: "missing", package: "fwupd"}] and .firmware_devices == null'
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_line 'firmware (fwupd): unknown'
  assert_line '  fwupdmgr: missing (apt install fwupd)'
}

@test "with every Source missing the Command still exits 0 and names each package (1.3, 1.4)" {
  with_tools
  run -0 --separate-stderr "$DOMOVYK" drivers --json
  check_doc drivers
  jqo '[.unavailable[] | .package] == ["pciutils", "usbutils", "ubuntu-drivers-common", "dkms", "mokutil", "fwupd"]'
  jqo '.secure_boot.state == "unknown" and .dkms == null and .candidates == null'
}

@test "the text view lists every device and fits in 100 columns (9.1, 4.1)" {
  with_tools "${TOOLS[@]}"
  run -0 --separate-stderr "$DOMOVYK" drivers
  assert_fits
  assert_line 'devices: 27 PCI, 6 USB; 4 without a driver'
  assert_line --regexp '^  pci 0000:00:05\.0 +8086:a75d  intel-ipu6 +Raptor Lake IPU$'
  # A device without a driver also shows its class.
  assert_line --regexp '^  pci 0000:00:14\.2 +8086:51ef  - +Alder Lake PCH Shared SRAM \(RAM memory\)$'
  assert_line --regexp '^  usb 3-7 +8086:0b63  ljca +Intel Corp\. USB Bridge$'
}

@test "drivers takes no arguments (4.4)" {
  run -2 "$DOMOVYK" drivers extra
  assert_output --partial 'unexpected argument: extra'
}
