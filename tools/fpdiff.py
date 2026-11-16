#!/usr/bin/env python3
"""Compare two Fingerprint folders captured by test/vm/fingerprint.

Ported from Motanka's tools/fpdiff.py at commit d076748.

Prints every difference that remains after the Allowlist is applied, one per
line. The Fingerprint and what it leaves out are defined in the Glossary of
.kiro/specs/domovyk-core/requirements.md.

Exit codes: 0 no differences, 1 differences found, 2 usage or input error.

File handling:
  *.sha256        tree files keyed by path; home-<user>.sha256 paths are
                  matched against the home-folder Allowlist relative to the
                  "# root" header, other tree files against system paths
  claude-settings-<user>.json
                  the user's ~/.claude/settings.json, compared as JSON:
                  key order and formatting do not matter, every changed,
                  added or removed value is reported by its path ($.a.b)
  packages.tsv    keyed by package name
  sysctl.txt      keyed by sysctl key
  dconf-*.ini     keyed by <dconf path>/<key>
  groups.txt      lines of `getent group`, with GDM's greeter users left
                  out of every member list (see GDM_GREETER)
  anything else   compared as a set of lines

Home-folder Allowlist (the Glossary): ~/.cache and ~/.claude/, which is
Claude Code's own state, except ~/.claude/settings.json. That file's tree
entry is still compared for its type, mode and owner; its content is
compared as JSON through claude-settings-<user>.json.

System Allowlist: apt and dpkg caches (the Glossary), plus the noise that
Motanka's harness needed to leave out (see SYSTEM_ALLOW and SYSCTL_ALLOW).
"""

import argparse
import collections
import fnmatch
import json
import os
import re
import sys

# --- Allowlist ---------------------------------------------------------------
# System paths, matched component by component from the filesystem root.
SYSTEM_ALLOW = (
    # The Glossary: apt and dpkg caches. apt rewrites its lists and package
    # caches on every update, and dpkg keeps the previous copy of each of
    # its database files as <file>-old.
    "var/cache/apt",
    "var/lib/apt/lists",
    "var/lib/dpkg/*-old",
    # Kept from Motanka: logs and the journal grow while the VM runs. The
    # Fingerprint holds no tree under /var/log or /run today; these entries
    # keep it that way if one is added.
    "var/log",
    "var/log/journal",
    "run/log/journal",
    # Kept from Motanka: the backup copies the shadow tools (useradd,
    # groupadd, groupdel, ...) write at every account change, holding the
    # previous version. A package that adds a system group on install and
    # deletes it on purge (pipewire on 24.04) leaves the account files as
    # they were but changes these. The account files themselves and
    # groups.txt are compared.
    "etc/passwd-",
    "etc/group-",
    "etc/shadow-",
    "etc/gshadow-",
)

# Home-folder paths, matched component by component from the home folder.
HOME_ALLOW = (
    ".cache",
    ".claude",
)

# The one path under an allowlisted home folder that is still compared, as
# JSON (see the top).
HOME_JSON = ".claude/settings.json"

# Kept from Motanka: sysctl keys whose values change without configuration
# (counters, random values and the kernel's own tuning).
SYSCTL_ALLOW = (
    "fs.aio-nr",
    "fs.dentry-state",
    "fs.file-nr",
    "fs.inode-nr",
    "fs.inode-state",
    "fs.quota.*",
    "kernel.ns_last_pid",
    "kernel.perf_event_max_sample_rate",
    "kernel.pty.nr",
    "kernel.random.boot_id",
    "kernel.random.entropy_avail",
    "kernel.random.uuid",
    "kernel.tainted",
    "net.core.netdev_rss_key",
    "net.ipv4.tcp_fastopen_key",
    "net.netfilter.nf_conntrack_count",
)

# Kept from Motanka: GDM 49 (Ubuntu 26.04) logs its greeter in as a dynamic
# user per display, gdm-greeter, gdm-greeter-2 and so on, that systemd's
# userdb lists as a member of group gdm while it runs; /etc/group does not
# change. Which number is running depends on how many greeters GDM started
# since boot, so these names are left out of every group's member list.
GDM_GREETER = re.compile(r"gdm-greeter(-[0-9]+)?")

ROOT_HEADER = "# root "
JSON_FILE = re.compile(r"claude-settings-.+\.json")
JSON_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")


class InputError(Exception):
    pass


def _match(parts, patterns):
    for pattern in patterns:
        pp = pattern.split("/")
        if len(parts) >= len(pp) and all(
            fnmatch.fnmatchcase(a, b) for a, b in zip(parts, pp)
        ):
            return True
    return False


def system_allowed(path):
    return _match(path.strip("/").split("/"), SYSTEM_ALLOW)


def home_relative(root, path):
    """The path relative to the home folder, "" for the folder itself, or None."""
    root = root.rstrip("/")
    if path == root:
        return ""
    if not path.startswith(root + "/"):
        return None
    return path[len(root) + 1:]


def home_allowed(rel):
    return _match(rel.split("/"), HOME_ALLOW)


def sysctl_allowed(key):
    return any(fnmatch.fnmatchcase(key, p) for p in SYSCTL_ALLOW)


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def read_lines(path):
    text = read_bytes(path).decode("utf-8", "surrogateescape")
    return [line for line in text.split("\n") if line != ""]


def parse_tree(name, lines, home):
    """Returns {path: "type mode owner data"} without the allowlisted paths."""
    entries = {}
    root = None
    for line in lines:
        if line.startswith(ROOT_HEADER):
            root = line[len(ROOT_HEADER):]
            continue
        if line.startswith("#"):
            continue
        path, _, rest = line.partition("\t")
        if home:
            if root is None:
                raise InputError(f"{name}: entry before the '# root' header")
            rel = home_relative(root, path)
            if rel == HOME_JSON:
                fields = rest.split("\t")
                if fields[0] == "f" and len(fields) == 4:
                    # The content is compared as JSON; see the top.
                    rest = "\t".join(fields[:3] + ["json"])
            elif rel and home_allowed(rel):
                continue
        elif system_allowed(path):
            continue
        entries[path] = rest
    return entries


def parse_packages(lines):
    entries = {}
    for line in lines:
        key, _, rest = line.partition("\t")
        entries[key] = rest
    return entries


def parse_sysctl(lines):
    entries = {}
    for line in lines:
        key, sep, value = line.partition(" = ")
        if not sep:
            key, value = line, ""
        if sysctl_allowed(key):
            continue
        entries[key] = value
    return entries


def parse_dconf(lines):
    entries = {}
    section = ""
    for line in lines:
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, _, value = line.partition("=")
        entries[f"{section}/{key}" if section else key] = value
    return entries


def parse_groups(lines):
    out = []
    for line in lines:
        parts = line.split(":")
        if len(parts) == 4:
            members = [
                m
                for m in parts[3].split(",")
                if m and not GDM_GREETER.fullmatch(m)
            ]
            parts[3] = ",".join(members)
        out.append(":".join(parts))
    return out


def json_path(keys):
    out = "$"
    for k in keys:
        out += f".{k}" if JSON_KEY.fullmatch(k) else f"[{json.dumps(k)}]"
    return out


def flatten_json(value, keys=(), out=None):
    """{path: canonical JSON} of every leaf; a non-empty object is not a leaf."""
    if out is None:
        out = {}
    if isinstance(value, dict) and value:
        for k, v in value.items():
            flatten_json(v, keys + (k,), out)
    else:
        # sort_keys and the JSON spelling keep true and 1, or 1 and 1.0, apart.
        out[json_path(keys)] = json.dumps(value, sort_keys=True, ensure_ascii=False)
    return out


def load_json(data):
    try:
        return True, json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return False, None


def compare_json(name, path_a, path_b):
    a = read_bytes(path_a)
    b = read_bytes(path_b)
    ok_a, va = load_json(a)
    ok_b, vb = load_json(b)
    if ok_a and ok_b:
        return diff_keyed(name, flatten_json(va), flatten_json(vb))
    if a == b:
        return []
    which = "neither side" if not (ok_a or ok_b) else ("before" if not ok_a else "after")
    return [f"{name}: changed: not valid JSON in {which}"]


def show(value):
    return " ".join(value.split("\t"))


def diff_keyed(name, before, after):
    out = []
    for key in sorted(set(before) | set(after)):
        if key not in before:
            extra = f" ({show(after[key])})" if after[key] else ""
            out.append(f"{name}: added {key}{extra}")
        elif key not in after:
            extra = f" ({show(before[key])})" if before[key] else ""
            out.append(f"{name}: removed {key}{extra}")
        elif before[key] != after[key]:
            out.append(
                f"{name}: changed {key}: {show(before[key])} -> {show(after[key])}"
            )
    return out


def diff_lines(name, before, after):
    a = collections.Counter(before)
    b = collections.Counter(after)
    out = [f"{name}: - {line}" for line in sorted((a - b).elements())]
    out += [f"{name}: + {line}" for line in sorted((b - a).elements())]
    return out


def compare_file(name, path_a, path_b):
    if JSON_FILE.fullmatch(name):
        return compare_json(name, path_a, path_b)
    a = read_lines(path_a)
    b = read_lines(path_b)
    if name.endswith(".sha256"):
        home = name.startswith("home-")
        return diff_keyed(name, parse_tree(name, a, home), parse_tree(name, b, home))
    if name == "packages.tsv":
        return diff_keyed(name, parse_packages(a), parse_packages(b))
    if name == "sysctl.txt":
        return diff_keyed(name, parse_sysctl(a), parse_sysctl(b))
    if name.startswith("dconf-") and name.endswith(".ini"):
        return diff_keyed(name, parse_dconf(a), parse_dconf(b))
    if name == "groups.txt":
        return diff_lines(name, parse_groups(a), parse_groups(b))
    return diff_lines(name, a, b)


def list_files(folder):
    return {
        n
        for n in os.listdir(folder)
        if not n.startswith(".") and os.path.isfile(os.path.join(folder, n))
    }


def compare(before, after):
    files_a = list_files(before)
    files_b = list_files(after)
    out = []
    for name in sorted(files_a | files_b):
        if name not in files_b:
            out.append(f"{name}: only in {before}")
        elif name not in files_a:
            out.append(f"{name}: only in {after}")
        else:
            out += compare_file(
                name, os.path.join(before, name), os.path.join(after, name)
            )
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="fpdiff.py",
        description="Compare two Fingerprint folders, ignoring the Allowlist.",
    )
    parser.add_argument("before", help="Fingerprint folder captured first")
    parser.add_argument("after", help="Fingerprint folder captured later")
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(errors="backslashreplace")

    for folder in (args.before, args.after):
        if not os.path.isdir(folder):
            print(f"fpdiff: not a folder: {folder}", file=sys.stderr)
            return 2
    try:
        diffs = compare(args.before, args.after)
    except (InputError, OSError) as e:
        print(f"fpdiff: {e}", file=sys.stderr)
        return 2

    for line in diffs:
        print(line)
    if diffs:
        print(f"fpdiff: {len(diffs)} difference(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
