# sysup

![Tests](https://github.com/cgraf78/sysup/actions/workflows/test.yml/badge.svg?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D4.0-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#)

`sysup` is one command for upgrading Arch, Debian, and Ubuntu systems. It
detects the host family, applies conservative package-manager policy, restarts
services affected by the upgrade, and reports broken package or systemd state
before returning.

```console
$ sysup --check-only
==> held packages (0)
  (none)

==> checking dpkg and apt integrity
ok: dpkg and apt report a consistent package state
```

## Installation

Clone the repository and install a PATH-visible dispatcher plus its private
library tree:

```bash
git clone https://github.com/cgraf78/sysup.git
cd sysup
./install.sh
```

`PREFIX` defaults to `$HOME/.local`. `BIN_DIR` and `LIB_DIR` can override its
`bin` and `lib` children independently. Dependency managers can instead expose
`bin/sysup` from the checkout directly; the launcher follows its own symlink
back to the matching `lib/sysup` tree. For example, a shdeps entry is:

```text
cgraf78/sysup  github
```

Only `sysup` is a public command. The Arch and Debian implementations live
under `lib/sysup` so their shared sequencing and package policy always update
with the dispatcher.

## Usage

```text
sysup [backend args...]
```

Common options:

- `--check-only` skips package changes and service restarts while running the
  verification checks;
- `--no-restart-upgraded-services` leaves affected active services running;
- `--restart-failed` restarts failed enabled systemd units after checks;
- `-h` or `--help` prints the options for the detected host; and
- `--` sends every remaining argument to the selected package manager.

### Arch

The Arch backend reports foreign packages, upgrades with `yay -Syu --devel`
when available or `pacman -Syu` otherwise, and scans foreign-package ELF files
for missing shared libraries. Broken AUR packages are rebuilt and their active
services are restarted even when the rebuilt package version is unchanged.

Package operations are noninteractive by default. Pass `--confirm` after `--`
to restore package-manager prompts.

### Debian and Ubuntu

The Debian backend runs `apt-get update`, then
`apt-get --with-new-pkgs upgrade -y`. This permits new dependencies without
removing installed packages. `--full-upgrade` permits dependency-driven
removals, while `--autoremove` opts into purging packages no longer required.
Neither option performs a release upgrade or edits APT sources.

It keeps locally modified conffiles, retries transient package-index failures,
checks dpkg and apt integrity, reports pending conffile merges and reboot state,
and prefers `needrestart` when it is installed.

## Failure and restart policy

`sysup` snapshots package versions before and after mutation. Once a package
manager starts, later checks still run after a failure because a partially
applied upgrade may already require service restarts. The original package
manager status retains precedence, while independent check and restart
failures are also surfaced instead of short-circuiting one another.

Only active units owned by packages proven to have changed are restarted.
Missing systemd is a supported no-op; an unreachable or failed systemd query is
an error rather than being mistaken for a healthy empty result.

See [`docs/design.md`](docs/design.md) for the hook contract and detailed run
ordering.

## Requirements

Upgrading a supported host requires Bash 4 or newer, `sudo` when not already
root, and the host's normal package tools. The Arch path additionally uses
`file`, `ldd`, and `sort`; `yay` is optional. The Debian path uses `apt-get`,
`apt-mark`, `dpkg`, `dpkg-query`, `find`, and `sort`; `needrestart` is optional.
systemd integration is used when `systemctl` is available.

The dispatcher and OS detection remain compatible with Bash 3.2 so an
unsupported macOS host can still run `sysup --help` and receive a clear
diagnostic instead of a shell-version failure.

## Development

Run the complete behavior and ShellCheck suite with:

```bash
test/run
```

The tests use command fixtures and temporary OS roots; they never invoke the
live package manager. See [`test/README.md`](test/README.md) for suite ownership
and [`lib/sysup/README.md`](lib/sysup/README.md) for the private backend
boundary.

## License

MIT. See [`LICENSE`](LICENSE).
