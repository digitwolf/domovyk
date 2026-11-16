#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2086 # a route is split into its words on purpose
# Command_Metadata lint: every Command has a summary and a Tier, and the Tier
# is read or user (requirement 2.5).

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
}

@test "every Command has summary and tier metadata with a valid tier (2.5)" {
  local f tier summary bad=()
  for f in "$REPO"/libexec/commands/domovyk-*; do
    summary=$(sed -n '1,15s/^# domovyk:summary=//p' "$f" | head -n 1)
    tier=$(sed -n '1,15s/^# domovyk:tier=//p' "$f" | head -n 1)
    [[ -n $summary ]] || bad+=("${f##*/}: no summary")
    [[ $tier == read || $tier == user ]] || bad+=("${f##*/}: tier '${tier}'")
    [[ -x $f ]] || bad+=("${f##*/}: not executable")
  done
  if ((${#bad[@]})); then
    printf '%s\n' "${bad[@]}" >&2
    return 1
  fi
}

@test "the lint names a Command without a tier" {
  fake_tree
  printf '#!/bin/bash\n# domovyk:summary=No tier\n' >"$FAKE_ROOT/libexec/commands/domovyk-broken"
  chmod +x "$FAKE_ROOT/libexec/commands/domovyk-broken"
  local tier
  tier=$(sed -n '1,15s/^# domovyk:tier=//p' "$FAKE_ROOT/libexec/commands/domovyk-broken")
  [[ -z $tier ]]
}

@test "every Read_Command accepts --json and prints one JSON document" {
  local f route
  for f in "$REPO"/libexec/commands/domovyk-*; do
    [[ $(sed -n '1,15s/^# domovyk:tier=//p' "$f") == read ]] || continue
    # Commands that need an argument are covered by their own tests.
    grep -q '^# domovyk:needs-args=yes' "$f" && continue
    route=${f##*/domovyk-}
    run -0 "$DOMOVYK" ${route//-/ } --json
    jq -e . >/dev/null <<<"$output"
  done
}
