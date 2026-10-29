# Unified System Updater (`sysup`) Design

## Problem

Arch, Debian-family, and Fedora-family package managers expose different upgrade and recovery
semantics, but operators need one command whose checks, service restarts, and
failure reporting remain consistent across supported hosts.

## Goals

- A Debian/Ubuntu upgrade helper, `debup`, with post-upgrade checks equivalent
  in spirit to `archup`'s.
- A Fedora/RHEL upgrade helper, `dnfup`, built on the same contract.
- A `sysup` front door that detects the OS family and runs the right backend.
- One authoritative copy of the logic every backend shares, rather than a second
  copy of `archup`'s systemd and snapshot handling.

## Non-goals

- Cross-release OS upgrades. `debup` never edits APT sources and never invokes
  `do-release-upgrade`; `dnfup` never runs `dnf system-upgrade`.
- openSUSE. It is RPM-based but upgrades through `zypper`, and Tumbleweed and
  Leap need different verbs; it would be its own family, not part of `dnfup`.
- Distributions without systemd (Alpine, Void, Gentoo with OpenRC). The shared
  restart and failed-unit handling is systemd-only, so they need a service
  layer of their own first.
- macOS/Homebrew support. `sysup` errors clearly on unsupported families; a
  `brewup` backend can be added later without changing the contract.
- Remote execution. `sysup` upgrades the host it runs on.

## Architecture

```text
bin/sysup                public dispatcher: detect family -> exec backend
lib/sysup/
  archup       private Arch backend
  debup        private Debian backend
  dnfup        private Fedora/RHEL backend
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
| `sysup_backend_parse_arg <arg>` | unhandled (sysup rejects the argument with status 2) | `debup` adds `--full-upgrade` |
| `sysup_backend_preamble` | no-op | `archup` lists foreign packages; `debup` lists held packages |
| `sysup_backend_autoremove_safe <args...>` | allow no forwarded arguments | `archup` also allows `--confirm` and `--noconfirm` |
| `sysup_backend_autoremove <apply\|report>` | no-op | `archup` removes `pacman -Qdtq` orphans; `debup` runs `apt-get --purge autoremove`; `dnfup` runs `dnf autoremove -y` and reports `dnf repoquery --unneeded` |
| `sysup_backend_checks` | no-op | family-specific post-upgrade verification |
| `sysup_backend_check_service_restart <unit>` | allow every restart | `archup` defers `nvidia-persistenced` while the loaded NVIDIA driver differs from the installed one, and reports it unverified when either version cannot be read |
| `sysup_backend_restart_services <pkg...>` | shared systemd restart | `debup` prefers `needrestart` |

`sysup_backend_check_service_restart` returns 0 to allow a restart, 1 to defer
it, or another status to mark service restarts unverified, which fails the run.
Only the shared upgraded-service restart path consults it; `needrestart`
restarts and `--restart-failed` do not. Session-critical units are deferred by
the shared path itself, before this hook runs, so a backend cannot re-enable
them.

Backends set `SYSUP_BACKEND_NAME` for user-facing messages and may append to
`SYSUP_EXTRA_UPGRADED_PACKAGES` for packages a version diff cannot detect
(`archup` rebuilds AUR packages at an unchanged version).

Hooks take single-token flags only. A flag needing its own argument would
require extending the parser contract.

### Run sequence

1. Parse shared flags. Arguments after `--` go to the package manager; any
   other argument the backend does not claim is rejected with status 2
   before anything runs, so a mistyped option cannot reach the package
   manager.
2. `sysup_backend_require`, then `sysup_backend_preamble`.
3. Unless `--check-only`: snapshot packages, warm `sudo`, upgrade, remove
   unused packages, snapshot again, and diff to get the upgraded set.
   Warming first probes `sudo -n -k true`; when sudo needs no password it
   skips both the prompt and the keeper, since `sudo -v` prompts under the
   default `verifypw=all` unless every matching sudoers rule is NOPASSWD
   (stock openSUSE also grants `ALL ALL=(ALL) ALL`). Otherwise, once
   `sudo` is warm, a background keeper refreshes it every
   `SYSUP_SUDO_REFRESH` seconds (default 60; 0 disables) until the run
   returns, so a long upgrade cannot leave the later steps at a password
   prompt. `sysup_main` stops and reaps it on every return path; it also
   exits on its own within one interval if the run dies without cleanup or
   `sudo -n -v` is refused.
   `sysup_backend_autoremove apply` runs only after a clean upgrade: after a
   partial failure the dependency graph may be mid-transition, so removal is
   skipped with a note. `--no-autoremove` calls it with `report` instead. It
   precedes the second snapshot so a package upgraded and then removed drops
   out of the diff rather than reaching the restart step, which could no
   longer list its files. Its failure fails the run without skipping later
   steps. Custom package-manager arguments skip cleanup because they can
   select non-install modes or another package database; only Arch confirmation
   flags are safe to share with removal.
4. `sysup_backend_checks`.
5. Restart affected services unless `--no-restart-upgraded-services`. The
   shared fallback maps upgraded package files to active units; Debian instead
   prefers `needrestart`'s runtime deleted-file analysis when available, which
   can include services owned by other packages. The shared fallback defers
   session-critical units (`sysup_session_critical_unit`: per-user managers
   and their runtime directories, gettys, display managers, logind, D-Bus,
   rescue shells) before consulting systemd or the backend, because template
   expansion would otherwise restart the running `user@UID` or `getty@tty`
   instances and end the operator's session. The list starts from the
   session-related entries in `needrestart`'s default `override_rc`, with its
   open-ended prefixes anchored to exact unit names. Deferred units are listed
   with a hint to restart them manually or reboot, and do not fail the run.
6. With `--restart-failed`, restart failed enabled units.
7. Repeat the deferred-restart reminder (below).
8. Report failed systemd units.

Steps 4 through 8 each run rather than short-circuiting, and every one except
the advisory reminder in step 7 contributes to the exit status, so one run
surfaces every problem.

Once the package-manager command starts, those follow-up steps also run after a
failure: an upgrade can install some packages before returning nonzero. The
driver re-snapshots best-effort, restarts services for anything it can prove
changed, reports unverified discovery explicitly, and preserves the original
package-manager status.

### Lock waits

`sysup_wait_path_free PATH TIMEOUT WHAT` waits, polling every
`SYSUP_LOCK_POLL` seconds, until no process has a package-manager lock file
open. Holders are found through `/proc/<pid>/fd` links (read as root), not
`/proc/locks`: the latter names files by device and inode, and on btrfs
`stat()` reports a per-subvolume device that never matches it. Backends can use it
where the package manager itself fails at once on a held lock.

### Deferred restarts

A deferral is reported once by the run that upgraded the package, which is
easy to miss on an unattended host, so the shared path also records it in
`/var/lib/sysup/deferred-restarts` (`SYSUP_STATE_DIR`). The record is
host-wide and root-owned (directory `0755`, file `0644`, written through
`sudo` like the restarts themselves and replaced by an atomic rename), because
sysup runs both as the operator and as root and each run must see the same
record. Each line holds the kernel `boot_id`, the unit, and the unit's
`ActiveEnterTimestampMonotonic` at deferral time. `user-runtime-dir@` is
deferred but not recorded: it is a oneshot with no code left running.

Every run reads the record, including `--check-only`, and prints one
`reboot recommended: ...` line on stderr while any entry still applies. An
entry is spent once `boot_id` changes, the unit is inactive or failed (stopped
or removed), or its activation timestamp changes (restarted manually).
Transient states such as `reloading` still count as running. When
the boot or the unit cannot be checked the entry is kept, trading a redundant
reminder for never dropping one silently. Only mutating runs prune spent
entries or remove the file; `--check-only` never writes. The reminder is
advisory, matching debup's reboot-required report, and a failure to record it
is a warning rather than a failed run, and an unreadable record is never
overwritten. Concurrent sysup runs could race on the rename; package-manager
locks make overlapping upgrade runs unlikely, and the loser only warns.

## Detection

`sysup_os_family` maps os-release `ID`, then each `ID_LIKE` token, to a family.
It reads `/etc/os-release`, falling back to `/usr/lib/os-release` as
os-release(5) specifies. A per-family marker file under `/etc`
(`/etc/arch-release`, `/etc/debian_version`) is the fallback for derivatives
with an unhelpful `os-release`.

`_sysup_family_table` is the single family table. Each row holds the family,
its backend command, a human label, the os-release IDs that select it, and its
marker file, so adding a family is one row plus its backend. Detection,
`sysup_family_command`, `sysup_family_label`, and the dispatcher's `--help`
routes all read it.

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
- `apt-get --purge autoremove -y`, through the shared autoremove step above;
  `--no-autoremove` reports the `--simulate` candidates instead.

Conffiles use `--force-confdef --force-confold`, so a package never silently
replaces a locally modified config file. `NEEDRESTART_MODE=l` keeps
`needrestart`'s APT hook from prompting mid-upgrade; `debup` drives the restart
itself afterward with `needrestart -r a` under the noninteractive debconf
frontend, so its kernel and microcode pending-reboot notices print instead of
waiting for a keypress on a terminal.

The package snapshot keeps rows whose dpkg desired state is install (`i`) or
hold (`h`) and whose current state is not `n` (not installed) or `c` (config
files only). A held package is still installed and can be upgraded on explicit
request, so leaving it out would hide that upgrade from the restart step.

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

## `dnfup` behavior

The `fedora` family matches os-release `fedora`, `rhel`, and `centos`, so
Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux, and Amazon Linux
2023 all select it, with `/etc/redhat-release` as the marker fallback.
`dnfup` then refuses two kinds of host before touching dnf:

- Image-based hosts (`/run/ostree-booted`: Fedora Atomic desktops, CoreOS,
  image-mode RHEL), where dnf cannot change the read-only root. The error
  names `rpm-ostree upgrade` and `bootc upgrade`.
- yum-only releases (RHEL/CentOS 7, Amazon Linux 2), with an error that says
  so instead of a bare missing-command report.

Upgrade, as root:

- `dnf upgrade --refresh -y`, forwarding extra arguments. dnf never prompts
  about config files; it writes `.rpmnew`/`.rpmsave` instead, which the checks
  report. Fedora's default `best=False` lets dnf skip a package whose
  dependencies cannot be met and still exit 0; RHEL's `best=True` fails
  instead.
- `dnf autoremove -y`, through the shared autoremove step. It removes packages
  whose recorded install reason is "dependency"; `installonly_limit` does not
  apply. `protect_running_kernel` makes the transaction fail rather than skip
  the running kernel, so a wrongly recorded kernel surfaces as a failed
  cleanup. `--no-autoremove` reports `dnf repoquery --unneeded` instead.

The snapshot keys packages by `NAME.ARCH` with `EPOCHNUM:VERSION-RELEASE`, so
both arches of a multilib library stay distinct and an epoch-only bump counts
as an upgrade; `rpm -ql` accepts the same `NAME.ARCH` form. Installonly
packages (`kernel`, `kernel-core`, ...) keep several versions under one
`NAME.ARCH`, and the driver's diff keys on the name, so each is one row of
comma-joined versions: an unchanged kernel set compares equal, and an added
or removed kernel registers as a change. `gpg-pubkey` entries (architecture
`(none)`) are signing keys rather than packages and are dropped: importing a
key during an upgrade would otherwise look like an upgraded package whose
files cannot be listed.

Service restarts use the shared package-diff path, like `archup`.

Checks, using commands available under both dnf4 and dnf5:

| Check | Severity |
| --- | --- |
| `dnf check`: unsatisfied dependencies, duplicates, obsoleted packages | fatal |
| Reboot required (`dnf needs-restarting -r`, when the plugin is installed) | advisory |
| Pending config merges (`.rpmnew`/`.rpmsave`/`.rpmorig` under `/etc`) | advisory |
| Failed systemd units | fatal |

`dnf check` is preferred over `rpm -Va --nofiles` because it also reports
duplicate packages, the usual remains of an interrupted transaction.

`check`, `needs-restarting`, and `repoquery --unneeded` run with
`--disablerepo='*'`. dnf otherwise loads every enabled repository first, and a
load failure (offline host, expired cache) exits 1, which `needs-restarting -r`
also uses for "reboot needed". The cost is on dnf5: without repositories its
`needs-restarting` checks only its built-in core-package list, not the
`reboot_suggested` flags in repository advisories, so the "ok" message says
advisories were not consulted. dnf4's check uses only the rpmdb. For the same
reason `dnfup` probes `needs-restarting --help` first, since dnf exits 1 for
an unknown command too, and reports reboot state as unknown when the plugin
is missing rather than claiming a reboot.

Not yet handled: dnf5 fails at once when another process (`dnf-automatic`,
PackageKit) holds the rpm transaction lock, where dnf4 waits; and versionlocked
or excluded packages are not listed the way `debup` lists held packages.

## Testing

- `common-test` drives the shared driver with a fake backend: argument
  rejection, the sudo keeper's lifecycle, and lock waits.
- `archup-test` covers the extracted shared hooks, AUR decisions, orphan
  removal, library scanning, package diffs, service restarts, and partial
  failures.
- `debup-test` mocks `apt-get`, `dpkg`, `dpkg-query`, and `systemctl` to cover
  the upgrade verb, default autoremove and its opt-out, each check, and
  `needrestart` preference.
- `dnfup-test` mocks `dnf`, `rpm`, and `systemctl` to cover the upgrade and
  autoremove policy, multilib, installonly, and signing-key snapshots, each
  check, and the image-based, yum-only, and family guards.
- `test/e2e/distro-run` boots a stock image of each supported family with
  systemd as PID 1 and runs the real `sysup` (check-only, upgrade as root,
  upgrade through sudo, check-only again) against the real package manager.
  It is the only test that does not mock them, and CI runs it per family.
- `sysup-test` covers family detection from fixture `os-release` files,
  symlink-aware dispatch to the private backend, exact argument forwarding,
  portability constraints, and the installation layout.
