#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Guard_Hook against the corpus, plus its input and output contract
# (requirements 18.1-18.5). Properties are in py/test_guard.py.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
  GUARD="$REPO/libexec/hooks/guard"
  export DOMOVYK_LIBEXEC="$REPO/libexec"
}

decide() {
  jq -cn --arg c "$1" --arg a "${2:--}" \
    '{tool_name: "Bash", tool_input: {command: $c}} + (if $a != "-" then {agent_type: $a} else {} end)' |
    "$GUARD"
}

@test "every corpus line gets the expected decision (18.1-18.4)" {
  local expect agent cmd out got fails=0 n=0
  while IFS=$'\t' read -r expect agent cmd; do
    [[ -z $expect || $expect == \#* ]] && continue
    cmd=${cmd//\\n/$'\n'}
    out=$(decide "$cmd" "$agent")
    got=allow
    [[ $out == *'"permissionDecision": "deny"'* ]] && got=deny
    if [[ $got != "$expect" ]]; then
      printf 'expected %s, got %s: [%s] %s\n' "$expect" "$got" "$agent" "$cmd" >&2
      fails=$((fails + 1))
    fi
    n=$((n + 1))
  done <"$REPO/test/unit/fixtures/guard-corpus.tsv"
  ((n >= 150)) || fail "corpus has only $n lines"
  ((fails == 0))
}

@test "a privileged command is denied with a reason that names domovyk handoff (18.1)" {
  run -0 decide 'sudo apt update'
  run jq -r '.hookSpecificOutput | "\(.hookEventName) \(.permissionDecision)"' <<<"$output"
  assert_output 'PreToolUse deny'
  run -0 decide 'sudo apt update'
  run jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"
  assert_output --partial 'domovyk handoff create'
}

@test "a destructive command is denied naming the rule (18.2)" {
  run -0 decide 'rm -rf ~'
  run jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"
  assert_output --partial 'rm-root-or-home'
}

@test "an ordinary command produces no output at all (18.3)" {
  run -0 decide 'ls -la /etc'
  assert_output ''
}

@test "unparsable input is denied (18.5)" {
  local input
  for input in '{bad json' '[]' '{"tool_input": {}}' '{"tool_input": {"command": 7}}'; do
    run -0 "$GUARD" <<<"$input"
    run jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"
    assert_output 'domovyk guard could not parse the command'
  done
  run -0 decide "echo 'unterminated"
  run jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output"
  assert_output 'domovyk guard could not parse the command'
}

@test "the investigator may run read routes but nothing else (18.4)" {
  run -0 decide 'domovyk commands --json | jq .commands' 'domovyk:domovyk-investigator'
  assert_output ''
  run -0 decide 'domovyk handoff create --title x' 'domovyk:domovyk-investigator'
  assert_output --partial 'the investigator only runs domovyk read commands'
}
