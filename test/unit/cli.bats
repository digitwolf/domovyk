#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # fake command bodies are single-quoted on purpose
# shellcheck disable=SC2030,SC2031 # each test sets its own environment
# Dispatcher: routes, default actions, help, unknown routes, release check,
# exit codes (requirements 1.5, 2.1-2.4, 2.6, 4.4).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
}

present_routes() {
  local f n
  for f in "$REPO"/libexec/commands/domovyk-*; do
    n=${f##*/}
    n=${n#domovyk-}
    printf '%s\n' "${n//-/ }"
  done
}

@test "no arguments prints usage and exits 2" {
  run -2 "$DOMOVYK"
  assert_output --partial 'usage: domovyk'
}

@test "--help prints usage and exits 0" {
  run -0 "$DOMOVYK" --help
  assert_output --partial 'domovyk commands'
}

@test "--version runs the version command" {
  run -0 "$DOMOVYK" --version
  assert_output --regexp '^domovyk [0-9]'
}

@test "commands lists every Command with route, tier and summary (2.1)" {
  run -0 "$DOMOVYK" commands
  assert_line --regexp '^commands +read +List every domovyk command'
  assert_line --regexp '^version +read +'
}

@test "commands --json lists exactly the Commands present (2.2, 2.4)" {
  run -0 "$DOMOVYK" commands --json
  local listed present
  listed=$(jq -r '.commands[].route' <<<"$output" | sort)
  present=$(present_routes | sort)
  assert_equal "$listed" "$present"
  run jq -e '.commands | all(has("route") and has("tier") and has("summary") and has("args") and has("examples"))' <<<"$output"
  assert_success
}

@test "group --help and command --help print metadata without running it (2.3)" {
  fake_tree
  fake_command thing-run read 'touch "$HOME/ran"; echo did'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" thing run --help
  assert_output --partial 'summary:  Fake thing-run'
  assert_output --partial 'tier:     read'
  [[ ! -e $HOME/ran ]]
  run -0 "$DOMOVYK_ROOT/bin/domovyk" thing --help
  assert_output --partial 'domovyk thing run'
  [[ ! -e $HOME/ran ]]
}

@test "a two-word route wins over a one-word route" {
  fake_tree
  fake_command disk read 'echo one-word "$@"'
  fake_command disk-usage read 'echo two-word "$@"'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" disk usage /x
  assert_output 'two-word /x'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" disk --json
  assert_output 'one-word --json'
}

@test "crash and handoff default to their list action" {
  fake_tree
  fake_command crash-list read 'echo crash-list "$@"'
  fake_command handoff-list read 'echo handoff-list'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" crash
  assert_output 'crash-list '
  run -0 "$DOMOVYK_ROOT/bin/domovyk" handoff
  assert_output 'handoff-list'
}

@test "the route is passed to the Command" {
  fake_tree
  fake_command svc-status read 'echo "$DOMOVYK_ROUTE"'
  run -0 "$DOMOVYK_ROOT/bin/domovyk" svc status
  assert_output 'svc status'
}

@test "an unknown route exits 2 and suggests the closest routes (2.6)" {
  run -2 "$DOMOVYK" comands
  assert_output --partial 'unknown command: comands'
  assert_output --partial 'domovyk commands'
}

@test "an unsupported release prints one warning and continues (1.5)" {
  export DOMOVYK_OS_RELEASE="$REPO/test/unit/fixtures/os-release/trixie"
  run -0 --separate-stderr "$DOMOVYK" version
  assert_output --regexp '^domovyk '
  [[ $(grep -c 'not a supported release' <<<"$stderr") == 1 ]]
  [[ $stderr == *trixie* ]]
}

@test "supported releases print no warning (1.5)" {
  local r
  for r in resolute noble; do
    export DOMOVYK_OS_RELEASE="$REPO/test/unit/fixtures/os-release/$r"
    run -0 --separate-stderr "$DOMOVYK" version
    assert_equal "$stderr" ""
  done
}

@test "a usage error inside a Command exits 2 (4.4)" {
  run -2 "$DOMOVYK" version extra
  assert_output --partial 'unexpected argument: extra'
}

@test "the dispatcher finds an installed layout under DOMOVYK_ROOT" {
  local root="$BATS_TEST_TMPDIR/usr"
  mkdir -p "$root/bin" "$root/libexec/domovyk" "$root/share/domovyk"
  cp "$REPO/bin/domovyk" "$root/bin/"
  cp -r "$REPO/libexec/." "$root/libexec/domovyk/"
  cp -r "$REPO/share/." "$root/share/domovyk/"
  DOMOVYK_ROOT="$root" run -0 "$root/bin/domovyk" version --json
  run jq -r .root <<<"$output"
  assert_output "$root"
}
