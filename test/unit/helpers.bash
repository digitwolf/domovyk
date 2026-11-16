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

# use_fakes <tool...>: puts Fake_Bin symlinks for these tools in front of
# PATH, replaying test/unit/fixtures/<tool>/<case>/.
use_fakes() {
  export FIXTURES="$REPO/test/unit/fixtures"
  local t
  for t in "$@"; do
    ln -sf "$REPO/test/unit/fixtures/bin/fake" "$STUBS/$t"
  done
}

# use_sysroot <name>: file Sources (/proc, /sys, /run, /var, /etc) are read
# under test/unit/fixtures/sysroot/<name>/ (DOMOVYK_SYSROOT).
use_sysroot() {
  export DOMOVYK_SYSROOT="$REPO/test/unit/fixtures/sysroot/$1"
}

# only_path <tool...>: a PATH holding the stub folder plus symlinks to the
# named system tools only, so every other Source is missing for this test.
only_path() {
  local dir="$BATS_TEST_TMPDIR/only" t
  mkdir -p "$dir"
  for t in bash sh env cat sed awk grep jq python3 mktemp rm mkdir chmod date stat timeout \
    cp mv tr cut head tail sort uniq wc printf readlink dirname basename uname sleep ln "$@"; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$dir/$t"
  done
  export PATH="$STUBS:$dir"
}
