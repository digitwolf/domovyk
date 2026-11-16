#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# tools/fpdiff.py: the Allowlist of the Fingerprint (Glossary of
# .kiro/specs/domovyk-core/requirements.md), ~/.claude/settings.json compared
# as JSON, output and exit codes. Ported from Motanka's test/unit/fpdiff.bats
# at commit d076748.

bats_require_minimum_version 1.5.0

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  FPDIFF="$BATS_TEST_DIRNAME/../../tools/fpdiff.py"
  BEFORE="$BATS_TEST_TMPDIR/before"
  AFTER="$BATS_TEST_TMPDIR/after"
  make_fingerprint "$BEFORE"
  make_fingerprint "$AFTER"
}

make_fingerprint() {
  local d=$1
  mkdir -p "$d"
  printf 'bash\t5.2.21-2ubuntu4\tinstalled\ncoreutils\t9.4-3ubuntu6\tinstalled\n' >"$d/packages.tsv"
  printf 'bash\ncoreutils\n' >"$d/manual.txt"
  printf '# root /etc\n/etc\td\t0755\t0:0\t-\n/etc/hostname\tf\t0644\t0:0\t%s\n' "$SHA_A" >"$d/etc.sha256"
  printf '# root /usr\n/usr\td\t0755\t0:0\t-\n/usr/bin/jq\tf\t0755\t0:0\t%s\n' "$SHA_A" >"$d/usr.sha256"
  printf '# root /var/lib\n/var/lib\td\t0755\t0:0\t-\n/var/lib/dpkg/status\tf\t0644\t0:0\t%s\n' "$SHA_A" >"$d/var-lib.sha256"
  printf 'system ssh.service enabled enabled\nglobal pipewire.service enabled enabled\n' >"$d/units.txt"
  printf '[org/gnome/desktop/interface]\ncolor-scheme=%s\n' "'default'" >"$d/dconf-alice.ini"
  printf '# root /home/alice\n/home/alice\td\t0750\t1001:1001\t-\n/home/alice/.bashrc\tf\t0644\t1001:1001\t%s\n/home/alice/.claude\td\t0700\t1001:1001\t-\n/home/alice/.claude/settings.json\tf\t0600\t1001:1001\t%s\n' "$SHA_A" "$SHA_A" >"$d/home-alice.sha256"
  printf '{"model": "opus", "permissions": {"allow": ["Bash(ls)"], "defaultMode": "default"}}\n' >"$d/claude-settings-alice.json"
  printf 'firefox 140.0 6000 latest/stable mozilla** -\n' >"$d/snaps.txt"
  printf 'alice:x:1001:\nsudo:x:27:\n' >"$d/groups.txt"
  printf 'fs.file-nr = 1024\t0\t9223372036854775807\nkernel.random.uuid = 0b0c6c3e-0000-4000-8000-000000000001\nvm.swappiness = 60\n' >"$d/sysctl.txt"
}

# add_home_entry <path> [kind]: adds an entry to alice's home in AFTER.
add_home_entry() {
  if [[ ${2:-f} == d ]]; then
    printf '%s\td\t0755\t1001:1001\t-\n' "$1" >>"$AFTER/home-alice.sha256"
  else
    printf '%s\tf\t0644\t1001:1001\t%s\n' "$1" "$SHA_B" >>"$AFTER/home-alice.sha256"
  fi
}

# settings <json>: replaces alice's settings.json in AFTER.
settings() {
  printf '%s\n' "$1" >"$AFTER/claude-settings-alice.json"
}

# fpdiff: runs fpdiff.py on BEFORE and AFTER; $output is its stdout.
fpdiff() {
  run --separate-stderr python3 -I "$FPDIFF" "$BEFORE" "$AFTER"
}

@test "identical Fingerprints: exit 0 and no output" {
  fpdiff
  assert_success
  assert_output ''
}

@test "a changed package version is reported" {
  printf 'bash\t5.2.21-2ubuntu5\tinstalled\ncoreutils\t9.4-3ubuntu6\tinstalled\n' >"$AFTER/packages.tsv"
  fpdiff
  assert_failure 1
  assert_output --partial 'packages.tsv: changed bash: 5.2.21-2ubuntu4 installed -> 5.2.21-2ubuntu5 installed'
}

@test "an added package is reported" {
  printf 'domovyk\t0.1.0-1\tinstalled\n' >>"$AFTER/packages.tsv"
  fpdiff
  assert_failure 1
  assert_output 'packages.tsv: added domovyk (0.1.0-1 installed)'
  assert_equal "$stderr" 'fpdiff: 1 difference(s)'
}

@test "~/.cache is allowlisted, including Domovyk's own ~/.cache/domovyk" {
  add_home_entry /home/alice/.cache d
  add_home_entry /home/alice/.cache/domovyk d
  add_home_entry /home/alice/.cache/domovyk/facts.json
  add_home_entry /home/alice/.cache/thumbnails/normal/x.png
  fpdiff
  assert_success
  assert_output ''
}

@test "a sibling of ~/.cache is not allowlisted" {
  add_home_entry /home/alice/.cachefile
  fpdiff
  assert_failure 1
  assert_output --partial 'home-alice.sha256: added /home/alice/.cachefile'
}

@test "~/.claude/ is allowlisted apart from settings.json" {
  add_home_entry /home/alice/.claude/projects d
  add_home_entry /home/alice/.claude/projects/x/1.jsonl
  add_home_entry /home/alice/.claude/plugins/known_marketplaces.json
  add_home_entry /home/alice/.claude/settings.local.json
  fpdiff
  assert_success
  assert_output ''
}

@test "~/.claude.json is not under ~/.claude/ and is compared" {
  add_home_entry /home/alice/.claude.json
  fpdiff
  assert_failure 1
  assert_output --partial 'home-alice.sha256: added /home/alice/.claude.json'
}

@test "settings.json is compared as JSON: key order and formatting do not matter" {
  settings '{
    "permissions": {"defaultMode": "default", "allow": ["Bash(ls)"]},
    "model": "opus"
  }'
  # The checksum in the tree changes with the bytes; only the JSON counts.
  sed -i "s|^\(/home/alice/.claude/settings.json\t.*\t\)$SHA_A\$|\1$SHA_B|" "$AFTER/home-alice.sha256"
  fpdiff
  assert_success
  assert_output ''
}

@test "a changed settings.json value is reported by its path" {
  settings '{"model": "opus", "permissions": {"allow": ["Bash(ls)"], "defaultMode": "plan"}}'
  fpdiff
  assert_failure 1
  assert_output 'claude-settings-alice.json: changed $.permissions.defaultMode: "default" -> "plan"'
}

@test "a changed list in settings.json is reported whole" {
  settings '{"model": "opus", "permissions": {"allow": ["Bash(domovyk status)", "Bash(ls)"], "defaultMode": "default"}}'
  fpdiff
  assert_failure 1
  assert_output --partial 'changed $.permissions.allow: ["Bash(ls)"] -> ["Bash(domovyk status)", "Bash(ls)"]'
}

@test "added and removed settings.json keys are reported, odd key names quoted" {
  settings '{"model": "opus", "permissions": {"allow": ["Bash(ls)"]}, "env": {"A.B": "1"}}'
  fpdiff
  assert_failure 1
  assert_line 'claude-settings-alice.json: added $.env["A.B"] ("1")'
  assert_line 'claude-settings-alice.json: removed $.permissions.defaultMode ("default")'
}

@test "settings.json keeps true and 1 apart" {
  printf '{"a": 1}\n' >"$BEFORE/claude-settings-alice.json"
  settings '{"a": true}'
  fpdiff
  assert_failure 1
  assert_output --partial 'changed $.a: 1 -> true'
}

@test "a settings.json that appears is reported" {
  rm "$BEFORE/claude-settings-alice.json"
  sed -i '\|/home/alice/.claude/settings.json\t|d' "$BEFORE/home-alice.sha256"
  fpdiff
  assert_failure 1
  assert_line "claude-settings-alice.json: only in $AFTER"
  assert_line --partial 'home-alice.sha256: added /home/alice/.claude/settings.json (f 0600 1001:1001 json)'
}

@test "a changed mode of settings.json is reported" {
  sed -i 's|^\(/home/alice/.claude/settings.json\t\)f\t0600|\1f\t0644|' "$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 1
  assert_output 'home-alice.sha256: changed /home/alice/.claude/settings.json: f 0600 1001:1001 json -> f 0644 1001:1001 json'
}

@test "invalid JSON in settings.json is a difference unless both copies are equal" {
  settings '{"model": '
  fpdiff
  assert_failure 1
  assert_output 'claude-settings-alice.json: changed: not valid JSON in after'
  cp "$AFTER/claude-settings-alice.json" "$BEFORE/claude-settings-alice.json"
  fpdiff
  assert_success
}

@test "a changed home file is reported with old and new values" {
  sed -i "s|^\(/home/alice/.bashrc\t.*\t\)$SHA_A\$|\1$SHA_B|" "$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial "home-alice.sha256: changed /home/alice/.bashrc: f 0644 1001:1001 $SHA_A -> f 0644 1001:1001 $SHA_B"
}

@test "a removed home file is reported" {
  sed -i '\|^/home/alice/.bashrc\t|d' "$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial 'home-alice.sha256: removed /home/alice/.bashrc'
}

@test "the home folder itself is never allowlisted" {
  sed -i 's|^/home/alice\td\t0750|/home/alice\td\t0700|' "$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial 'home-alice.sha256: changed /home/alice: d 0750'
}

@test "volatile sysctl keys are allowlisted" {
  printf 'fs.file-nr = 2048\t0\t9223372036854775807\nkernel.random.uuid = 0b0c6c3e-0000-4000-8000-000000000002\nvm.swappiness = 60\n' >"$AFTER/sysctl.txt"
  fpdiff
  assert_success
}

@test "a configured sysctl change is reported" {
  printf 'fs.file-nr = 1024\t0\t9223372036854775807\nkernel.random.uuid = 0b0c6c3e-0000-4000-8000-000000000001\nvm.swappiness = 10\n' >"$AFTER/sysctl.txt"
  fpdiff
  assert_failure 1
  assert_output --partial 'sysctl.txt: changed vm.swappiness: 60 -> 10'
}

@test "a new file in /etc is reported" {
  printf '/etc/apt/sources.list.d/domovyk.sources\tf\t0644\t0:0\t%s\n' "$SHA_B" >>"$AFTER/etc.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial 'etc.sha256: added /etc/apt/sources.list.d/domovyk.sources'
}

@test "a new file in /usr is reported" {
  printf '/usr/bin/domovyk\tl\t0777\t0:0\t../share/domovyk/bin/domovyk\n' >>"$AFTER/usr.sha256"
  fpdiff
  assert_failure 1
  assert_output 'usr.sha256: added /usr/bin/domovyk (l 0777 0:0 ../share/domovyk/bin/domovyk)'
}

@test "apt lists and dpkg's -old copies are allowlisted, the dpkg database is not" {
  printf '/var/lib/apt/lists/archive.ubuntu.com_dists_noble_InRelease\tf\t0644\t0:0\t%s\n/var/lib/dpkg/status-old\tf\t0644\t0:0\t%s\n' "$SHA_A" "$SHA_A" >>"$BEFORE/var-lib.sha256"
  printf '/var/lib/apt/lists/archive.ubuntu.com_dists_noble_InRelease\tf\t0644\t0:0\t%s\n/var/lib/dpkg/status-old\tf\t0644\t0:0\t%s\n/var/lib/apt/lists/partial\td\t0700\t0:0\t-\n' "$SHA_B" "$SHA_B" >>"$AFTER/var-lib.sha256"
  fpdiff
  assert_success
  sed -i "s|^\(/var/lib/dpkg/status\t.*\t\)$SHA_A\$|\1$SHA_B|" "$AFTER/var-lib.sha256"
  fpdiff
  assert_failure 1
  assert_output "var-lib.sha256: changed /var/lib/dpkg/status: f 0644 0:0 $SHA_A -> f 0644 0:0 $SHA_B"
}

@test "/var/log and the journal are allowlisted in any tree file" {
  printf '# root /var\n/var/log/syslog\tf\t0640\t104:4\t%s\n/var/cache/apt/pkgcache.bin\tf\t0644\t0:0\t%s\n' "$SHA_A" "$SHA_A" >"$BEFORE/var.sha256"
  printf '# root /var\n/var/log/syslog\tf\t0640\t104:4\t%s\n/var/log/journal/x/system.journal\tf\t0640\t0:101\t%s\n' "$SHA_B" "$SHA_B" >"$AFTER/var.sha256"
  fpdiff
  assert_success
}

@test "the shadow tools' backup copies in /etc are ignored, the account files are not" {
  printf '/etc/group-\tf\t0644\t0:0\t%s\n/etc/gshadow-\tf\t0640\t0:42\t%s\n/etc/group\tf\t0644\t0:0\t%s\n' "$SHA_A" "$SHA_A" "$SHA_A" >>"$BEFORE/etc.sha256"
  printf '/etc/group-\tf\t0644\t0:0\t%s\n/etc/gshadow-\tf\t0640\t0:42\t%s\n/etc/group\tf\t0644\t0:0\t%s\n' "$SHA_B" "$SHA_B" "$SHA_A" >>"$AFTER/etc.sha256"
  fpdiff
  assert_success
  printf '/etc/group\tf\t0644\t0:0\t%s\n' "$SHA_B" >>"$AFTER/etc.sha256"
  sed -i "\|^/etc/group\t.*$SHA_A\$|d" "$AFTER/etc.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial 'etc.sha256: changed /etc/group:'
}

@test "a dconf change is reported with its full key" {
  printf '[org/gnome/desktop/interface]\ncolor-scheme=%s\n' "'prefer-dark'" >"$AFTER/dconf-alice.ini"
  fpdiff
  assert_failure 1
  assert_output --partial "dconf-alice.ini: changed org/gnome/desktop/interface/color-scheme: 'default' -> 'prefer-dark'"
}

@test "a changed unit state is reported" {
  printf 'system ssh.service disabled enabled\nglobal pipewire.service enabled enabled\n' >"$AFTER/units.txt"
  fpdiff
  assert_failure 1
  assert_line 'units.txt: - system ssh.service enabled enabled'
  assert_line 'units.txt: + system ssh.service disabled enabled'
}

@test "line-based files show removed and added lines" {
  printf 'alice:x:1001:\nsudo:x:27:alice\n' >"$AFTER/groups.txt"
  fpdiff
  assert_failure 1
  assert_line 'groups.txt: - sudo:x:27:'
  assert_line 'groups.txt: + sudo:x:27:alice'
}

@test "GDM's numbered greeter users are left out of group member lists" {
  printf 'alice:x:1001:\nsudo:x:27:\ngdm:x:975:gdm-greeter\n' >"$BEFORE/groups.txt"
  printf 'alice:x:1001:\nsudo:x:27:\ngdm:x:975:gdm-greeter-2\n' >"$AFTER/groups.txt"
  fpdiff
  assert_success
  assert_output ''
}

@test "other members of group gdm are still compared" {
  printf 'alice:x:1001:\nsudo:x:27:\ngdm:x:975:gdm-greeter\n' >"$BEFORE/groups.txt"
  printf 'alice:x:1001:\nsudo:x:27:\ngdm:x:975:gdm-greeter-2,alice\n' >"$AFTER/groups.txt"
  fpdiff
  assert_failure 1
  assert_line 'groups.txt: - gdm:x:975:'
  assert_line 'groups.txt: + gdm:x:975:alice'
}

@test "a file present on one side only is reported" {
  rm "$AFTER/snaps.txt"
  fpdiff
  assert_failure 1
  assert_output --partial "snaps.txt: only in $BEFORE"
}

@test "a new user's home folder is reported" {
  printf '# root /home/bob\n/home/bob\td\t0750\t1002:1002\t-\n' >"$AFTER/home-bob.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial "home-bob.sha256: only in $AFTER"
}

@test "home Allowlist entries do not apply to system tree files" {
  printf '/etc/.cache\td\t0755\t0:0\t-\n' >>"$AFTER/etc.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial 'etc.sha256: added /etc/.cache'
}

@test "a missing folder is an input error" {
  run python3 -I "$FPDIFF" "$BEFORE" "$BATS_TEST_TMPDIR/missing"
  assert_failure 2
  assert_output --partial 'not a folder'
}

@test "a home tree file without a root header is an input error" {
  printf '/home/alice/.bashrc\tf\t0644\t1001:1001\t%s\n' "$SHA_A" >"$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 2
}

@test "wrong number of arguments is a usage error" {
  run python3 -I "$FPDIFF" "$BEFORE"
  assert_failure 2
}
