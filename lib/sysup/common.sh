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

# Prompt for sudo once up front so a long upgrade does not stall on a password
# prompt buried in package manager output.
sysup_warm_sudo() {
  ((EUID != 0)) || return 0

  sysup_need_cmds sudo || return
  sudo -v
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

# Handle one backend-specific flag. Return 0 when consumed, 1 to let the
# argument fall through to the package manager. Single-token flags only.
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

# Restart services shipped by the packages named in "$@".
sysup_backend_restart_services() {
  sysup_restart_upgraded_services "$@"
}

sysup_usage_common_options() {
  cat <<'EOF'
  --check-only                    skip the upgrade; only run post-upgrade checks
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

sysup_main() {
  local check_only=0 restart_failed=0 restart_upgraded=1
  local -a upgrade_args=()
  local -a upgraded_packages=()
  local before_packages="" after_packages="" stage=""
  local changed_listing="" unique_listing=""
  local upgrade_status=0 status=0
  local followup_status=0 upgrade_attempted=0 package_diff_known=0

  while (($#)); do
    case "$1" in
      --check-only)
        check_only=1
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
        sysup_backend_parse_arg "$1" || upgrade_args+=("$1")
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
    fi

    if ((upgrade_status == 0)); then
      sysup_log "upgrading system"
      stage="the system upgrade"
      upgrade_attempted=1
      sysup_backend_upgrade "${upgrade_args[@]+"${upgrade_args[@]}"}" || upgrade_status=$?
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
        upgraded_packages=()
        if [[ -n "$changed_listing" ]]; then
          mapfile -t upgraded_packages <<<"$changed_listing"
        fi
        unique_listing="$(sysup_unique_packages \
          "${upgraded_packages[@]+"${upgraded_packages[@]}"}" \
          "${SYSUP_EXTRA_UPGRADED_PACKAGES[@]+"${SYSUP_EXTRA_UPGRADED_PACKAGES[@]}"}")" ||
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

  sysup_report_failed_units || status=1
  ((upgrade_status == 0)) || return "$upgrade_status"
  return "$status"
}
