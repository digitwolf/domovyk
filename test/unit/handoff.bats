#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # grep patterns are single-quoted on purpose
# Handoff scripts: create, list, show (requirements 15.1-15.7).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
  HD="$HOME/.local/state/domovyk/handoff"
}

@test "create writes a 0600 script with the header and the body unchanged (15.1, 15.2)" {
  local body=$'apt-get install -y intel-ipu6-dkms\necho "done: $HOME"\n'
  run -0 "$DOMOVYK" handoff create --title "Install the IPU6 camera driver" <<<"$body"
  local file=${lines[0]}
  [[ $file == "$HD"/*-install-the-ipu6-camera-driver.sh ]]
  [[ ${file##*/} =~ ^[0-9]{8}T[0-9]{6}Z- ]]
  assert_equal "$(stat -c %a "$file")" 600
  assert_equal "$(sed -n 1p "$file")" '#!/bin/bash'
  assert_equal "$(sed -n 2p "$file")" 'set -euo pipefail'
  assert_equal "$(sed -n 3p "$file")" '# domovyk handoff: Install the IPU6 camera driver'
  local created_re='^# created: [0-9T:-]+Z by [^ ]+ on resolute$'
  [[ $(sed -n 4p "$file") =~ $created_re ]]
  assert_equal "$(sed -n 6p "$file")" '# --- body ---'
  assert_equal "$(tail -n +7 "$file")" "$(printf '%s' "$body")"
}

@test "create prints the path and the line to run it (15.3)" {
  run -0 "$DOMOVYK" handoff create --title "x" <<<'echo hi'
  assert_equal "${lines[1]}" "! sudo bash ${lines[0]}"
}

@test "create never runs the script (15.4)" {
  run -0 "$DOMOVYK" handoff create --title "touch" <<<"touch '$HOME/ran'"
  [[ ! -e $HOME/ran ]]
  # No code path executes or sources the written file.
  run grep -nE 'bash +"?\$file|source +"?\$file|^\s*\. +"?\$file|exec +"?\$file' \
    "$REPO/libexec/commands/domovyk-handoff-create"
  assert_failure
}

@test "list shows scripts newest first with title and time (15.5)" {
  "$DOMOVYK" handoff create --title "first" <<<'echo 1' >/dev/null
  sleep 1.1
  "$DOMOVYK" handoff create --title "second" <<<'echo 2' >/dev/null
  run -0 "$DOMOVYK" handoff list --json
  run jq -r '.scripts | map(.title) | join(",")' <<<"$output"
  assert_output 'second,first'
  run -0 "$DOMOVYK" handoff
  assert_line --index 0 --partial 'second'
}

@test "empty, oversized and unparsable scripts are refused and nothing is written (15.6)" {
  run -2 "$DOMOVYK" handoff create --title "empty" </dev/null
  run -2 "$DOMOVYK" handoff create --title "blank" <<<$'  \n\t\n'
  run -2 "$DOMOVYK" handoff create --title "big" < <(head -c 65537 /dev/zero | tr '\0' '#')
  run -2 "$DOMOVYK" handoff create --title "broken" <<<'if then fi ('
  assert_output --partial 'does not parse'
  [[ ! -d $HD ]] || [[ -z $(ls -A "$HD") ]]
}

@test "exactly 64 KiB is accepted" {
  run -0 "$DOMOVYK" handoff create --title "edge" < <(head -c 65536 /dev/zero | tr '\0' '#')
}

@test "a title is required" {
  run -2 "$DOMOVYK" handoff create <<<'echo hi'
  assert_output --partial '--title is required'
}

@test "handoff create is in the user tier (15.7)" {
  run -0 "$DOMOVYK" commands --json
  run jq -r '.commands[] | select(.route == "handoff create") | .tier' <<<"$output"
  assert_output 'user'
}

@test "show prints one script; an unknown name exits 2" {
  run -0 "$DOMOVYK" handoff create --title "shown" <<<'echo shown-body'
  local name=${lines[0]##*/}
  run -0 "$DOMOVYK" handoff show "$name"
  assert_output --partial 'echo shown-body'
  assert_output --partial 'sudo bash'
  run -2 "$DOMOVYK" handoff show nope.sh
  assert_output --partial 'domovyk handoff list'
}

@test "list JSON matches the Envelope and its key list" {
  run -0 "$DOMOVYK" handoff list --json
  jq -e -f "$REPO/test/unit/schemas/envelope.jq" <<<"$output" >/dev/null
  run jq -r 'keys - ["schema","generated","host","unavailable"] | join(" ")' <<<"$output"
  assert_output 'scripts'
}
