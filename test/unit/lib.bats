#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # bash -c scripts are single-quoted on purpose
# libexec/lib/domovyk.sh: Sources, timeouts, Unavailable_Sources, the
# Envelope, exit codes and temporary directories (requirements 1.2-1.4, 3.3,
# 4.2, 4.3, 4.5, 10.5).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
  fake_tree
}

# A Command whose body is $1, run through the dispatcher.
run_body() {
  fake_command probe read "source \"\$DOMOVYK_LIBEXEC/lib/domovyk.sh\"
dv_init domovyk.probe.v1 \"\" \"\$@\"
$1"
  printf 'include "lib"; .note // "none", unavailable_lines\n' >"$FAKE_ROOT/libexec/render/probe.jq"
  run "${@:2}" "$DOMOVYK_ROOT/bin/domovyk" probe
}

@test "a missing Source is recorded with its package and the Command exits 0 (1.3, 1.4)" {
  run_body 'dv_have no-such-tool some-package || true
echo "{\"note\":\"still here\"}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"' -0
  assert_line 'still here'
  assert_line '  no-such-tool: missing (apt install some-package)'
}

@test "the JSON Envelope has schema, generated, host and unavailable (4.2, 4.3)" {
  fake_command probe read 'source "$DOMOVYK_LIBEXEC/lib/domovyk.sh"
dv_init domovyk.probe.v1 "" "$@"
dv_have no-such-tool pkg || true
echo "{\"x\":1}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" probe --json
  run jq -e '.schema == "domovyk.probe.v1"
    and (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    and .host.codename == "resolute" and .host.release == "26.04.1"
    and (.host | has("kernel"))
    and .unavailable == [{"source":"no-such-tool","reason":"missing","package":"pkg"}]
    and .x == 1' <<<"$output"
  assert_success
}

@test "the Envelope carries no hostname or machine id" {
  fake_command probe read 'source "$DOMOVYK_LIBEXEC/lib/domovyk.sh"
dv_init domovyk.probe.v1 "" "$@"
echo "{}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" probe --json
  refute_output --partial "$(hostname)"
  [[ -r /etc/machine-id ]] && refute_output --partial "$(cat /etc/machine-id)"
  true
}

@test "a Source that runs longer than the timeout is recorded as timeout (3.3)" {
  stub slowtool 'sleep 15'
  SECONDS=0
  run_body 'dv_source slow -- slowtool || true
echo "{}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"' -0 env DOMOVYK_TIMEOUT=1
  assert_line '  slow: timeout'
  ((SECONDS < 6))
}

@test "a refused Source is recorded as permission" {
  stub locked 'echo "locked: Permission denied" >&2; exit 1'
  run_body 'dv_source locked-src -- locked || true
echo "{}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"' -0
  assert_line '  locked-src: permission'
}

@test "a Source with a nonzero exit is left to the caller" {
  stub falsy 'echo partial; exit 3'
  run_body 'dv_source f -- falsy
echo "{\"note\":\"rc=$DV_RC out=$(cat "$DV_OUT")\"}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"' -0
  assert_line 'rc=3 out=partial'
}

@test "an internal failure exits 1 naming the Command and the step (4.5)" {
  run_body 'dv_die parse "bad input"' -1 --separate-stderr
  assert_equal "$stderr" 'domovyk probe: parse: bad input'
}

@test "a body that is not JSON is an internal failure" {
  run_body 'echo "{not json" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"' -1
  assert_output --partial 'domovyk probe: emit: body is not valid JSON'
}

@test "temporary directories are removed on exit and on SIGTERM (10.5)" {
  fake_command keep read 'source "$DOMOVYK_LIBEXEC/lib/domovyk.sh"
dv_init domovyk.keep.v1 "" "$@"
d=$(dv_mktemp_dir); echo "$d" >"$HOME/dir"; stat -c %a "$d" >"$HOME/mode"
[[ ${1:-} == wait ]] && sleep 30
exit 0'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" keep
  [[ ! -e $(cat "$HOME/dir") ]]
  assert_equal "$(cat "$HOME/mode")" 700
  rm -f "$HOME/dir"
  "$DOMOVYK_ROOT/bin/domovyk" keep wait &
  local pid=$!
  for _ in $(seq 50); do
    [[ -s $HOME/dir ]] && break
    sleep 0.1
  done
  [[ -d $(cat "$HOME/dir") ]]
  kill -TERM "$pid"
  wait "$pid" || true
  [[ ! -e $(cat "$HOME/dir") ]]
}

@test "--raw skips redaction and says so on stderr (5.4)" {
  fake_command probe read 'source "$DOMOVYK_LIBEXEC/lib/domovyk.sh"
dv_init domovyk.probe.v1 "" "$@"
echo "{\"note\":\"password=hunter2\"}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b"'
  printf 'include "lib"; .note\n' >"$FAKE_ROOT/libexec/render/probe.jq"
  run -0 --separate-stderr "$DOMOVYK_ROOT/bin/domovyk" probe
  assert_output 'password=[redacted:assignment]'
  run -0 --separate-stderr "$DOMOVYK_ROOT/bin/domovyk" probe --raw
  assert_output 'password=hunter2'
  assert_equal "$(head -n 1 <<<"$stderr")" 'unredacted output'
}

@test "the Facts_Cache stores redacted JSON with mode 0600 and expires after 60 s" {
  printf '.note\n' >"$FAKE_ROOT/libexec/render/probe.jq"
  fake_command probe read 'source "$DOMOVYK_LIBEXEC/lib/domovyk.sh"
dv_init domovyk.probe.v1 "" "$@"
DV_CACHE_ROUTE=probe
echo "{\"note\":\"token=abc12345\"}" >"$DV_TMP/b"; dv_emit "$DV_TMP/b" >/dev/null
f=$(dv_cache_get probe) && echo "hit $f"
touch -d "2 minutes ago" "$f"
dv_cache_get probe || echo miss'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" probe
  assert_line --regexp '^hit '
  assert_line 'miss'
  local f="$DOMOVYK_CACHE/facts/probe.json"
  assert_equal "$(stat -c %a "$f")" 600
  run jq -r .note "$f"
  assert_output 'token=[redacted:assignment]'
}
