# Private sysup implementation

This directory owns both package-manager backends and the policy they share.
Only `bin/sysup` is a stable command surface; files and function names here are
implementation details that may change together.

- `archup` supplies Arch, pacman, yay, AUR rebuild, and missing-library policy.
- `debup` supplies Debian/Ubuntu, apt, dpkg, conffile, reboot, and needrestart
  policy.
- `common.sh` parses shared flags and owns the upgrade/check/restart ordering.
- `detect.sh` defines the supported-family vocabulary and family guards.
- `systemd.sh` discovers affected active units and handles failed units.

The driver snapshots package versions before mutation and compares a second
snapshot afterward. Backends implement small hooks for requirements, package
enumeration, upgrade, checks, and usage text. Centralizing orchestration is a
safety property: partial package-manager failures still reach verification and
best-effort service restart, while the original failure status remains final.

`archup` and `debup` are executable because the dispatcher replaces itself with
the selected backend. They intentionally do not live in `bin/`; publishing them
as separate commands would create extra user-facing APIs and make independent
installation/version skew possible.

See [`../../docs/design.md`](../../docs/design.md) for the complete hook and
status contract.
