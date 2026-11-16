#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # stub bodies and jq programs are single-quoted on purpose
# shellcheck disable=SC2030,SC2031 # each test sets its own environment
# domovyk logs: grouped errors, the previous boot, OOM kills, kernel events,
# suspend failures, journal size, user-only access and --unit (requirements
# 11.1-11.5, with 1.3, 1.4, 4.1-4.4 and 4.6). journalctl is a Fake_Bin
# replaying test/unit/fixtures/journalctl/logs-<case>/, all synthetic.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
  use_fakes journalctl
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls"
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

@test "errors are grouped by unit, identifier and priority with count, first and last (11.1)" {
  export FAKE_CASE=logs-grouped
  run -0 --separate-stderr "$DOMOVYK" logs --json
  check_doc logs
  # Most severe first, then the largest groups.
  jqo '.groups[0] | .identifier == "systemd-coredump" and .priority == 2 and .count == 1'
  jqo '.groups | map(.priority) == (map(.priority) | sort)'
  jqo '.groups[] | select(.unit == "bluetooth.service")
    | .identifier == "bluetoothd" and .user == false and .count == 5
      and .first == "2026-11-09T07:31:10Z" and .last == "2026-11-15T19:58:24Z"
      and (.message | startswith("src/profile.c:record_cb()"))'
  jqo '.groups[] | select(.unit == "obex.service")
    | .user == true and .count == 5 and .message == "Transport got disconnected"'
  jqo '[.groups[] | select(.unit == "init.scope") | [.user, .count]] | sort == [[false, 2], [true, 1]]'
  jqo '.groups[] | select(.identifier == "kernel") | .unit == null and .count == 3'
  jqo '[.groups[].count] | add == 19'
}

@test "a MESSAGE stored as bytes is decoded and stripped of colour codes (11.1)" {
  export FAKE_CASE=logs-grouped
  run -0 --separate-stderr "$DOMOVYK" logs --json
  jqo '.groups[] | select(.identifier == "example-tool") | .message == "ERROR: café sync failed"'
}

@test "the text view lists each group with its count and times, within 100 columns (11.1, 4.1)" {
  export FAKE_CASE=logs-grouped
  run -0 --separate-stderr "$DOMOVYK" logs
  assert_fits
  assert_line 'boot 0 (current): 2026-11-09 07:30 to 2026-11-15 20:00 UTC'
  assert_line --regexp '^ +5 err +bluetooth\.service / bluetoothd +11-09 07:31:10  11-15 19:58:24$'
  assert_line --regexp '^ +5 err +obex\.service \(user\) / obexd '
  assert_line 'errors: 19 entries in 8 groups of priority err or worse (times UTC)'
  assert_line '           ERROR: café sync failed'
}

@test "the current boot is resolved from the boot list and has no shutdown verdict (11.1)" {
  export FAKE_CASE=logs-grouped
  run -0 --separate-stderr "$DOMOVYK" logs --json
  jqo '.boot == {offset: 0, id: "00000000000000000000000000000b00", first: "2026-11-09T07:30:00Z",
    last: "2026-11-15T20:00:00Z", current: true, clean_shutdown: null, ended_in_suspend: null}'
  # The current boot needs no look at how it ended.
  run grep -c -- '-n 100' "$FAKE_LOG"
  assert_output 0
}

@test "--boot -1 reports the previous boot and that it never shut down cleanly (11.2)" {
  export FAKE_CASE=logs-prev
  run -0 --separate-stderr "$DOMOVYK" logs --boot -1 --json
  check_doc logs
  jqo '.boot | .offset == -1 and .current == false and .clean_shutdown == false
    and .ended_in_suspend == true and .first == "2026-11-04T08:00:00Z"'
  jqo '[.groups[] | {identifier, count}]
    == [{identifier: "kernel", count: 2}, {identifier: "systemd", count: 1}]'
  jqo '.suspend | .cycles == 3 and .resumes == 2'
  # Every journal query of the boot asked for boot -1.
  run grep -c -- '^journalctl -b -1 ' "$FAKE_LOG"
  assert_output 3
  run -0 --separate-stderr "$DOMOVYK" logs --boot -1
  assert_fits
  assert_line 'boot -1: 2026-11-04 08:00 to 2026-11-08 23:10 UTC, no clean shutdown (never woke from suspend)'
}

@test "an earlier boot that ended with a shutdown is clean (11.2)" {
  export FAKE_CASE=logs-prev
  run -0 --separate-stderr "$DOMOVYK" logs --boot=-2 --json
  check_doc logs
  jqo '.boot | .offset == -2 and .clean_shutdown == true and .ended_in_suspend == false'
  run -0 --separate-stderr "$DOMOVYK" logs --boot -2
  assert_line 'boot -2: 2026-11-01 08:00 to 2026-11-03 18:00 UTC, ended with a clean shutdown'
}

@test "OOM kills come from the kernel and from systemd-oomd (11.4)" {
  export FAKE_CASE=logs-oom
  run -0 --separate-stderr "$DOMOVYK" logs --json
  check_doc logs
  jqo '[.oom_kills[] | [.source, .process, .pid]]
    == [["kernel", "example-app", 4242], ["kernel", "cc1plus", 5151],
        ["systemd-oomd", "app-gnome-example-5555.scope", null]]'
  jqo '.oom_kills[0].time == "2026-11-12T10:01:02Z"'
  run -0 --separate-stderr "$DOMOVYK" logs
  assert_fits
  assert_line 'OOM kills: 3'
  assert_line '  11-12 10:01:02 kernel        example-app (pid 4242)'
}

@test "kernel warnings and oopses are events, with their trace lines folded in (11.4)" {
  export FAKE_CASE=logs-oops
  run -0 --separate-stderr "$DOMOVYK" logs --json
  check_doc logs
  # The WARNING's trace and the BUG's Oops and trace belong to their event; a
  # trace 11 minutes later stands alone; a user-space fault (info) is no event.
  jqo '.kernel.count == 4 and ([.kernel.events[].kind] == ["warning", "bug", "call-trace", "hung-task"])'
  jqo '.kernel.events[0] | .time == "2026-11-10T09:00:00Z" and (.message | startswith("WARNING: CPU: 3 PID: 812"))'
  run -0 --separate-stderr "$DOMOVYK" logs
  assert_fits
  assert_line 'kernel warnings and oopses: 4'
  assert_line --regexp '^  11-11 14:20:05 bug +BUG: kernel NULL pointer dereference'
}

@test "failed suspend and resume cycles are counted with their messages (11.4)" {
  export FAKE_CASE=logs-suspend
  run -0 --separate-stderr "$DOMOVYK" logs --json
  check_doc logs
  jqo '.suspend | .cycles == 3 and .resumes == 3 and .failed == 2 and (.failures | length) == 4'
  jqo '[.suspend.failures[].source] == ["kernel", "systemd-sleep", "kernel", "kernel"]'
  jqo 'any(.suspend.failures[]; .message | startswith("PM: Some devices failed to suspend"))'
  # A power-management warning that is not a failure is left out.
  jqo 'all(.suspend.failures[]; .message | contains("should not be sleeping") | not)'
  run -0 --separate-stderr "$DOMOVYK" logs
  assert_fits
  assert_line 'suspend: 3 cycles, 3 resumes, 2 failed'
}

@test "journal disk usage is reported in bytes (11.4)" {
  export FAKE_CASE=logs-grouped
  run -0 --separate-stderr "$DOMOVYK" logs --json
  jqo '.journal == {disk_usage_bytes: 1288490188, boots: 3}'
  export FAKE_CASE=logs-user-only
  run -0 --separate-stderr "$DOMOVYK" logs --json
  jqo '.journal.disk_usage_bytes == 25165824'
}

@test "user-only journal access reports the system journal as permission with the groups (11.5)" {
  export FAKE_CASE=logs-user-only
  run -0 --separate-stderr "$DOMOVYK" logs --json
  check_doc logs
  jqo '.unavailable == [{source: "system-journal", reason: "permission", hint: "adm or systemd-journal group"}]'
  # What the user's own journal holds is still reported (1.4).
  jqo '[.groups[] | .unit] == ["obex.service"]'
  run -0 --separate-stderr "$DOMOVYK" logs
  assert_fits
  assert_line '  system-journal: permission, adm or systemd-journal group'
}

@test "--unit prints the unit's entries, newest last, as domovyk.logs-unit.v1 (11.3)" {
  export FAKE_CASE=logs-unit
  run -0 --separate-stderr "$DOMOVYK" logs --unit ssh.service --json
  check_doc logs-unit
  jqo '.unit == {name: "ssh.service", scope: "system", boot: null, limit: 200} and (.entries | length) == 10'
  jqo '.entries[0] == {time: "2026-11-15T08:00:00Z", priority: 6, identifier: "systemd", pid: 1,
    message: "Starting ssh.service - OpenBSD Secure Shell server..."}'
  jqo '.entries[-1].message == "pam_unix(sshd:session): session closed for user tester"'
  run grep -c -- '^journalctl -u ssh.service -n 200 ' "$FAKE_LOG"
  assert_output 1
  run -0 --separate-stderr "$DOMOVYK" logs --unit ssh.service
  assert_fits
  assert_line 'ssh.service (system unit): 10 entries, newest last (times UTC)'
  assert_line '2026-11-15 10:00:00 err     sshd[2302]: error: kex_exchange_identification: Connection closed by re…'
}

@test "--unit falls back to the user unit when the system has none (11.3)" {
  export FAKE_CASE=logs-unit
  run -0 --separate-stderr "$DOMOVYK" logs --unit=obex.service --json
  check_doc logs-unit
  jqo '.unit.scope == "user" and ([.entries[].message] == ["Transport got disconnected", "OBEX daemon 5.85"])'
}

@test "--unit keeps at most 200 entries, the newest, in time order (11.3)" {
  rm -f "$STUBS/journalctl" # a stub, not the Fake_Bin symlink, which it would overwrite
  stub journalctl 'if [[ $1 == --list-boots ]]; then echo "[]"; exit 0; fi
echo "$*" >>"$HOME/args"
for i in $(seq 250 -1 1); do
  printf "{\"__REALTIME_TIMESTAMP\":\"%d\",\"PRIORITY\":\"6\",\"SYSLOG_IDENTIFIER\":\"demo\",\"_PID\":\"42\",\"MESSAGE\":\"line %d\"}\n" \
    $((1794700000000000 + i * 1000000)) "$i"
done'
  run -0 --separate-stderr "$DOMOVYK" logs --unit demo.service --json
  check_doc logs-unit
  jqo '(.entries | length) == 200 and .entries[0].message == "line 51" and .entries[-1].message == "line 250"'
  run grep -c -- '-n 200' "$HOME/args"
  assert_output 1
}

@test "--unit with user-only access reports the system journal as permission (11.3, 11.5)" {
  export FAKE_CASE=logs-user-only
  run -0 --separate-stderr "$DOMOVYK" logs --unit ssh.service --json
  check_doc logs-unit
  jqo '.entries == [] and .unit.scope == null and .unavailable[0].source == "system-journal"'
  run -0 --separate-stderr "$DOMOVYK" logs --unit ssh.service
  assert_line 'no journal entries for ssh.service'
}

@test "bad --boot or --unit values are usage errors (4.4)" {
  export FAKE_CASE=logs-grouped
  local bad
  for bad in x 1.5 -1x 1234567 +1; do
    run -2 "$DOMOVYK" logs --boot "$bad"
    assert_output --partial '--boot takes a boot offset'
  done
  run -2 "$DOMOVYK" logs --boot
  assert_output --partial '--boot needs a value'
  run -2 "$DOMOVYK" logs --boot -99
  assert_output --partial 'no boot -99 in the journal, which holds boots -2 to 0'
  run -2 "$DOMOVYK" logs --unit -x
  assert_output --partial '--unit takes a unit name'
  run -2 "$DOMOVYK" logs --unit 'a b.service'
  run -2 "$DOMOVYK" logs --unit
  run -2 "$DOMOVYK" logs extra
  assert_output --partial 'unexpected argument: extra'
}

@test "without journalctl every journal fact is unknown and the Command exits 0 (1.3, 1.4)" {
  rm -f "$STUBS/journalctl"
  only_path
  run -0 --separate-stderr "$DOMOVYK" logs --json
  check_doc logs
  jqo '.unavailable == [{source: "journalctl", reason: "missing", package: "systemd"}]
    and .groups == null and .oom_kills == null and .kernel == null and .suspend == null'
  run -0 --separate-stderr "$DOMOVYK" logs
  assert_line 'errors: unknown'
  assert_line '  journalctl: missing (apt install systemd)'
}

@test "every case renders within 100 columns (4.1)" {
  local c
  for c in grouped oom oops suspend user-only; do
    export FAKE_CASE=logs-$c
    run -0 --separate-stderr "$DOMOVYK" logs
    assert_fits
  done
  export FAKE_CASE=logs-prev
  run -0 --separate-stderr "$DOMOVYK" logs --boot -1
  assert_fits
  export FAKE_CASE=logs-unit
  run -0 --separate-stderr "$DOMOVYK" logs --unit obex.service
  assert_fits
}
