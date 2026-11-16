"""Seeded property tests for the Guard_Hook (requirements 18.1, 18.3).

For random compositions of allowed commands joined by ;, &&, ||, |, $(...),
backticks and bash -c, inserting a privilege tool in front of any one simple
command flips the decision to deny, and the same composition without it gets
no decision.
"""

import importlib.util
import os
import random
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
os.environ.setdefault("DOMOVYK_LIBEXEC", os.path.join(REPO, "libexec"))
SPEC = importlib.util.spec_from_file_location("guard", os.path.join(REPO, "libexec", "py", "guard.py"))
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
CASES = 500

ALLOWED = [
    "ls -la", "echo hi", "cat /etc/os-release", "grep -r foo .", "journalctl -b -p err",
    "systemctl --failed", "df -h", "uname -r", "rm -rf ./build", "jq . f.json", "wc -l x",
    "find . -name '*.log'", "env FOO=1 ls", "timeout 5 ls", "python3 -c 'print(1)'",
]
PRIV = ["sudo", "pkexec", "doas", "su -c", "run0", "/usr/bin/sudo", "env A=1 sudo", "timeout 3 sudo", "xargs sudo"]


def decision(command):
    try:
        guard.decide({"tool_name": "Bash", "tool_input": {"command": command}})
        return None
    except guard.Deny as deny:
        return deny.reason


def compose(rng, parts):
    """Joins simple commands with random operators and nesting."""
    text = parts[0]
    for part in parts[1:]:
        op = rng.choice([" ; ", " && ", " || ", " | ", "\n"])
        text = text + op + part
    wrap = rng.choice(["plain", "subst", "backtick", "bash-c", "subshell", "group"])
    if wrap == "subst":
        text = 'echo "$(%s)"' % text
    elif wrap == "backtick":
        text = "echo `%s`" % text.replace("`", "")
    elif wrap == "bash-c":
        text = "bash -c \"%s\"" % text.replace('"', "'")
    elif wrap == "subshell":
        text = "( %s )" % text
    elif wrap == "group":
        text = "{ %s; }" % text
    return text


class GuardProperties(unittest.TestCase):
    def test_insert_privilege_denies_remove_restores(self):
        rng = random.Random(20261115)
        for _ in range(CASES):
            parts = [rng.choice(ALLOWED) for _ in range(rng.randint(1, 4))]
            state = rng.getstate()
            clean = compose(rng, parts)
            self.assertIsNone(decision(clean), msg=clean)
            i = rng.randrange(len(parts))
            dirty_parts = list(parts)
            dirty_parts[i] = rng.choice(PRIV) + " " + parts[i]
            rng.setstate(state)
            dirty = compose(rng, dirty_parts)
            reason = decision(dirty)
            self.assertIsNotNone(reason, msg=dirty)
            self.assertIn("domovyk handoff", reason, msg=dirty)

    def test_decision_ignores_surrounding_whitespace(self):
        rng = random.Random(3)
        for _ in range(CASES):
            cmd = rng.choice(ALLOWED + ["sudo ls", "rm -rf ~"])
            padded = " " * rng.randint(0, 3) + cmd + rng.choice(["", " ", "\n", "  "])
            self.assertEqual(decision(cmd) is None, decision(padded) is None, msg=repr(padded))


if __name__ == "__main__":
    unittest.main()
