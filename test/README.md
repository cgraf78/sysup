# Test suites

`test/run` executes each suite in a new Bash process. The backend suites source
private implementation files and replace package, privilege, and systemd
commands with deterministic fixtures; process isolation prevents one suite's
functions and shell state from reaching another.

- `sysup-test` covers OS detection, family guards, exact argv dispatch, help and
  error behavior, Bash 3.2 constraints, shdeps-style relative and absolute
  symlinks, and the manual installation layout.
- `common-test` covers the shared driver with a fake backend: rejection of
  unknown arguments, the sudo keeper's refresh and shutdown (normal return,
  failed upgrade, revoked credentials, and a parent that dies without
  cleanup), and package-manager lock detection and waits.
- `archup-test` covers package-manager argument policy, AUR membership and
  rebuild decisions, orphan removal, missing-library failures, package
  snapshots, service restarts, persistent deferred-restart reminders, partial
  failures, caller trap preservation, and failed units.
- `debup-test` covers apt/dpkg policy, retries, autoremove, integrity and
  advisory checks, multiarch snapshots, needrestart, check-only behavior,
  partial upgrades, family refusal, service restarts, and failed units.
- `dnfup-test` covers dnf/rpm policy, autoremove and its report, multilib,
  installonly, and signing-key snapshots, image-based and yum-only refusal, partial upgrades, each check, check-only behavior,
  and family refusal.
- `lib/test.sh` provides only the assertions and guarded temporary directories
  these suites need. It is intentionally independent of dotfiles.

Run everything with:

```bash
test/run
```

When ShellCheck is installed, the runner also lints every program listed in
`.github/shellcheck-files.txt`. Shared CI sets `SYSUP_SKIP_SHELLCHECK=1` for the
behavior matrix because a separate required inventory job runs the same lint.

## End to end

The suites above prove sysup agrees with its fixtures, not with the real tools.
`e2e/distro-run IMAGE` closes that gap: `e2e/provision.sh` installs systemd,
sudo, and sysup's tool dependencies into a stock distribution image (without
upgrading anything else), and the runner boots it with systemd as PID 1. It
then runs `sysup --check-only` and a full upgrade as root, a full run as a
non-root user through sudo, and `--check-only` again; every step must exit 0.

```bash
test/e2e/distro-run docker.io/library/debian:stable
SYSUP_E2E_ENGINE=podman test/e2e/distro-run docker.io/library/fedora:latest
```

CI runs it for each supported family in the `distros` job. Some advisory
warnings are expected inside a container, such as needrestart being unable to
determine the running kernel's state.

Fixtures must stay generic and public: synthetic package/unit names, temporary
paths, and distribution defaults only. Never add real hosts, accounts, or
deployment details.
