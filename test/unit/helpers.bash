# shellcheck shell=bash disable=SC2034 # variables are used by the test files
# Common setup for Domovyk unit tests: the working tree as DOMOVYK_ROOT, a
# fixed os-release, and a per-test stub folder at the front of PATH.

dv_setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  DOMOVYK="$REPO/bin/domovyk"
  export DOMOVYK_ROOT="$REPO"
  export DOMOVYK_OS_RELEASE="$REPO/test/unit/fixtures/os-release/resolute"
  export DOMOVYK_CACHE="$BATS_TEST_TMPDIR/cache"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export PATH="$STUBS:$PATH"
  unset DOMOVYK_FORMAT DOMOVYK_RAW DOMOVYK_TIMEOUT DOMOVYK_ROUTE
}

# stub <name> <script body>: an executable on PATH for this test only.
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

# A Command tree in a temporary root, for dispatcher tests that need
# commands the real tree does not have.
fake_tree() {
  FAKE_ROOT="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$FAKE_ROOT/bin" "$FAKE_ROOT/libexec/commands" "$FAKE_ROOT/share"
  cp "$REPO/bin/domovyk" "$FAKE_ROOT/bin/"
  cp -r "$REPO/libexec/lib" "$REPO/libexec/render" "$REPO/libexec/py" "$FAKE_ROOT/libexec/"
  cp "$REPO/share/redact.tsv" "$FAKE_ROOT/share/"
  export DOMOVYK_ROOT="$FAKE_ROOT"
}

# fake_command <route-with-dashes> <tier> <body>
fake_command() {
  local f="$FAKE_ROOT/libexec/commands/domovyk-$1"
  printf '#!/bin/bash\n# domovyk:summary=Fake %s\n# domovyk:tier=%s\n# domovyk:args=[x]\n%s\n' \
    "$1" "$2" "$3" >"$f"
  chmod +x "$f"
}
