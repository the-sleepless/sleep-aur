# Security policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please report security issues privately through GitHub Security Advisories:

<https://github.com/the-sleepless/sleep-aur/security/advisories/new>

Do not open a public issue for a vulnerability. Include:

- the affected version (`sleep-aur self version`);
- a description of the issue and its impact;
- reproduction steps or a proof of concept;
- any suggested fix, if you have one.

## Scope

Reports are especially welcome for:

- privilege handling in `installer.sh` and `src/lib/core.sh`;
- temporary directory and file handling;
- package name validation and command construction;
- dependency resolution and `PKGBUILD` execution;
- checksum verification for releases and self-updates;
- path traversal or unintended file overwrites.

General questions and feature requests should use the public issue tracker.
