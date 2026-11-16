#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# domovyk services and domovyk services status against fixtures: failed
# system and user units with their result and journal tails, one unit's
# status, unknown units, an older systemctl, no user manager and an
# unreadable system journal (requirements 14.1, 14.2, 1.3, 1.4, 4.1, 4.3,
# 4.6).
#
# Fake_Bin cases for systemctl and journalctl: services-failed (captured on a
# 26.04 laptop, plus a synthetic fwupd-refresh failure), services-none,
# services-plain (a systemctl without JSON tables, no user manager, a user
# outside adm and systemd-journal) and services-status.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
  : >"$FAKE_LOG"
}

# check_doc <schema-name> <json>: the Envelope, the schema's predicate and
# its documented keys.
check_doc() {
  assert_equal "$(jq -s length <<<"$2")" 1
  jq -e -f "$REPO/test/unit/schemas/envelope.jq" <<<"$2" >/dev/null || fail "Envelope check failed"
  jq -e -f "$REPO/test/unit/schemas/$1.jq" <<<"$2" >/dev/null || fail "$1 predicate failed"
  local want got
  want=$(awk -F'\t' -v s="domovyk.$1.v1" '$1 == s { print $2 }' "$REPO/test/unit/schemas/keys.tsv" | tr ' ' '\n' | sort)
  [[ -n $want ]] || fail "domovyk.$1.v1 has no key list"
  got=$(jq -r 'keys[] | select(IN("schema", "generated", "host", "unavailable") | not)' <<<"$2" | sort)
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

# fakes <case>: systemctl and journalctl replay that case; nothing else exists.
fakes() {
  only_path
  use_fakes systemctl journalctl
  export FAKE_CASE=$1
}

@test "services lists failed system and user units with their result (14.1)" {
  fakes services-failed
  run -0 "$DOMOVYK" services --json
  check_doc services "$output"
  has '.unavailable == []'
  has '[.failed_system[] | {unit, load, active, sub, result, since}] == [
    {unit: "apport-autoreport.service", load: "loaded", active: "failed", sub: "failed",
     result: "exit-code", since: "2026-11-16T02:00:36Z"},
    {unit: "fwupd-refresh.service", load: "loaded", active: "failed", sub: "failed",
     result: "timeout", since: "2026-11-16T01:00:12Z"}]'
  has '.failed_system[1].description == "Refresh fwupd metadata and update motd"'
  has '[.failed_user[] | {unit, result, since}] == [
    {unit: "mpris-proxy.service", result: "core-dump", since: "2026-11-11T05:53:38Z"}]'
}

@test "services shows the last 10 journal lines of each failed unit (14.1)" {
  fakes services-failed
  run -0 "$DOMOVYK" services --json
  has '[.failed_system[].journal | length] == [10, 3] and (.failed_user[0].journal | length) == 10'
  has '.failed_system[1].journal[1] == {time: "2026-11-16T01:00:12Z", priority: 3,
    identifier: "fwupdmgr", pid: 2081544,
    message: "Failed to download https://cdn.fwupd.org/downloads/firmware.xml.zst: Timeout was reached"}'
  has '.failed_user[0].journal[-1].message == "mpris-proxy.service: Failed with result '"'core-dump'"'."'
  run grep -c -- '^journalctl -u apport-autoreport.service -n 10 -o json ' "$FAKE_LOG"
  assert_output 1
  run grep -c -- '^journalctl --user-unit mpris-proxy.service -n 10 -o json ' "$FAKE_LOG"
  assert_output 1
}

@test "the services text view lists each unit with its journal lines and fits in 100 columns (14.1, 4.1)" {
  fakes services-failed
  run -0 "$DOMOVYK" services
  assert_line 'failed system units (2):'
  assert_line '  apport-autoreport.service  failed/failed  result exit-code  since 2026-11-16 02:00:36'
  assert_line '  fwupd-refresh.service  failed/failed  result timeout  since 2026-11-16 01:00:12'
  assert_line "    2026-11-16 01:00:12 systemd[1]: fwupd-refresh.service: Failed with result 'timeout'."
  assert_line 'failed user units (1):'
  assert_line "    2026-11-11 05:53:38 systemd[11359]: mpris-proxy.service: Failed with result 'core-dump'."
  assert_line 'next: domovyk services status <unit> [--user]'
  fits
}

@test "no failed units: both lists are empty and no journal is read (14.1)" {
  fakes services-none
  run -0 "$DOMOVYK" services --json
  check_doc services "$output"
  has '.failed_system == [] and .failed_user == [] and .unavailable == []'
  run -0 "$DOMOVYK" services
  assert_output 'failed system units: none
failed user units: none'
  run grep -c '^journalctl' "$FAKE_LOG"
  assert_output 0
}

@test "a systemctl without JSON tables is read from its plain table" {
  fakes services-plain
  run -0 "$DOMOVYK" services --json
  check_doc services "$output"
  has '[.failed_system[] | {unit, load, active, sub, description, result}] == [
    {unit: "apport-autoreport.service", load: "loaded", active: "failed", sub: "failed",
     description: "Process error reports when automatic reporting is enabled", result: "exit-code"}]'
  run grep -c '^systemctl list-units --failed --plain --no-legend --full$' "$FAKE_LOG"
  assert_output 1
}

@test "no user service manager: failed_user is null and the manager is reported (1.3, 1.4)" {
  fakes services-plain
  run -0 "$DOMOVYK" services --json
  has '.failed_user == null'
  has '.unavailable | index([{source: "systemctl --user", reason: "missing",
    hint: "no user service manager for this session"}]) != null'
  run -0 "$DOMOVYK" services
  assert_line 'failed user units: unknown (see unavailable)'
  assert_line '  systemctl --user: missing, no user service manager for this session'
}

@test "a user outside adm and systemd-journal: the system journal is reported as permission (1.3)" {
  fakes services-plain
  run -0 "$DOMOVYK" services --json
  has '.failed_system[0].journal == null'
  has '[.unavailable[] | select(.source == "system-journal")] == [{source: "system-journal",
    reason: "permission", hint: "adm or systemd-journal group"}]'
  run -0 "$DOMOVYK" services
  assert_line '    (journal not readable)'
  assert_line '  system-journal: permission, adm or systemd-journal group'
}

@test "no systemctl: both lists are null and systemctl is reported missing (1.3, 1.4)" {
  only_path
  run -0 "$DOMOVYK" services --json
  check_doc services "$output"
  has '.failed_system == null and .failed_user == null'
  has '.unavailable == [{source: "systemctl", reason: "missing", package: "systemd"}]'
}

@test "services takes no arguments" {
  fakes services-none
  run -2 --separate-stderr "$DOMOVYK" services extra
  [[ $stderr == *"unexpected argument: extra"* ]]
}

@test "services status prints state, enablement, main PID, memory, restarts and journal (14.2)" {
  fakes services-status
  run -0 "$DOMOVYK" services status cron --json
  check_doc services-status "$output"
  has '.unavailable == []'
  has '.unit | del(.journal) == {name: "cron.service", scope: "system",
    description: "Regular background program processing daemon", load: "loaded", active: "active",
    sub: "running", result: "success", enablement: "enabled", preset: "enabled", main_pid: 7749,
    memory_bytes: 10620928, restarts: 0, since: "2026-11-11T04:55:27Z",
    fragment: "/usr/lib/systemd/system/cron.service"}'
  has '(.unit.journal | length) == 20'
  has '.unit.journal[1] == {time: "2026-11-16T01:17:01Z", priority: 6, identifier: "CRON", pid: 2090327,
    message: "(root) CMD (cd / && run-parts --report /etc/cron.hourly)"}'
  run grep -c -- '^journalctl -u cron.service -n 20 -o json ' "$FAKE_LOG"
  assert_output 1
}

@test "the services status text view shows every field and fits in 100 columns (14.2, 4.1)" {
  fakes services-status
  run -0 "$DOMOVYK" services status cron
  assert_line 'cron.service (system): active (running) since 2026-11-11 04:55:27'
  assert_line '  enablement  enabled (preset enabled)'
  assert_line '  main pid    7749'
  assert_line '  memory      10.1M'
  assert_line '  restarts    0'
  assert_line 'journal (last 20):'
  assert_line '  2026-11-16 01:17:01 CRON[2090327]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)'
  fits
}

@test "services status finds a user unit in the user manager (14.2)" {
  fakes services-status
  run -0 "$DOMOVYK" services status pipewire --json
  check_doc services-status "$output"
  has '.unit.name == "pipewire.service" and .unit.scope == "user" and .unit.main_pid == 11387'
  has '.unit.memory_bytes == 7880704 and .unit.enablement == "enabled" and (.unit.journal | length) == 20'
  run grep -c -- '^journalctl --user-unit pipewire.service -n 20 ' "$FAKE_LOG"
  assert_output 1
}

@test "services status --user asks only the user manager" {
  fakes services-status
  run -0 "$DOMOVYK" services status pipewire --user --json
  has '.unit.scope == "user"'
  run grep -c '^systemctl show ' "$FAKE_LOG"
  assert_output 0
}

@test "services status of a failed unit without a main process or memory count (14.2)" {
  fakes services-status
  run -0 "$DOMOVYK" services status apport-autoreport --json
  check_doc services-status "$output"
  has '.unit.active == "failed" and .unit.result == "exit-code" and .unit.enablement == "static"'
  has '.unit.main_pid == null and .unit.memory_bytes == null and .unit.restarts == 0'
  run -0 "$DOMOVYK" services status apport-autoreport
  assert_line '  main pid    none'
  assert_line '  memory      not counted'
}

@test "services status of an unknown unit exits 2 and says so (14.2)" {
  fakes services-status
  run -2 --separate-stderr "$DOMOVYK" services status nosuch
  assert_output ''
  assert_equal "$stderr" 'domovyk services status: no unit nosuch in the system or user manager; see domovyk services'
  run -2 --separate-stderr "$DOMOVYK" services status nosuch --user --json
  assert_output ''
  assert_equal "$stderr" 'domovyk services status: no unit nosuch in the user manager; see domovyk services'
}

@test "services status without one valid unit name exits 2" {
  fakes services-status
  run -2 --separate-stderr "$DOMOVYK" services status
  [[ $stderr == *"which unit?"* ]]
  run -2 --separate-stderr "$DOMOVYK" services status cron ssh
  [[ $stderr == *"give one unit"* ]]
  run -2 --separate-stderr "$DOMOVYK" services status ../etc/passwd
  [[ $stderr == *"not a unit name"* ]]
  run -2 --separate-stderr "$DOMOVYK" services status --bogus cron
  [[ $stderr == *"unknown option: --bogus"* ]]
  run grep -c '^systemctl' "$FAKE_LOG"
  assert_output 0
}

@test "services status with an unreadable system journal reports permission (1.3)" {
  fakes services-status
  export FAKE_CASE_JOURNALCTL=services-plain
  run -0 "$DOMOVYK" services status cron --json
  has '.unit.journal == null and .unit.active == "active"'
  has '.unavailable == [{source: "system-journal", reason: "permission", hint: "adm or systemd-journal group"}]'
  run -0 "$DOMOVYK" services status cron
  assert_line 'journal: not readable'
}

@test "services status without systemctl: unit is null, reported missing, exit 0 (1.3, 1.4)" {
  only_path
  run -0 "$DOMOVYK" services status cron --json
  check_doc services-status "$output"
  has '.unit == null'
  has '.unavailable == [{source: "systemctl", reason: "missing", package: "systemd"}]'
  run -0 "$DOMOVYK" services status cron
  assert_line 'unit status unknown'
}
