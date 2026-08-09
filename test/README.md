# Test suites

`test/run` executes each suite in a new Bash process. The backend suites source
private implementation files and replace package, privilege, and systemd
commands with deterministic fixtures; process isolation prevents one suite's
functions and shell state from reaching another.

- `sysup-test` covers OS detection, family guards, exact argv dispatch, help and
  error behavior, Bash 3.2 constraints, shdeps-style relative and absolute
  symlinks, and the manual installation layout.
- `archup-test` covers package-manager argument policy, AUR membership and
  rebuild decisions, missing-library failures, package snapshots, service
  restarts, partial failures, caller trap preservation, and failed units.
- `debup-test` covers apt/dpkg policy, retries, autoremove, integrity and
  advisory checks, multiarch snapshots, needrestart, check-only behavior,
  partial upgrades, family refusal, service restarts, and failed units.
- `lib/test.sh` provides only the assertions and guarded temporary directories
  these suites need. It is intentionally independent of dotfiles.

Run everything with:

```bash
test/run
```

When ShellCheck is installed, the runner also lints every program listed in
`.github/shellcheck-files.txt`. Shared CI sets `SYSUP_SKIP_SHELLCHECK=1` for the
behavior matrix because a separate required inventory job runs the same lint.

Fixtures must stay generic and public: synthetic package/unit names, temporary
paths, and distribution defaults only. Never add real hosts, accounts, or
deployment details.
