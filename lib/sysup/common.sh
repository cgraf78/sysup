# shellcheck shell=bash
# Shared plumbing and run driver for the sysup updaters.
#
# Backends source this file, define the `sysup_backend_*` hooks documented
# below, and call `sysup_main "$@"`. Keeping the run sequence here means the
# ordering guarantees that make an upgrade safe -- snapshot before upgrading,
# diff after, check before restarting, report failed units last -- hold for
# every OS family.

_sysup_common_dir() {
  local src="${BASH_SOURCE[0]}"
  (cd "$(dirname "$src")" >/dev/null 2>&1 && pwd -P)
}
_SYSUP_LIB_DIR="${_SYSUP_LIB_DIR:-$(_sysup_common_dir)}"

# shellcheck source=detect.sh
. "$_SYSUP_LIB_DIR/detect.sh"
# shellcheck source=systemd.sh
. "$_SYSUP_LIB_DIR/systemd.sh"

# Packages a version diff cannot detect. `archup` rebuilds AUR packages whose
# version does not change, and those still need their services restarted.
SYSUP_EXTRA_UPGRADED_PACKAGES=()

sysup_log() {
  printf '\n==> %s\n' "$*"
}

sysup_need_cmds() {
  local missing=() cmd

  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if ((${#missing[@]})); then
    printf 'error: missing required command(s): %s\n' "${missing[*]}" >&2
    return 1
  fi
}

sysup_run_as_root() {
  if ((EUID == 0)); then
    "$@"
    return
  fi

  sysup_need_cmds sudo || return
  sudo "$@"
}

# Run a read-only advisory scan as root when that needs no password prompt (a
# root run, a cached credential, or NOPASSWD), and as the invoking user
# otherwise. Root-only directories under /etc (sudoers.d, ssl/private) hide
# pending config merges from an unprivileged scan, but a --check-only run never
# warms sudo, and prompting for an advisory report would make an unattended
# check hang. An unprivileged `find` reports what it cannot read through its
# exit status, which callers surface as an incomplete scan; pacdiff cannot.
sysup_scan_as_root() {
  if ((EUID != 0)) && command -v sudo >/dev/null 2>&1 &&
    sudo -n true 2>/dev/null; then
    sudo -n "$@"
    return
  fi
  "$@"
}

# Set once sudo has been shown to need no password, so there is no credential
# to keep warm.
_SYSUP_SUDO_PASSWORDLESS=0

# Prompt for sudo once up front so a long upgrade does not stall on a password
# prompt buried in package manager output.
#
# Skip the prompt when sudo needs no password at all. `sudo -v` is the wrong
# probe for that: under the default verifypw=all it asks for a password unless
# every sudoers rule matching the user is NOPASSWD, so a user with a NOPASSWD
# rule alongside a password rule (stock openSUSE ships `ALL ALL=(ALL) ALL`) is
# prompted although no command they run needs it. `-k` makes this one probe
# ignore a cached credential, so a recent `sudo` cannot pass for NOPASSWD and
# leave a run to outlive its timestamp unrefreshed.
sysup_warm_sudo() {
  _SYSUP_SUDO_PASSWORDLESS=0
  ((EUID != 0)) || return 0

  sysup_need_cmds sudo || return
  if sudo -n -k true 2>/dev/null; then
    _SYSUP_SUDO_PASSWORDLESS=1
    return 0
  fi
  sudo -v
}

# Seconds between sudo credential refreshes while a run is in progress; 0
# disables them. Warming sudo once is not enough: a long upgrade or AUR build
# can outlast sudo's timestamp_timeout, and the cleanup and restart steps that
# follow would then stop at a password prompt halfway through the run.
SYSUP_SUDO_REFRESH="${SYSUP_SUDO_REFRESH:-60}"
_SYSUP_SUDO_KEEPER_PID=""

# Start a background loop that refreshes the cached sudo credential until
# sysup_stop_sudo_keeper runs or this shell exits.
#
# The keeper owns exactly one child, its current sleep, and kills it when it
# is told to stop, so stopping leaves no process behind. It also exits on its
# own once the parent shell is gone (checked every interval) or sudo refuses a
# noninteractive refresh, so a run killed without cleanup cannot leave it
# looping. No trap is installed in the caller: backends are sourceable, and
# clobbering a caller's trap is worse than that bounded lag.
sysup_start_sudo_keeper() {
  local parent="$BASHPID"

  ((EUID != 0)) || return 0
  [[ "$SYSUP_SUDO_REFRESH" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  [[ ! "$SYSUP_SUDO_REFRESH" =~ ^0+([.]0+)?$ ]] || return 0
  [[ -z "$_SYSUP_SUDO_KEEPER_PID" ]] || return 0
  ((_SYSUP_SUDO_PASSWORDLESS == 0)) || return 0

  (
    sleeper=""
    trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' TERM
    while :; do
      sleep "$SYSUP_SUDO_REFRESH" &
      sleeper=$!
      wait "$sleeper" || true
      kill -0 "$parent" 2>/dev/null || exit 0
      sudo -n -v 2>/dev/null || exit 0
    done
  ) </dev/null >/dev/null 2>&1 &
  _SYSUP_SUDO_KEEPER_PID=$!
}

# Stop the keeper and reap it. Idempotent, and safe when none was started.
sysup_stop_sudo_keeper() {
  local pid="$_SYSUP_SUDO_KEEPER_PID" tries

  [[ -n "$pid" ]] || return 0
  _SYSUP_SUDO_KEEPER_PID=""
  kill -TERM "$pid" 2>/dev/null || true
  # The keeper runs its TERM trap only between commands, so a refresh stuck
  # in sudo (a slow PAM or directory lookup) would hold it there. Give it
  # about five seconds, then kill it, rather than hang the end of the run.
  for ((tries = 0; tries < 50; tries++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Root of the process table that lock detection reads. Overridable so tests can
# use a fixture tree instead of the live system.
SYSUP_PROC_ROOT="${SYSUP_PROC_ROOT:-/proc}"

# Return 0 when some process has `path` open, 1 otherwise.
#
# Package-manager lock files are opened only to take the lock, so an open
# descriptor is the holder. This reads /proc/<pid>/fd links rather than
# /proc/locks because those compare paths: /proc/locks names files by
# device and inode, and on btrfs (the Fedora and openSUSE default) stat()
# reports a per-subvolume device that never matches it. Other processes'
# descriptors need root to read, and so does listing them where /proc is
# mounted hidepid, so root does the whole walk. When the scan cannot run, this
# reports the file free, and the package manager's own lock error is what the
# operator sees.
sysup_path_in_use() {
  local path="$1" root="$SYSUP_PROC_ROOT" match=""
  local -a runner=()

  # Never prompt: this polls, and a password prompt in the middle of a lock
  # wait would stall it. Without cached credentials the scan simply fails.
  ((EUID == 0)) || runner=(sudo -n)
  # Descend only into <pid>/fd; prune every other second-level directory
  # (task, net, ...) so the walk stays proportional to the process count.
  match=$(${runner[@]+"${runner[@]}"} find "$root" -mindepth 1 -maxdepth 3 \
    \( -path "$root/*/*" ! -path "$root/[0-9]*/fd" \
    ! -path "$root/[0-9]*/fd/*" -prune \) \
    -o -path "$root/[0-9]*/fd/*" -lname "$path" -print -quit \
    2>/dev/null) || true
  [[ -n "$match" ]]
}

# Seconds between checks while waiting for a lock. Overridable for tests.
SYSUP_LOCK_POLL="${SYSUP_LOCK_POLL:-5}"

# Wait up to `timeout` whole seconds for no process to hold `path`. `what`
# names the lock in the one message printed when a wait begins. `held`, a
# command given the path, decides whether it is still held, for a package
# manager whose lock file stays open after the lock is released; it defaults
# to sysup_path_in_use. Returns 0 once it is free and 1 if it is still held at
# the deadline. The deadline uses bash's SECONDS clock so the poll interval may
# be fractional.
sysup_wait_path_free() {
  local path="$1" timeout="$2" what="$3" held="${4:-sysup_path_in_use}" deadline

  "$held" "$path" || return 0
  printf 'waiting up to %ss for %s, held by another process\n' "$timeout" "$what" >&2
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    sleep "$SYSUP_LOCK_POLL"
    "$held" "$path" || return 0
  done
  printf 'error: %s is still held after %ss\n' "$what" "$timeout" >&2
  return 1
}

# Print packages present in both snapshots whose version changed. Packages that
# only appear in the newer snapshot are new installs, not upgrades, and have no
# previously running service to restart.
sysup_changed_packages() {
  local before="$1" after="$2"
  local pkg version
  declare -A before_versions=()

  while read -r pkg version _; do
    [[ -n "${pkg:-}" ]] || continue
    before_versions["$pkg"]="$version"
  done <"$before"

  while read -r pkg version _; do
    [[ -n "${pkg:-}" ]] || continue
    [[ -n "${before_versions[$pkg]+set}" ]] || continue
    [[ "${before_versions[$pkg]}" != "$version" ]] || continue
    printf '%s\n' "$pkg"
  done <"$after"
}

# Print the packages among "$2..." that the snapshot file "$1" still lists.
#
# Backend-reported extras (archup's same-version AUR rebuilds) bypass the
# version diff, so a rebuilt package that autoremove then removed would
# otherwise reach the restart step, which can no longer list its files.
sysup_snapshot_members() {
  local snapshot="$1" pkg
  shift
  declare -A present=()

  while read -r pkg _; do
    [[ -n "${pkg:-}" ]] && present["$pkg"]=1
  done <"$snapshot"

  for pkg in "$@"; do
    [[ -n "${present[$pkg]+set}" ]] && printf '%s\n' "$pkg"
  done
  return 0
}

# Print the unique, non-empty package names among the arguments.
#
# An empty result is a success, not a failure: "nothing was upgraded" is the
# normal outcome of a run with no pending updates, and the caller checks this
# status. Collect into an array rather than filtering inside a pipeline, so an
# all-empty argument list cannot leave a failed test as the pipeline's status
# under `set -o pipefail`.
sysup_unique_packages() {
  local pkg
  local -a names=()

  for pkg in "$@"; do
    [[ -n "$pkg" ]] || continue
    names+=("$pkg")
  done

  ((${#names[@]})) || return 0
  printf '%s\n' "${names[@]}" | sort -u
}

# ---------------------------------------------------------------------------
# Backend hook defaults
#
# Backends override these by defining a function of the same name before
# calling sysup_main.
# ---------------------------------------------------------------------------

# Handle one backend-specific flag. Return 0 when consumed, 1 to reject it
# (sysup then exits 2). Single-token flags only.
sysup_backend_parse_arg() {
  return 1
}

# Report host state worth seeing before the upgrade runs.
sysup_backend_preamble() {
  return 0
}

# Verify the upgrade did not leave the system broken. Non-zero fails the run.
sysup_backend_checks() {
  return 0
}

# Backends may reject a restart that systemd itself permits when package and
# kernel runtime state make the newly installed userspace temporarily unsafe.
# Return 0 to allow it, 1 to defer it safely, or another status when the
# decision could not be verified. Any output is shown to the operator.
sysup_backend_check_service_restart() {
  return 0
}

# Extra package-manager arguments can select a simulation or another package
# database. Cleanup does not inherit them, so only default-context upgrades
# permit automatic removal. Backends may allow arguments they know are safe.
sysup_backend_autoremove_safe() {
  (($# == 0))
}

# Remove packages that nothing installed still requires. "$1" is `apply` to
# remove them or `report` to only list them (--no-autoremove). Non-zero fails
# the run but never skips the checks that follow.
sysup_backend_autoremove() {
  return 0
}

# Restart services shipped by the packages named in "$@".
sysup_backend_restart_services() {
  sysup_restart_upgraded_services "$@"
}

sysup_usage_common_options() {
  cat <<'EOF'
  --check-only                    skip the upgrade; only run post-upgrade checks
  --no-autoremove                 only report packages no longer required,
                                  instead of removing them after the upgrade
  --no-restart-upgraded-services  skip automatic restart of active services
                                  shipped by upgraded packages
  --restart-failed                restart currently failed enabled systemd units
                                  after checks
  -h, --help                      show this help
EOF
}

# ---------------------------------------------------------------------------
# Run driver
# ---------------------------------------------------------------------------

# Run one sysup invocation. The sudo keeper is stopped here, after the run,
# so every return path of the run itself releases it.
#
# Calling _sysup_run on the left of || turns errexit off for everything it
# runs, at any depth. Every step in it must therefore check its own status
# rather than rely on set -e to stop the run.
sysup_main() {
  local status=0

  _sysup_run "$@" || status=$?
  sysup_stop_sudo_keeper
  return "$status"
}

_sysup_run() {
  local check_only=0 restart_failed=0 restart_upgraded=1 autoremove=1
  local -a upgrade_args=()
  local -a upgraded_packages=()
  local before_packages="" after_packages="" stage=""
  local changed_listing="" unique_listing="" extra_listing=""
  local -a extra_packages=()
  local upgrade_status=0 status=0
  local followup_status=0 upgrade_attempted=0 package_diff_known=0

  while (($#)); do
    case "$1" in
      --check-only)
        check_only=1
        ;;
      # --autoremove predates removal becoming the default; it stays accepted
      # so existing invocations keep working, and the last flag wins.
      --autoremove)
        autoremove=1
        ;;
      --no-autoremove)
        autoremove=0
        ;;
      --no-restart-upgraded-services)
        restart_upgraded=0
        ;;
      --restart-failed)
        restart_failed=1
        ;;
      -h | --help)
        sysup_backend_usage
        return 0
        ;;
      --)
        shift
        upgrade_args+=("$@")
        break
        ;;
      *)
        # Package-manager arguments must follow `--`. Passing unknown words
        # through silently turned a mistyped flag into an apt or yay
        # argument that failed only after sudo and `apt-get update`
        # had already run, or into a real upgrade.
        if ! sysup_backend_parse_arg "$1"; then
          printf 'error: unknown argument: %s\n' "$1" >&2
          printf 'hint: pass package-manager arguments after --, as in: sysup -- %s\n' "$1" >&2
          printf 'run sysup --help for the supported options\n' >&2
          return 2
        fi
        ;;
    esac
    shift
  done

  sysup_backend_require || return
  sysup_backend_preamble || return

  if ((check_only == 0)); then
    before_packages=$(mktemp) || return
    after_packages=$(mktemp) || {
      upgrade_status=$?
      rm -f "$before_packages"
      return "$upgrade_status"
    }

    # Avoid a process-wide EXIT trap here. Backends are sourceable for tests,
    # and clobbering a caller's trap is worse than making this block a little
    # more explicit. Track status manually so every failed path still removes
    # the package snapshots before returning.
    stage="reading the package list"
    sysup_backend_snapshot >"$before_packages" || upgrade_status=$?

    if ((upgrade_status == 0)); then
      sysup_log "warming sudo credentials"
      stage="acquiring sudo credentials"
      sysup_warm_sudo || upgrade_status=$?
      ((upgrade_status != 0)) || sysup_start_sudo_keeper
    fi

    if ((upgrade_status == 0)); then
      sysup_log "upgrading system"
      stage="the system upgrade"
      upgrade_attempted=1
      sysup_backend_upgrade "${upgrade_args[@]+"${upgrade_args[@]}"}" || upgrade_status=$?
    fi

    # Remove unused packages only after a clean upgrade. After a partial
    # failure the dependency graph may be mid-transition, and removing what
    # merely looks orphaned could take out a package a retried upgrade still
    # needs. It precedes the second snapshot so a package upgraded and then
    # removed drops out of the diff instead of reaching the restart step,
    # which could no longer list its files. Its failure is not an upgrade
    # failure: it fails the run without skipping any later step.
    if ((upgrade_attempted)); then
      if ((upgrade_status != 0)); then
        ((autoremove == 0)) ||
          printf 'note: skipped removing packages no longer required because the upgrade failed\n' >&2
      elif ! sysup_backend_autoremove_safe "${upgrade_args[@]+"${upgrade_args[@]}"}"; then
        printf 'note: skipped automatic cleanup because custom package-manager arguments were supplied\n' >&2
      elif ((autoremove)); then
        sysup_backend_autoremove apply || {
          printf '\nerror: removing packages no longer required failed\n' >&2
          status=1
        }
      else
        sysup_backend_autoremove report || status=1
      fi
    fi

    # Package managers can install some packages and still return non-zero.
    # Once the upgrade command has started, always take the second snapshot so
    # checks and service restarts can cover whatever actually changed.
    if ((upgrade_attempted)); then
      followup_status=0
      sysup_backend_snapshot >"$after_packages" || followup_status=$?
      if ((followup_status == 0)); then
        changed_listing="$(sysup_changed_packages "$before_packages" "$after_packages")" ||
          followup_status=$?
      fi
      if ((followup_status == 0)); then
        extra_listing="$(sysup_snapshot_members "$after_packages" \
          "${SYSUP_EXTRA_UPGRADED_PACKAGES[@]+"${SYSUP_EXTRA_UPGRADED_PACKAGES[@]}"}")" ||
          followup_status=$?
      fi
      if ((followup_status == 0)); then
        upgraded_packages=()
        if [[ -n "$changed_listing" ]]; then
          mapfile -t upgraded_packages <<<"$changed_listing"
        fi
        extra_packages=()
        if [[ -n "$extra_listing" ]]; then
          mapfile -t extra_packages <<<"$extra_listing"
        fi
        unique_listing="$(sysup_unique_packages \
          "${upgraded_packages[@]+"${upgraded_packages[@]}"}" \
          "${extra_packages[@]+"${extra_packages[@]}"}")" ||
          followup_status=$?
      fi
      if ((followup_status == 0)); then
        upgraded_packages=()
        if [[ -n "$unique_listing" ]]; then
          mapfile -t upgraded_packages <<<"$unique_listing"
        fi
        package_diff_known=1
      else
        if ((upgrade_status == 0)); then
          upgrade_status=$followup_status
          stage="re-reading or comparing the package list after the upgrade"
        else
          printf '\nerror: could not re-read or compare the package list after the failed upgrade (status %s); upgraded-package service discovery is unavailable\n' \
            "$followup_status" >&2
        fi
      fi
    fi
    rm -f "$before_packages" "$after_packages"
    if ((upgrade_status != 0 && upgrade_attempted == 0)); then
      # Name the stage. Without this the caller gets a bare exit code, and an
      # early failure otherwise gives no indication that no mutation occurred.
      printf '\nerror: %s failed (status %s); post-upgrade checks and service restarts were skipped\n' \
        "$stage" "$upgrade_status" >&2
      return "$upgrade_status"
    fi
    if ((upgrade_status != 0)); then
      printf '\nerror: %s failed (status %s); continuing with best-effort post-upgrade checks and service restarts\n' \
        "$stage" "$upgrade_status" >&2
    fi
  fi

  # Every remaining step contributes to the exit status instead of
  # short-circuiting, so one run surfaces every problem it can see.
  sysup_backend_checks || status=1

  # Nothing was upgraded under --check-only, so there is nothing to restart.
  # This is a guarantee of the driver rather than of each backend: a backend
  # whose restart hook ignores its argument list (debup defers to needrestart,
  # which discovers work on its own) must not mutate the host on a check run.
  if ((restart_upgraded && check_only == 0)); then
    if ((package_diff_known)); then
      sysup_backend_restart_services "${upgraded_packages[@]+"${upgraded_packages[@]}"}" || status=1
    else
      SYSUP_PACKAGE_DIFF_UNVERIFIED=1 sysup_backend_restart_services || status=1
    fi
  fi

  # --check-only is a strict no-mutation mode, including when a conflicting
  # restart request is also present.
  if ((restart_failed && check_only == 0)); then
    sysup_restart_failed_units || status=1
  fi

  # Every run repeats pending deferred-restart reminders, including
  # --check-only, which must not prune the record.
  sysup_report_deferred_restarts "$((check_only == 0))"

  sysup_report_failed_units || status=1
  ((upgrade_status == 0)) || return "$upgrade_status"
  return "$status"
}
