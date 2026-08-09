# Unified System Updater (`sysup`) Design

## Problem

Arch and Debian-family package managers expose different upgrade and recovery
semantics, but operators need one command whose checks, service restarts, and
failure reporting remain consistent across supported hosts.

## Goals

- A Debian/Ubuntu upgrade helper, `debup`, with post-upgrade checks equivalent
  in spirit to `archup`'s.
- A `sysup` front door that detects the OS family and runs the right backend.
- One authoritative copy of the logic both backends share, rather than a second
  copy of `archup`'s systemd and snapshot handling.

## Non-goals

- Cross-release OS upgrades. `debup` never edits APT sources and never invokes
  `do-release-upgrade`.
- macOS/Homebrew support. `sysup` errors clearly on unsupported families; a
  `brewup` backend can be added later without changing the contract.
- Remote execution. `sysup` upgrades the host it runs on.

## Architecture

```text
bin/sysup                public dispatcher: detect family -> exec backend
lib/sysup/
  archup       private Arch backend
  debup        private Debian backend
  detect.sh    OS family vocabulary and detection
  common.sh    logging, privilege, package-diff, and the shared run driver
  systemd.sh   failed units and service restarts for upgraded packages
```

`common.sh` owns the run orchestration. Each backend supplies hook functions and
then calls `sysup_main "$@"`. This keeps the ordering guarantees (snapshot before
upgrade, diff after, checks before restarts, failed-unit report last) in one
place, so a fix to that sequence applies to every family.

### Backend contract

Required hooks:

| Hook | Responsibility |
| --- | --- |
| `sysup_backend_require` | Verify the host family and required commands |
| `sysup_backend_snapshot` | Print `<package> <version>` lines, sorted |
| `sysup_backend_package_files <pkg>` | Print the files a package owns |
| `sysup_backend_upgrade [args...]` | Perform the upgrade |
| `sysup_backend_usage` | Print `--help` text |

Optional hooks, with defaults in `common.sh`:

| Hook | Default | Override |
| --- | --- | --- |
| `sysup_backend_parse_arg <arg>` | unhandled (arg falls through to the package manager) | `debup` adds `--autoremove`, `--full-upgrade` |
| `sysup_backend_preamble` | no-op | `archup` lists foreign packages; `debup` lists held packages |
| `sysup_backend_checks` | no-op | family-specific post-upgrade verification |
| `sysup_backend_restart_services <pkg...>` | shared systemd restart | `debup` prefers `needrestart` |

Backends set `SYSUP_BACKEND_NAME` for user-facing messages and may append to
`SYSUP_EXTRA_UPGRADED_PACKAGES` for packages a version diff cannot detect
(`archup` rebuilds AUR packages at an unchanged version).

Hooks take single-token flags only. A flag needing its own argument would
require extending the parser contract.

### Run sequence

1. Parse shared flags; unrecognized arguments pass through to the package
   manager.
2. `sysup_backend_require`, then `sysup_backend_preamble`.
3. Unless `--check-only`: snapshot packages, warm `sudo`, upgrade, snapshot
   again, and diff to get the upgraded set.
4. `sysup_backend_checks`.
5. Restart affected services unless `--no-restart-upgraded-services`. The
   shared fallback maps upgraded package files to active units; Debian instead
   prefers `needrestart`'s runtime deleted-file analysis when available, which
   can include services owned by other packages.
6. With `--restart-failed`, restart failed enabled units.
7. Report failed systemd units.

Steps 4 through 7 each contribute to the exit status rather than short-circuiting,
so one run surfaces every problem.

Once the package-manager command starts, those follow-up steps also run after a
failure: an upgrade can install some packages before returning nonzero. The
driver re-snapshots best-effort, restarts services for anything it can prove
changed, reports unverified discovery explicitly, and preserves the original
package-manager status.

## Detection

`sysup_os_family` maps `/etc/os-release` `ID`, then each `ID_LIKE` token, to a
family. `/etc/arch-release` and `/etc/debian_version` are fallbacks for
derivatives with an unhelpful `os-release`. `_sysup_family_table` is the single
family table; `sysup_family_command` and `sysup_family_label` expose it to both
the dispatcher and the per-backend family guard.

`sysup` follows its own portable symlink chain and resolves the backend from the
provider's `lib/sysup` directory, never through `PATH`. A shdeps link, manual
install, or worktree invocation therefore dispatches within one coherent
checkout.

## `debup` behavior

Upgrade, as root, with `DEBIAN_FRONTEND=noninteractive`:

- `apt-get update`, retried on failure
- `apt-get --with-new-pkgs upgrade -y` — installs new dependencies so kernel ABI
  bumps land, but never removes a package. `--full-upgrade` opts into
  `full-upgrade`, which permits removals to resolve dependencies. Neither crosses
  an OS release.
- `apt-get autoclean -y`, advisory — a failure to reclaim the cache must not
  cancel the checks and restarts that make the upgrade safe.
- `autoremove` reports candidates only; `--autoremove` performs it with `--purge`.

Conffiles use `--force-confdef --force-confold`, so a package never silently
replaces a locally modified config file. `NEEDRESTART_MODE=l` keeps
`needrestart`'s APT hook from prompting mid-upgrade; `debup` drives the restart
itself afterward.

`DPkg::Lock::Timeout` covers only the two dpkg locks, not the lists lock that
`apt-get update` takes (Debian #1012173), so `update` gets its own bounded retry.
`unattended-upgrades` routinely holds that lock on Debian-family hosts, and a collision
must not abort the run. Note that `unattended-upgrades` itself is python-apt and
does not run `apt-get`; the verb above is equivalent in effect, not identical in
implementation.

`--check-only` must not mutate the host, and the driver enforces that centrally
by skipping the restart step entirely. A backend cannot be trusted to infer it
from an empty package list: `debup` defers to `needrestart`, which discovers work
on its own.

Checks:

| Check | Severity |
| --- | --- |
| `dpkg --audit` and `apt-get check` | fatal |
| Reboot required (`needrestart -b -k`, falling back to `/var/run/reboot-required`) | advisory |
| Pending conffiles (`.dpkg-dist`/`.dpkg-new`/`.ucf-dist` under `/etc`) | advisory |
| Failed systemd units | fatal |

## Testing

- `archup-test` covers the extracted shared hooks, AUR decisions, library
  scanning, package diffs, service restarts, and partial failures.
- `debup-test` mocks `apt-get`, `dpkg`, `dpkg-query`, and `systemctl` to cover
  the upgrade verb, autoremove opt-in, each check, and `needrestart` preference.
- `sysup-test` covers family detection from fixture `os-release` files,
  symlink-aware dispatch to the private backend, exact argument forwarding,
  portability constraints, and the installation layout.
