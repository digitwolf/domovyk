#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# The Redactor as a program: rules file errors, text and JSON modes
# (requirements 5.1, 5.5, 5.6). The properties are in py/test_redact.py.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  dv_setup
  REDACT=(python3 -I "$REPO/libexec/py/redact.py")
  RULES="$REPO/share/redact.tsv"
}

@test "each required rule family is covered (5.5)" {
  local input
  input=$'Authorization: Bearer abcdefghijklmnop1234\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\nhttps://u:pw1234@h.example/x\npasswd=abc secret: def token=ghi\npsk=wifipass1\nAKIAABCDEFGHIJKLMNOP\nghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ12\nsk-ant-api03-abcdefghijklmnopqrstuvwxyz\nsk-proj-abcdefghijklmnopqrstuvwxyz\nx@example.org'
  run -0 "${REDACT[@]}" --rules "$RULES" <<<"$input"
  local secret
  for secret in abcdefghijklmnop1234 AAAA pw1234 abc def ghi wifipass1 AKIAABCDEFGHIJKLMNOP \
    ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ12 sk-ant-api03 sk-proj-abc x@example.org; do
    refute_output --partial "$secret"
  done
  for rule in bearer private-key url-password assignment wifi-psk aws-key-id github-token anthropic-key openai-key email; do
    assert_output --partial "[redacted:$rule]"
  done
}

@test "JSON mode redacts values, keys and secret-named fields (5.1)" {
  run -0 "${REDACT[@]}" --json --rules "$RULES" <<<'{"m":"token=abc12345","password":"hunter2","a@b.io":[1]}'
  run jq -c . <<<"$output"
  assert_output '{"m":"token=[redacted:assignment]","password":"[redacted:key]","[redacted:email]":[1]}'
}

@test "a missing rules file exits 1 with nothing on stdout (5.6)" {
  run -1 --separate-stderr "${REDACT[@]}" --rules "$BATS_TEST_TMPDIR/none.tsv" <<<'x'
  assert_output ''
  [[ $stderr == *none.tsv* ]]
}

@test "an invalid pattern exits 1 naming the rule (5.6)" {
  printf 'broken\t(unclosed\n' >"$BATS_TEST_TMPDIR/bad.tsv"
  run -1 --separate-stderr "${REDACT[@]}" --rules "$BATS_TEST_TMPDIR/bad.tsv" <<<'x'
  assert_output ''
  [[ $stderr == *broken* ]]
}

@test "a Read_Command with a broken rules file prints no Fact_Output (5.6)" {
  fake_tree
  printf 'broken\t(unclosed\n' >"$FAKE_ROOT/share/redact.tsv"
  run -1 --separate-stderr "$DOMOVYK_ROOT/bin/domovyk" commands --json
  assert_output ''
}
