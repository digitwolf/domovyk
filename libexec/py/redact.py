#!/usr/bin/env python3
"""Redactor: replace Secrets in Fact_Output with [redacted:<rule>].

Usage: redact.py [--json] [--rules FILE] < input > output

Rules are lines of FILE: name<TAB>pattern[<TAB>flags], where flags may hold
"i" (ignore case). Lines that are empty or start with "#" are skipped. When a
pattern has a group named "secret", only that group is replaced, so the key in
"password=..." survives; otherwise the whole match is replaced.

In --json mode every string value and every object key is redacted, and the
value of any key that itself names a secret (password, token, ...) is replaced
whole. Exit status 1, with nothing on stdout, when the rules file is missing
or holds an invalid pattern (requirement 5.6).
"""

import json
import re
import sys

SECRET_KEYS = re.compile(
    r"^(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key"
    r"|client[_-]?secret|psk|private[_-]?key)$",
    re.IGNORECASE,
)


def die(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def load_rules(path):
    try:
        handle = open(path, encoding="utf-8")
    except OSError as err:
        die("redact: %s: %s" % (path, err.strerror))
    rules = []
    with handle:
        for number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) not in (2, 3) or not parts[0] or not parts[1]:
                die("redact: %s:%d: expected name<TAB>pattern[<TAB>flags]" % (path, number))
            name, pattern = parts[0], parts[1]
            flags = re.IGNORECASE if len(parts) == 3 and "i" in parts[2] else 0
            try:
                rules.append((name, re.compile(pattern, flags)))
            except re.error as err:
                die("redact: %s: %s" % (name, err))
    if not rules:
        die("redact: %s: no rules" % path)
    return rules


def redact_text(text, rules):
    for name, regex in rules:
        marker = "[redacted:%s]" % name
        if "secret" in regex.groupindex:

            def keep_key(match, marker=marker):
                start, end = match.span("secret")
                whole = match.group(0)
                offset = match.start()
                return whole[: start - offset] + marker + whole[end - offset :]

            text = regex.sub(keep_key, text)
        else:
            text = regex.sub(marker, text)
    return text


def redact_json(value, rules):
    if isinstance(value, str):
        return redact_text(value, rules)
    if isinstance(value, list):
        return [redact_json(item, rules) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            new_key = redact_text(key, rules)
            if SECRET_KEYS.match(key) and isinstance(item, str) and item:
                result[new_key] = "[redacted:key]"
            else:
                result[new_key] = redact_json(item, rules)
        return result
    return value


def main(argv):
    json_mode = False
    rules_path = "/usr/share/domovyk/redact.tsv"
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--json":
            json_mode = True
        elif arg == "--rules" and args:
            rules_path = args.pop(0)
        else:
            die("usage: redact.py [--json] [--rules FILE]")
    rules = load_rules(rules_path)
    data = sys.stdin.read()
    if json_mode:
        try:
            document = json.loads(data)
        except ValueError as err:
            die("redact: input is not JSON: %s" % err)
        sys.stdout.write(json.dumps(redact_json(document, rules), ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(redact_text(data, rules))


if __name__ == "__main__":
    main(sys.argv[1:])
