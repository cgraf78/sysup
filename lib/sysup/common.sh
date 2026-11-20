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

# ---------------------------------------------------------------------------
# Structured notices
#
# Reports that matter after a successful run (a pending reboot, a config merge,
# a deferred restart, a warning) are printed for the operator and also
# recorded here, so policy that depends on them -- whether an unattended
# --cron run mails its log -- reads a kind instead of matching message text.
# ---------------------------------------------------------------------------

# Every kind a run can record. This is the one owner of the spelling: the cron
# report policy and the backends both use these words.
#   reboot-required   the upgrade needs a reboot to take effect
#   config-merge      a .pacnew/.rpmnew/.dpkg-dist style file awaits a merge
#   deferred-restart  a service was left on pre-upgrade code
#   excluded-pending  a package excluded with --exclude still has an update
#   kept-back         the package manager held back an available upgrade
#   warning           anything sysup_warn reported
SYSUP_NOTICE_KINDS=(reboot-required config-merge deferred-restart
  excluded-pending kept-back warning)

# Where notices are recorded, one "kind<TAB>message" line each. Empty means
# nothing records them, and sysup_notice only validates its kind. A file
# rather than a shell array, because reports also run inside command
# substitutions, whose variable assignments never reach the run.
_SYSUP_NOTICE_FILE=""

# Record a notice of `kind`. Prints nothing: each call site keeps printing its
# own operator-facing text, so recording a notice never changes the output.
# An unknown kind is a programming error and returns 2.
#
# Recording is advisory: a failed write must not fail the report around it.
sysup_notice() {
  local kind="$1" message known valid=0
  shift
  message="$*"

  for known in "${SYSUP_NOTICE_KINDS[@]}"; do
    [[ "$kind" != "$known" ]] || valid=1
  done
  if ((valid == 0)); then
    printf 'error: unknown sysup notice kind: %s\n' "$kind" >&2
    return 2
  fi
  [[ -n "$_SYSUP_NOTICE_FILE" ]] || return 0
  # One line per notice: fold embedded newlines so the record stays parsable.
  printf '%s\t%s\n' "$kind" "${message//$'\n'/ }" >>"$_SYSUP_NOTICE_FILE" ||
    true
}

# Print `warning: <message>` on stderr and record it as a `warning` notice.
sysup_warn() {
  printf 'warning: %s\n' "$*" >&2
  sysup_notice warning "$*"
}

# Print the kinds recorded in notice file "$1", one per line, in order.
sysup_notice_kinds() {
  local kind

  [[ -s "$1" ]] || return 0
  while IFS=$'\t' read -r kind _; do
    [[ -n "$kind" ]] && printf '%s\n' "$kind"
  done <"$1"
  return 0
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

# Warm sudo with a real command: it prompts only if that command needs a
# password, and refreshes cached credentials otherwise. A deliberately refused
# `sudo -n -k true` can send a security email even with stderr redirected.
# `sudo -v` alone is not equivalent: verifypw=all can require a password on
# mixed PASSWD/NOPASSWD policies whose actual commands are passwordless.
sysup_warm_sudo() {
  ((EUID != 0)) || return 0

  sysup_need_cmds sudo || return
  sudo true
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
# clobbering a caller's trap is worse than that bounded lag. Always start the
# keeper after warming: successful commands cannot distinguish NOPASSWD from
# cached credentials. Under mixed passwordless policies, validation may refuse;
# `sudo -n -v` then exits without a refused-command alert or a prompt.
sysup_start_sudo_keeper() {
  local parent="$BASHPID"

  ((EUID != 0)) || return 0
  [[ "$SYSUP_SUDO_REFRESH" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  [[ ! "$SYSUP_SUDO_REFRESH" =~ ^0+([.]0+)?$ ]] || return 0
  [[ -z "$_SYSUP_SUDO_KEEPER_PID" ]] || return 0

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
# (sysup then exits 2). Single-token flags only; a value travels in the same
# token after `=`.
sysup_backend_parse_arg() {
  return 1
}

# Leave the packages named in "$@" (as given to --exclude, possibly globs) out
# of this run's upgrade. Called once, before anything else runs, with every
# name. Return 0 to accept; any other status ends the run with it. The default
# rejects with 2, so a backend that cannot honor exclusions never upgrades a
# package the operator asked to keep.
sysup_backend_exclude() {
  printf 'error: %s does not support --exclude\n' "${SYSUP_BACKEND_NAME:-this backend}" >&2
  return 2
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
  --cron                          unattended mode for root's crontab: skip when
                                  another --cron run or a scheduled shutdown is
                                  active, and print the buffered log only when
                                  something changed, failed, or needs attention
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
#
# --cron changes how the whole run executes (privilege, locking, output), so
# it is taken out here, before the shared parser sees the rest. Words after
# `--` belong to the package manager and are never inspected. --help with
# --cron prints help directly: buffering it would make it silent.
sysup_main() {
  local status=0 cron=0 help=0
  local -a args=()

  while (($#)); do
    case "$1" in
      --cron) cron=1 ;;
      --)
        args+=("$@")
        break
        ;;
      *)
        [[ "$1" != -h && "$1" != --help ]] || help=1
        args+=("$1")
        ;;
    esac
    shift
  done

  if ((cron && ! help)); then
    _sysup_cron "${args[@]+"${args[@]}"}" || status=$?
  else
    _sysup_run "${args[@]+"${args[@]}"}" || status=$?
  fi
  sysup_stop_sudo_keeper
  return "$status"
}

# ---------------------------------------------------------------------------
# Unattended runs (--cron)
# ---------------------------------------------------------------------------

# Where --cron keeps its lock and its in-progress log. /run is cleared on
# boot, so a lock or log orphaned by a crash never outlives the boot.
# Overridable for tests.
SYSUP_RUN_DIR="${SYSUP_RUN_DIR:-/run/sysup}"
# systemd-logind writes this while a shutdown or reboot is scheduled (as
# unattended-upgrades does with `shutdown -r 04:20`). Overridable for tests.
SYSUP_SHUTDOWN_SCHEDULED_FILE="${SYSUP_SHUTDOWN_SCHEDULED_FILE:-/run/systemd/shutdown/scheduled}"
# EX_TEMPFAIL from sysexits.h: another --cron run holds the lock; try later.
SYSUP_EXIT_LOCKED=75

# Set for the duration of a --cron run; steps that behave differently
# unattended (the shutdown inhibitor) read it.
_SYSUP_CRON=0
# The open file descriptor holding the --cron lock, and the shutdown
# inhibitor's process, while each is held.
_SYSUP_CRON_LOCK_FD=""
_SYSUP_INHIBIT_PID=""
# Set by _sysup_run when the package snapshots before and after the upgrade
# differ: any install, removal, or version change.
_SYSUP_PACKAGES_CHANGED=0

# A function so tests can run --cron without being root.
sysup_is_root() {
  ((EUID == 0))
}

# Create the run directory and take the nonblocking --cron lock. Returns
# SYSUP_EXIT_LOCKED, after one line of explanation, when another --cron run
# holds it.
#
# The directory and the lock are refused when they are symlinks: this runs as
# root, and following a link planted there would create or truncate files
# elsewhere. A missing /run/sysup is created root-owned 0755.
#
# Best effort by design: only --cron runs take this lock, so it keeps two
# scheduled runs from overlapping, and the package managers' own locks still
# guard against an interactive run. Children inherit the descriptor, so a
# daemon a package script starts directly (rather than through systemd) can
# keep the lock held until it exits.
_sysup_cron_lock() {
  local dir="$SYSUP_RUN_DIR" lock

  if [[ -L "$dir" ]]; then
    printf 'error: %s is a symlink; refusing to use it\n' "$dir" >&2
    return 1
  fi
  # -m applies to the run directory alone; its parent is /run.
  # shellcheck disable=SC2174
  mkdir -p -m 0755 -- "$dir" || return
  if [[ -L "$dir" || ! -d "$dir" ]]; then
    printf 'error: %s is not a directory\n' "$dir" >&2
    return 1
  fi
  lock="$dir/cron.lock"
  if [[ -L "$lock" ]]; then
    printf 'error: %s is a symlink; refusing to use it\n' "$lock" >&2
    return 1
  fi
  exec {_SYSUP_CRON_LOCK_FD}>>"$lock" || return
  if ! flock -n "$_SYSUP_CRON_LOCK_FD"; then
    exec {_SYSUP_CRON_LOCK_FD}>&-
    _SYSUP_CRON_LOCK_FD=""
    printf 'sysup: skipped; another sysup --cron run holds %s\n' "$lock"
    return "$SYSUP_EXIT_LOCKED"
  fi
}

_sysup_cron_unlock() {
  [[ -n "$_SYSUP_CRON_LOCK_FD" ]] || return 0
  flock -u "$_SYSUP_CRON_LOCK_FD"
  exec {_SYSUP_CRON_LOCK_FD}>&-
  _SYSUP_CRON_LOCK_FD=""
}

# Take a systemd shutdown inhibitor for the package-manager step of a --cron
# run, so a scheduled reboot (unattended-upgrades', say) waits instead of
# interrupting a transaction halfway. Best effort and --cron only: without
# systemd or systemd-inhibit the step simply runs uninhibited.
#
# systemd-inhibit can only wrap an external command, not this shell's
# functions, so it holds the lock around a watcher that exits when this shell
# does. That bounds a lock orphaned by a killed run to a few seconds; the
# normal release kills systemd-inhibit, whose child gets SIGTERM with it. The
# watcher reads nothing from this shell, so no descriptor inherited by a
# package script's long-lived child can keep the inhibitor alive.
sysup_inhibit_shutdown() {
  ((_SYSUP_CRON)) || return 0
  [[ -z "$_SYSUP_INHIBIT_PID" ]] || return 0
  sysup_systemd_running || return 0
  command -v systemd-inhibit >/dev/null 2>&1 || return 0

  # The --cron lock descriptor is closed for it: the watcher's last sleep can
  # outlive the release by a few seconds, and must not hold the lock then.
  # $BASHPID is read here: inside the background job it names the job.
  local owner="$BASHPID" ready deadline

  ready=$(mktemp "$SYSUP_RUN_DIR/inhibit-ready.XXXXXX") || return
  if [[ -n "$_SYSUP_CRON_LOCK_FD" ]]; then
    _sysup_start_inhibitor "$owner" "$ready" {_SYSUP_CRON_LOCK_FD}>&- &
  else
    _sysup_start_inhibitor "$owner" "$ready" &
  fi
  _SYSUP_INHIBIT_PID=$!

  # The watcher only starts once logind has granted the lock. Wait for its
  # signal before letting the package manager mutate anything.
  deadline=$((SECONDS + 10))
  while kill -0 "$_SYSUP_INHIBIT_PID" 2>/dev/null; do
    if [[ -s "$ready" ]]; then
      rm -f -- "$ready"
      return 0
    fi
    ((SECONDS < deadline)) || break
    sleep 0.05
  done
  sysup_release_shutdown_inhibitor
  rm -f -- "$ready"
  printf 'error: could not acquire a shutdown inhibitor\n' >&2
  return 1
}

# Signal readiness through "$2", then watch the shell whose pid is "$1".
# A separate function lets the caller close descriptors for it alone.
_sysup_start_inhibitor() {
  # The watcher expands the positional parameters in its own shell.
  # shellcheck disable=SC2016
  exec systemd-inhibit --what=shutdown --who=sysup --mode=block \
    --why="sysup is upgrading packages" \
    sh -c 'printf "ready\n" >"$2" || exit; while kill -0 "$1" 2>/dev/null; do sleep 5; done' \
    sh "$1" "$2" \
    </dev/null >/dev/null
}

sysup_release_shutdown_inhibitor() {
  local pid="$_SYSUP_INHIBIT_PID"

  [[ -n "$pid" ]] || return 0
  _SYSUP_INHIBIT_PID=""
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Decide whether a finished --cron run prints its log. "$1" is the run's exit
# status, "$2" yes/no for a package change, "$3" the notice file. Returns 0 to
# print. A run that changed nothing and recorded nothing worth reading stays
# silent, so cron mails only what needs attention; an excluded package with an
# update is expected on every run while the exclusion stands, so it alone does
# not mail.
sysup_cron_should_report() {
  local status="$1" changed="$2" notices="$3" kind

  ((status == 0)) || return 0
  [[ "$changed" != yes ]] || return 0
  while IFS= read -r kind; do
    [[ "$kind" == excluded-pending ]] || return 0
  done < <(sysup_notice_kinds "$notices")
  return 1
}

# Keep the last --cron log and a machine-readable status beside the deferred-
# restart record, each replaced by a rename so a reader never sees half of it.
# last-cron holds `time=<epoch>`, `status=<exit status>`, `changed=yes|no`.
_sysup_cron_save_state() {
  local log="$1" status="$2" changed="$3" dir="$SYSUP_STATE_DIR" tmp

  install -d -m 0755 -- "$dir" || return
  tmp="$(mktemp "$dir/.last-cron.log.XXXXXX")" || return
  # Keep the mktemp mode: root's package hooks can log sensitive details.
  if ! { cat -- "$log" >"$tmp" &&
    mv -f -- "$tmp" "$dir/last-cron.log"; }; then
    rm -f -- "$tmp"
    return 1
  fi
  tmp="$(mktemp "$dir/.last-cron.XXXXXX")" || return
  if ! { printf 'time=%s\nstatus=%s\nchanged=%s\n' "$(date +%s)" "$status" "$changed" >"$tmp" &&
    chmod -- 0644 "$tmp" && mv -f -- "$tmp" "$dir/last-cron"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Run sysup unattended from root's crontab. Cron mails whatever a job prints,
# so the run's output is buffered and printed only when it failed, changed
# packages, or recorded a notice; a quiet night sends nothing.
_sysup_cron() {
  local status=0 changed=no log="" notices=""

  # Root only, checked before anything else: as another user the run would
  # stop at sudo prompts nobody answers, and it could not take the lock or
  # write the state below.
  if ! sysup_is_root; then
    printf 'error: --cron must run as root\n' >&2
    return 2
  fi
  if ((BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] == 0)); then
    printf 'error: --cron requires Bash 4.1 or newer\n' >&2
    return 2
  fi
  if [[ -e "$SYSUP_SHUTDOWN_SCHEDULED_FILE" ]]; then
    printf 'sysup: skipped; a shutdown is scheduled (%s)\n' "$SYSUP_SHUTDOWN_SCHEDULED_FILE"
    return 0
  fi
  sysup_need_cmds flock || return
  _sysup_cron_lock || return

  # The buffer lives beside the lock, under the root-owned run directory,
  # rather than in a shared /tmp.
  log="$(mktemp "$SYSUP_RUN_DIR/cron-log.XXXXXX")" || status=$?
  if ((status == 0)); then
    notices="$(mktemp "$SYSUP_RUN_DIR/cron-notices.XXXXXX")" || status=$?
  fi
  if ((status != 0)); then
    rm -f -- "$log"
    _sysup_cron_unlock
    return "$status"
  fi

  _SYSUP_PACKAGES_CHANGED=0
  SYSUP_EXTRA_UPGRADED_PACKAGES=()
  _SYSUP_CRON=1
  _SYSUP_NOTICE_FILE="$notices"
  # stdin from /dev/null: nothing can prompt under cron, and a package
  # manager that tried would otherwise read cron's stdin.
  _sysup_run "$@" >"$log" 2>&1 </dev/null || status=$?
  _SYSUP_NOTICE_FILE=""
  _SYSUP_CRON=0

  if ((_SYSUP_PACKAGES_CHANGED || ${#SYSUP_EXTRA_UPGRADED_PACKAGES[@]})); then
    changed=yes
  fi
  if sysup_cron_should_report "$status" "$changed" "$notices"; then
    cat -- "$log"
  fi
  # Outside the buffer, so a failure to keep the record reaches cron mail.
  _sysup_cron_save_state "$log" "$status" "$changed" ||
    printf 'warning: could not record the last --cron run in %s\n' "$SYSUP_STATE_DIR" >&2
  rm -f -- "$log" "$notices"
  _sysup_cron_unlock
  return "$status"
}

# ---------------------------------------------------------------------------
# The shared run
# ---------------------------------------------------------------------------

# Package names and the `*`/`?` globs pacman and dnf accept. The first
# character may not be `-`, which a package manager would read as an option.
_SYSUP_EXCLUDE_NAME_RE='^[A-Za-z0-9@_+.*?][A-Za-z0-9@_+.*?:-]*$'

# Print the names in one --exclude value, one per line. An empty value, an
# empty element (a stray comma), or anything else that is not a package name
# is a usage error.
_sysup_parse_excludes() {
  local value="$1" name
  local -a names=()

  if [[ -z "$value" ]]; then
    printf 'error: --exclude needs package names, as in --exclude=PKG[,PKG...]\n' >&2
    return 2
  fi
  if [[ "$value" == *$'\n'* ]]; then
    printf 'error: --exclude package names must be on one line\n' >&2
    return 2
  fi
  IFS=, read -ra names <<<"$value"
  # read drops one trailing empty field, which still means a stray comma.
  [[ "$value" != *, ]] || names+=("")
  for name in "${names[@]}"; do
    if [[ ! "$name" =~ $_SYSUP_EXCLUDE_NAME_RE ]]; then
      printf 'error: invalid package name in --exclude: %s\n' "${name:-(empty)}" >&2
      return 2
    fi
    printf '%s\n' "$name"
  done
}

_sysup_run() {
  local check_only=0 restart_failed=0 restart_upgraded=1 autoremove=1
  local -a upgrade_args=() excludes=()
  local -a upgraded_packages=()
  local before_packages="" after_packages="" stage=""
  local changed_listing="" unique_listing="" extra_listing=""
  local -a extra_packages=()
  local upgrade_status=0 status=0
  local followup_status=0 upgrade_attempted=0 package_diff_known=0
  local exclude_listing

  while (($#)); do
    case "$1" in
      --check-only)
        check_only=1
        ;;
      # A value rides in the same token so the parser contract stays one
      # token per flag. Exclusions never join the `--` arguments: those
      # disable automatic cleanup, and keeping a package back is no reason
      # to skip it.
      --exclude=*)
        exclude_listing="$(_sysup_parse_excludes "${1#--exclude=}")" || return
        mapfile -t -O "${#excludes[@]}" excludes <<<"$exclude_listing"
        ;;
      --exclude)
        printf 'error: --exclude takes its packages in the same word, as in --exclude=PKG[,PKG...]\n' >&2
        return 2
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

  # Before anything else runs, so a backend that cannot exclude packages
  # rejects the request instead of upgrading them.
  if ((${#excludes[@]})); then
    sysup_backend_exclude "${excludes[@]}" || return
  fi

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
      # Held across the upgrade and the removal below: both run package
      # transactions a reboot must not cut short.
      stage="acquiring the shutdown inhibitor"
      sysup_inhibit_shutdown || upgrade_status=$?
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
    sysup_release_shutdown_inhibitor

    # Package managers can install some packages and still return non-zero.
    # Once the upgrade command has started, always take the second snapshot so
    # checks and service restarts can cover whatever actually changed.
    if ((upgrade_attempted)); then
      followup_status=0
      sysup_backend_snapshot >"$after_packages" || followup_status=$?
      # Any difference counts, installs and removals included, which the
      # version diff below deliberately ignores; --cron reports on it.
      # Compared in the shell because cmp (diffutils) is not in every base
      # install; a package list is small.
      if ((followup_status == 0)) && [[ "$(<"$before_packages")" != "$(<"$after_packages")" ]]; then
        _SYSUP_PACKAGES_CHANGED=1
      fi
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
  sysup_backend_checks "$check_only" || status=1

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
