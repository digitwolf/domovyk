#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Runs the Python stdlib unit and property tests under test/unit/py.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
}

@test "python unit and property tests pass" {
  run python3 -I -m unittest discover -s "$REPO/test/unit/py" -p 'test_*.py'
  assert_success
}
