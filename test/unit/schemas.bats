#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2086 # a route is split into its words on purpose
# Every Read_Command's JSON carries the Envelope and exactly the top-level
# keys documented for its schema (requirements 4.2, 4.3, 4.6). Commands that
# need arguments or fixtures are checked again in their own test files with
# check_schema.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
}

@test "every documented schema has a key list" {
  run -0 grep -vc '^#' "$REPO/test/unit/schemas/keys.tsv"
}

@test "argument-free Read_Commands match the Envelope and their key list (4.6)" {
  local f route doc schema want got
  for f in "$REPO"/libexec/commands/domovyk-*; do
    [[ $(sed -n '1,15s/^# domovyk:tier=//p' "$f") == read ]] || continue
    grep -q '^# domovyk:needs-args=yes' "$f" && continue
    route=${f##*/domovyk-}
    doc=$("$DOMOVYK" ${route//-/ } --json)
    jq -e -f "$REPO/test/unit/schemas/envelope.jq" <<<"$doc" >/dev/null ||
      fail "$route: Envelope check failed"
    schema=$(jq -r .schema <<<"$doc")
    want=$(awk -F'\t' -v s="$schema" '$1 == s { print $2 }' "$REPO/test/unit/schemas/keys.tsv" | tr ' ' '\n' | sort)
    [[ -n $want ]] || fail "$route: schema $schema has no key list"
    got=$(jq -r 'keys[] | select(IN("schema","generated","host","unavailable") | not)' <<<"$doc" | sort)
    assert_equal "$got" "$want"
  done
}
