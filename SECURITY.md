# Security policy

Domovyk gives an AI agent information about a computer and a way to propose
changes to it. Its safety features are part of what it promises:

- **read commands change nothing**;
- **the agent never gets root**: the guard hook blocks `sudo`, `pkexec` and
  destructive commands;
- **every system change is a script the user reads and runs**;
- **secrets are redacted** before output reaches the model.

A way around any of these is a security issue.

## Reporting a vulnerability

Please report it privately through GitHub:
**[Report a vulnerability](https://github.com/digitwolf/domovyk/security/advisories/new)**
(the *Security* tab, then *Report a vulnerability*).

Include:
- what you did;
- what you expected;
- what happened;
- the output of `domovyk version`.

For a guard bypass, the exact command string is enough. For a redaction miss,
use a fake secret that has the same shape as the real one.

Please don't open a public issue or pull request for a vulnerability before a
fix is released.

## What to expect

This is a volunteer project, so these are goals, not guarantees:
- an acknowledgement within a week;
- a fix or mitigation as soon as practical;
- a public advisory that credits you, unless you prefer otherwise.

## Supported versions

Until 1.0, only the latest release and `main` receive security fixes.
