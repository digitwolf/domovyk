#!/usr/bin/env python3
"""Guard_Hook: Claude Code PreToolUse decision for the Bash tool.

Reads the hook JSON on stdin. Prints a deny decision as JSON on stdout, or
nothing to leave the normal permission flow in place (requirements 18.1-18.5).

The command is tokenized with shlex (punctuation_chars), split into simple
commands, and every simple command is normalized: leading assignments are
dropped and wrapper programs (env, command, exec, nice, nohup, time, timeout,
stdbuf, xargs, find -exec, ssh <host>) are unwrapped. Shell strings given to
bash/sh/zsh/dash -c, eval, $(...) and backticks are parsed recursively, up to
MAX_DEPTH levels. When in doubt the guard denies: an unparsable command is
denied, and so is a privilege tool word inside a single-quoted $(...).
"""

import json
import os
import re
import shlex
import sys

MAX_DEPTH = 5

PRIVILEGE = {"sudo", "pkexec", "su", "doas", "run0", "sudoedit"}
PRIVILEGE_REASON = (
    "Domovyk does not run privileged commands. Write the change as a handoff "
    'script: domovyk handoff create --title "<what it does>" with the script on '
    "stdin, and show it to the owner, who runs it with sudo."
)

SYSTEM_TOP = {
    "/bin", "/boot", "/etc", "/lib", "/lib32", "/lib64", "/libx32", "/opt", "/root",
    "/sbin", "/snap", "/srv", "/usr", "/var", "/home", "/dev", "/proc", "/sys",
}
MKFS_LIKE = {
    "mkswap", "wipefs", "blkdiscard", "sgdisk", "sfdisk", "parted", "fdisk",
    "gdisk", "cfdisk", "cryptsetup",
}
BLOCK_DEVICE = re.compile(r"^/dev/(sd|hd|vd|xvd|nvme|mmcblk|mapper/|dm-|md|loop|disk/)")
FORK_BOMB = re.compile(r":\s*\(\s*\)\s*\{\s*:\s*\|\s*:?\s*&\s*\}\s*;?\s*:")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "mksh", "busybox"}
SEPARATORS = {";", "&", "&&", "||", "|", "|&", "(", ")", "{", "}", "\n", ";;", ";&", ";;&", "!"}
REDIRECT = re.compile(r"^[0-9]*(>>?|<<?<?|>&|<&|&>>?|>\||<>)$")
PUNCTUATION = set(";&|()<>\n")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
INVESTIGATOR_FILTERS = {"jq", "head", "tail", "grep", "wc", "sort", "uniq", "cut"}


class Deny(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def home_dir():
    return os.path.realpath(os.path.expanduser("~")).rstrip("/") or "/"


def normalize_path(word):
    """Expands ~ and $HOME, strips trailing slashes and a trailing /*."""
    home = home_dir()
    w = word
    for prefix in ("${HOME}", "$HOME", "~"):
        if w == prefix or w.startswith(prefix + "/"):
            w = home + w[len(prefix):]
            break
    star = False
    while w.endswith("/*") or w.endswith("/.*"):
        w = w[: w.rfind("/")]
        star = True
    if len(w) > 1:
        w = w.rstrip("/")
    if w == "" and (word.startswith("/") or star):
        w = "/"
    return w


def protected_target(word):
    path = normalize_path(word)
    if path in ("/", "/*"):
        return True
    if path in SYSTEM_TOP:
        return True
    home = home_dir()
    if path == home:
        return True
    # /home/<user> for any user
    if re.fullmatch(r"/home/[^/]+", path):
        return True
    return False


def tokenize(command):
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = "#"
    return list(lex)


def split_simple(tokens):
    """Splits tokens into simple commands; returns [(words, redirect_targets)]."""
    commands, words, targets = [], [], []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        # Redirections first: "&>" and ">&" contain "&" but are not separators.
        if REDIRECT.match(tok):
            if i + 1 < len(tokens):
                targets.append(tokens[i + 1])
                i += 2
            else:
                i += 1
            continue
        # Any other run of punctuation separates commands, including "<(" and
        # ">(" (process substitution), whose body starts a new command.
        if tok in SEPARATORS or (tok and set(tok) <= PUNCTUATION):
            if words or targets:
                commands.append((words, targets))
            words, targets = [], []
            i += 1
            continue
        if tok in ("{", "}"):
            i += 1
            continue
        words.append(tok)
        i += 1
    if words or targets:
        commands.append((words, targets))
    return commands


def substitutions(word):
    """Bodies of $(...) and `...` inside one word."""
    bodies = []
    i = 0
    while i < len(word):
        if word.startswith("$(", i) and not word.startswith("$((", i):
            depth, j = 1, i + 2
            while j < len(word) and depth:
                if word[j] == "(":
                    depth += 1
                elif word[j] == ")":
                    depth -= 1
                j += 1
            bodies.append(word[i + 2 : j - 1] if depth == 0 else word[i + 2 :])
            i = j
        elif word[i] == "`":
            j = word.find("`", i + 1)
            bodies.append(word[i + 1 :] if j < 0 else word[i + 1 : j])
            i = len(word) if j < 0 else j + 1
        elif word.startswith("<(", i) or word.startswith(">(", i):
            depth, j = 1, i + 2
            while j < len(word) and depth:
                if word[j] == "(":
                    depth += 1
                elif word[j] == ")":
                    depth -= 1
                j += 1
            bodies.append(word[i + 2 : j - 1] if depth == 0 else word[i + 2 :])
            i = j
        else:
            i += 1
    return bodies


def program_name(word):
    w = word.lstrip("\\`$(")
    return os.path.basename(w)


def skip_options(words, start, with_arg=(), stop_at_first_operand=True):
    """Index of the first operand after options, skipping option arguments."""
    i = start
    while i < len(words):
        w = words[i]
        if w == "--":
            return i + 1
        if w.startswith("-") and w != "-":
            if w in with_arg:
                i += 2
            else:
                i += 1
            continue
        if stop_at_first_operand:
            return i
        i += 1
    return i


def unwrap(words):
    """Removes assignments and wrapper programs; returns the real command words
    and any extra command lists (find -exec bodies)."""
    extra = []
    while words:
        while words and ASSIGNMENT.match(words[0]):
            words = words[1:]
        if not words:
            break
        name = program_name(words[0])
        if name == "env":
            i = 1
            while i < len(words):
                w = words[i]
                if w in ("-u", "--unset", "-C", "--chdir", "-S", "--split-string"):
                    if w in ("-S", "--split-string") and i + 1 < len(words):
                        extra.append(words[i + 1])
                    i += 2
                elif w.startswith("-") or ASSIGNMENT.match(w):
                    i += 1
                else:
                    break
            words = words[i:]
        elif name in ("command", "builtin"):
            if len(words) > 1 and words[1] in ("-v", "-V"):
                return [], extra
            words = words[skip_options(words, 1):]
        elif name == "exec":
            words = words[skip_options(words, 1, with_arg=("-a",)):]
        elif name in ("nice", "ionice", "chrt", "taskset", "unbuffer", "setsid", "flock"):
            words = words[skip_options(words, 1, with_arg=("-n", "-c", "-p", "-w")):]
            if name in ("chrt", "taskset", "flock") and words:
                words = words[1:]
        elif name in ("nohup", "time"):
            words = words[skip_options(words, 1):]
        elif name == "timeout":
            i = skip_options(words, 1, with_arg=("-s", "--signal", "-k", "--kill-after"))
            words = words[i + 1:]
        elif name == "stdbuf":
            words = words[skip_options(words, 1, with_arg=("-i", "-o", "-e")):]
        elif name == "xargs":
            words = words[skip_options(words, 1, with_arg=(
                "-I", "-i", "-n", "-P", "-d", "-E", "-e", "-L", "-l", "-s", "-a", "--arg-file",
                "--delimiter", "--max-args", "--max-procs", "--replace",
            )):]
        elif name == "watch":
            words = words[skip_options(words, 1, with_arg=("-n", "--interval", "-d")):]
        elif name == "ssh":
            i = skip_options(words, 1, with_arg=(
                "-p", "-i", "-l", "-o", "-F", "-J", "-b", "-c", "-D", "-E", "-L", "-R", "-W", "-w", "-m", "-Q", "-S",
            ))
            rest = words[i + 1:]
            if rest:
                extra.append(" ".join(rest))
            return [], extra
        elif name == "systemd-run":
            if "--user" in words:
                i = skip_options(words, 1, with_arg=("-u", "--unit", "-p", "--property", "-E", "--setenv", "-M"))
                words = words[i:]
            else:
                return words, extra
        else:
            break
    return words, extra


def find_exec_bodies(words):
    bodies = []
    for i, w in enumerate(words):
        if w in ("-exec", "-execdir", "-ok", "-okdir"):
            body = []
            for x in words[i + 1:]:
                if x in (";", "+", "\\;"):
                    break
                body.append(x)
            if body:
                bodies.append(body)
    return bodies


def has_recursive_flag(words):
    for w in words[1:]:
        if w == "--":
            break
        if w in ("--recursive",):
            return True
        if w.startswith("-") and not w.startswith("--") and ("r" in w[1:] or "R" in w[1:]):
            return True
    return False


def operands(words):
    out, after = [], False
    for w in words[1:]:
        if after or not (w.startswith("-") and w != "-"):
            out.append(w)
        elif w == "--":
            after = True
    return out


def check_rules(words, targets):
    if not words and not targets:
        return
    for t in targets:
        if BLOCK_DEVICE.match(t):
            raise Deny("domovyk guard: redirect-device: writes to a block device")
    if not words:
        return
    name = program_name(words[0])
    if name in PRIVILEGE or (name == "machinectl" and "shell" in words[1:]) or name == "systemd-run":
        raise Deny(PRIVILEGE_REASON)
    if name == "dd" and any(w.startswith("of=/dev/") for w in words[1:]):
        raise Deny("domovyk guard: dd-device: dd writes to a device")
    if name.startswith("mkfs") or name in MKFS_LIKE:
        raise Deny("domovyk guard: mkfs: formats or repartitions a disk")
    if name == "shred" and any(o.startswith("/dev/") for o in operands(words)):
        raise Deny("domovyk guard: shred-device: shreds a device")
    if name == "rm" and has_recursive_flag(words) and any(protected_target(o) for o in operands(words)):
        raise Deny("domovyk guard: rm-root-or-home: recursive rm on /, a system folder or a home folder")
    if name in ("chmod", "chown", "chgrp") and has_recursive_flag(words):
        ops = operands(words)
        if any(protected_target(o) for o in ops[1:] if ops):
            raise Deny("domovyk guard: chmod-chown-recursive: recursive permission change on / or a home folder")
    if name == "find":
        starts = []
        for w in words[1:]:
            if w.startswith("-") or w in ("(", "!"):
                break
            starts.append(w)
        deletes = "-delete" in words or any(program_name(b[0]) == "rm" for b in find_exec_bodies(words))
        if deletes and any(protected_target(s) for s in starts):
            raise Deny("domovyk guard: find-delete-home: find deletes from / or a home folder")
    if name == "tee" and any(BLOCK_DEVICE.match(o) for o in operands(words)):
        raise Deny("domovyk guard: redirect-device: writes to a block device")


def analyse(command, depth, sink):
    """Appends every normalized simple command to sink; raises Deny."""
    if depth > MAX_DEPTH:
        raise Deny("domovyk guard: command nested too deeply to check")
    if FORK_BOMB.search(command):
        raise Deny("domovyk guard: fork-bomb")
    try:
        tokens = tokenize(command)
    except ValueError:
        raise Deny("domovyk guard could not parse the command")
    for tok in tokens:
        for body in substitutions(tok):
            analyse(body, depth + 1, sink)
    for words, targets in split_simple(tokens):
        words, extra = unwrap(words)
        for text in extra:
            analyse(text, depth + 1, sink)
        check_rules(words, targets)
        if words:
            name = program_name(words[0])
            if name in SHELLS:
                i = 1
                while i < len(words):
                    w = words[i]
                    if w.startswith("-") and not w.startswith("--") and "c" in w[1:]:
                        if i + 1 < len(words):
                            analyse(words[i + 1], depth + 1, sink)
                        break
                    if not w.startswith("-"):
                        break
                    i += 1
            elif name == "eval":
                analyse(" ".join(words[1:]), depth + 1, sink)
            for body in find_exec_bodies(words):
                inner, more = unwrap(body)
                for text in more:
                    analyse(text, depth + 1, sink)
                check_rules(inner, [])
        sink.append((words, targets))


def read_routes():
    """Read-tier routes from the Command_Metadata of the installed Commands."""
    libexec = os.environ.get("DOMOVYK_LIBEXEC") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    commands = os.path.join(libexec, "commands")
    routes = set()
    try:
        names = os.listdir(commands)
    except OSError:
        return routes
    for name in names:
        if not name.startswith("domovyk-"):
            continue
        try:
            with open(os.path.join(commands, name), encoding="utf-8") as f:
                head = [next(f, "") for _ in range(15)]
        except OSError:
            continue
        if any(line.strip() == "# domovyk:tier=read" for line in head):
            routes.add(tuple(name[len("domovyk-"):].split("-")))
    return routes


def investigator_check(sink):
    routes = read_routes()
    reason = "the investigator only runs domovyk read commands"
    seen_domovyk = False
    for words, targets in sink:
        if any(t != "/dev/null" for t in targets):
            raise Deny(reason)
        if not words:
            continue
        name = program_name(words[0])
        if name == "domovyk":
            args = [w for w in words[1:] if not w.startswith("-")]
            if not any(tuple(args[: len(r)]) == r for r in routes):
                raise Deny(reason)
            seen_domovyk = True
        elif name in INVESTIGATOR_FILTERS and seen_domovyk:
            continue
        else:
            raise Deny(reason)


def decide(payload):
    if not isinstance(payload, dict):
        raise Deny("domovyk guard could not parse the command")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        raise Deny("domovyk guard could not parse the command")
    command = tool_input.get("command")
    if not isinstance(command, str):
        raise Deny("domovyk guard could not parse the command")
    sink = []
    analyse(command, 0, sink)
    agent_type = payload.get("agent_type") or ""
    if isinstance(agent_type, str) and agent_type.endswith("domovyk-investigator"):
        investigator_check(sink)


def deny_json(reason):
    return json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    })


def main():
    try:
        payload = json.loads(sys.stdin.read())
        decide(payload)
    except Deny as deny:
        print(deny_json(deny.reason))
    except (ValueError, RecursionError):
        print(deny_json("domovyk guard could not parse the command"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
