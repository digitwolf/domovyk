"""Seeded property tests for the Redactor (requirements 5.2, 5.3).

Run with: python3 -I -m unittest discover -s test/unit/py
"""

import importlib.util
import os
import random
import string
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SPEC = importlib.util.spec_from_file_location("redact", os.path.join(REPO, "libexec", "py", "redact.py"))
redact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(redact)
RULES = redact.load_rules(os.path.join(REPO, "share", "redact.tsv"))
CASES = 500

# Characters for filler text: no "@", ":", "=" or "-", so filler alone never
# forms an email, URL credential, assignment or key prefix.
FILLER = string.ascii_letters + string.digits + " .,()/\n\t"


def filler(rng, n):
    text = "".join(rng.choice(FILLER) for _ in range(n))
    # Keep words that a rule keys on out of the filler.
    for word in ("bearer", "Bearer", "BEARER", "psk", "PSK", "AKIA", "ASIA", "gh"):
        text = text.replace(word, "w")
    return text


def token(rng, n, alphabet=string.ascii_letters + string.digits):
    return "".join(rng.choice(alphabet) for _ in range(n))


def secret_forms(rng):
    """(text containing a secret, the secret string)."""
    value = token(rng, rng.randint(8, 30))
    key = rng.choice(["password", "passwd", "secret", "token", "api_key", "apikey", "PASSWORD"])
    forms = [
        ("%s=%s" % (key, value), value),
        ("%s: %s" % (key, value), value),
        ("Authorization: Bearer %s" % (value + token(rng, 16)), None),
        ("https://user:%s@host.example/p" % value, value),
        ("psk=%s" % value, value),
        ("AKIA" + token(rng, 16, string.ascii_uppercase + string.digits), None),
        ("ghp_" + token(rng, 40), None),
        ("sk-ant-api03-" + token(rng, 30), None),
        ("sk-proj-" + token(rng, 30), None),
        ("%s@%s.org" % (token(rng, 6).lower(), token(rng, 5).lower()), None),
        ("-----BEGIN RSA PRIVATE KEY-----\n%s\n-----END RSA PRIVATE KEY-----" % value, value),
    ]
    text, secret = rng.choice(forms)
    if secret is None:
        secret = text.split()[-1] if " " in text else text
    return text, secret


class RedactorProperties(unittest.TestCase):
    def test_secrets_never_survive(self):
        rng = random.Random(20261115)
        for _ in range(CASES):
            text, secret = secret_forms(rng)
            doc = filler(rng, rng.randint(0, 40)) + " " + text + " " + filler(rng, rng.randint(0, 40))
            out = redact.redact_text(doc, RULES)
            self.assertNotIn(secret, out, msg=repr(doc))
            self.assertIn("[redacted:", out, msg=repr(doc))

    def test_clean_text_is_unchanged(self):
        rng = random.Random(42)
        for _ in range(CASES):
            doc = filler(rng, rng.randint(0, 200))
            self.assertEqual(redact.redact_text(doc, RULES), doc)

    def test_idempotent(self):
        rng = random.Random(7)
        for _ in range(CASES):
            text, _ = secret_forms(rng)
            doc = filler(rng, 20) + " " + text + " " + filler(rng, 20)
            once = redact.redact_text(doc, RULES)
            self.assertEqual(redact.redact_text(once, RULES), once)

    def test_json_mode_reaches_nested_strings(self):
        rng = random.Random(99)
        for _ in range(CASES):
            text, secret = secret_forms(rng)
            doc = {"a": [{"b": "x " + text}], "c": 1}
            out = redact.redact_json(doc, RULES)
            self.assertNotIn(secret, repr(out))
            self.assertEqual(out["c"], 1)


if __name__ == "__main__":
    unittest.main()
