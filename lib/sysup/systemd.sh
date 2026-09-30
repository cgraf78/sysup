# shellcheck shell=bash
# systemd handling shared by the sysup updaters.
#
# Upgrading a package replaces its binaries on disk but leaves the running
# service on the old code, so an upgrade is not finished until the affected
# units have been restarted and the unit state re-checked.

# Prints the failed-unit table. Returns non-zero when systemd could not be
# queried at all, which the callers must not confuse with "nothing failed".
sysup_failed_units() {
  systemctl --failed --no-legend --plain
}
sysup_report_failed_units() {
  local failed restartable=()

  sysup_log "checking failed systemd units"

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'skipped: systemctl is not available\n'
    return 0
  fi

  if ! failed="$(sysup_failed_units 2>&1)"; then
    printf '%s\n' "$failed" >&2
    printf '\nerror: could not query systemd for failed units; unit state is unverified\n' >&2
    return 1
  fi

  if [[ -z "$failed" ]]; then
    printf 'ok: no failed systemd units\n'
    return 0
  fi

  printf '%s\n' "$failed"
  while read -r unit _; do
    [[ -n "${unit:-}" ]] || continue
    [[ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" == "enabled" ]] || continue
    restartable+=("$unit")
  done <<<"$failed"

  if ((${#restartable[@]})); then
    printf '\nhint: run: sysup --restart-failed\n' >&2
    printf 'hint: failed enabled units: %s\n' "${restartable[*]}" >&2
  fi

  printf '\nerror: systemd has failed units\n' >&2
  return 1
}

# Restart failed units that are enabled. Disabled units are left alone: they
# failed on a manual or dependency-triggered start, and restarting them here
# would start services the host is not configured to run.
sysup_restart_failed_units() {
  local failed unit state
  local units=()

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'skipped: systemctl is not available\n'
    return 0
  fi

  if ! failed="$(sysup_failed_units 2>&1)"; then
    printf '%s\n' "$failed" >&2
    printf 'error: could not query systemd for failed units; restarted nothing\n' >&2
    return 1
  fi

  if [[ -z "$failed" ]]; then
    printf 'ok: no failed units to restart\n'
    return 0
  fi

  while read -r unit _; do
    [[ -n "${unit:-}" ]] || continue
    state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    [[ "$state" == "enabled" ]] || continue
    units+=("$unit")
  done <<<"$failed"

  if ((${#units[@]} == 0)); then
    printf 'no failed enabled units to restart\n'
    return 0
  fi

  sysup_log "restarting failed enabled units: ${units[*]}"
  sysup_run_as_root systemctl reset-failed "${units[@]}"
  sysup_run_as_root systemctl restart "${units[@]}"
}

# All active units, not just services: packages ship socket, timer, and path
# units whose stale definitions matter too.
#
# Returns non-zero when the listing could not be obtained. A host with no active
# units and a host whose systemd cannot be reached look identical otherwise, and
# the second must not be reported as "nothing to restart".
sysup_active_units() {
  local units

  units="$(systemctl list-units --state=active --no-legend --plain)" || return

  [[ -n "$units" ]] || return 0
  while read -r unit _; do
    [[ -n "${unit:-}" ]] || continue
    printf '%s\n' "$unit"
  done <<<"$units"
}

# Print the unit names shipped by the given packages. /lib is covered alongside
# /usr/lib because dpkg records the path as the package declared it, which on
# Debian can still be the pre-merged-usr spelling.
#
# A package whose files cannot be listed contributes no units, which would
# silently drop it from the restart set, so say so rather than skipping quietly.
sysup_service_units_for_packages() {
  local pkg file listing
  local status=0

  for pkg in "$@"; do
    if ! listing="$(sysup_backend_package_files "$pkg" 2>&1)"; then
      printf '%s\n' "$listing" >&2
      printf 'warning: could not list files owned by %s; its services will not be restarted\n' \
        "$pkg" >&2
      status=1
      continue
    fi

    while IFS= read -r file; do
      case "$file" in
        /usr/lib/systemd/system/* | /lib/systemd/system/* | /etc/systemd/system/*)
          # Socket, timer, and path units activate services too, so restarting
          # only *.service leaves activation units running stale definitions.
          case "$file" in
            *.service | *.socket | *.timer | *.path)
              printf '%s\n' "${file##*/}"
              ;;
          esac
          ;;
      esac
    done <<<"$listing"
  done

  return "$status"
}

# Intersect the units shipped by the given packages with the units currently
# running, so only services the host actually uses get restarted.
sysup_upgraded_active_service_units() {
  local -a owned_units=()
  local -a active_units=()
  local owned active prefix

  local owned_listing active_listing suffix
  local discovery_status=0

  owned_listing="$(sysup_service_units_for_packages "$@")" || discovery_status=$?
  if [[ -n "$owned_listing" ]]; then
    mapfile -t owned_units <<<"$owned_listing"
  fi
  ((${#owned_units[@]})) || return "$discovery_status"

  active_listing="$(sysup_active_units)" || return 1
  [[ -n "$active_listing" ]] || return "$discovery_status"
  mapfile -t active_units <<<"$active_listing"

  # Keep ordinary non-matches successful: with pipefail, a trailing
  # `[[ ... ]] && printf` would make valid discovery depend on unit ordering.
  for owned in "${owned_units[@]}"; do
    [[ -n "$owned" ]] || continue
    # A template unit ships no runnable instance of its own; its running
    # instances carry the upgraded code.
    if [[ "$owned" == *@.* ]]; then
      prefix="${owned%@.*}"
      suffix=".${owned##*.}"
      for active in "${active_units[@]}"; do
        if [[ "$active" == "$prefix@"*"$suffix" ]]; then
          printf '%s\n' "$active" || return
        fi
      done
      continue
    fi

    for active in "${active_units[@]}"; do
      if [[ "$active" == "$owned" ]]; then
        printf '%s\n' "$active" || return
      fi
    done
  done | sort -u || return 1

  return "$discovery_status"
}

# Units whose restart ends a login or graphical session, or takes down a
# service every session depends on. An upgrade must not kill the operator's
# session mid-run, so these keep running the old code until a reboot or a
# deliberate manual restart. The list starts from the session-related defaults
# in needrestart's override_rc, which only protect debup's needrestart path;
# the shared package-based path needs the same protection because template
# expansion maps a shipped user@.service or getty@.service to every running
# instance. It adds units needrestart never has to consider: oneshots with no
# process to inspect (user-runtime-dir@) and gettys and display managers
# missing from its list. Patterns match whole unit names. needrestart matches
# open-ended prefixes (^gdm, ^dbus); these are anchored to the real unit names
# so an unrelated unit sharing a prefix (sanlock's wdmd, say) still restarts.
#
# Deliberately not listed: systemd-journald (it keeps client streams in its
# fd store across restarts), sshd (live connections are separate processes),
# and needrestart's network and virtualization entries, which risk
# connectivity or guests rather than the local session.
sysup_session_critical_unit() {
  case "$1" in
    # The per-user manager owns every user service and the graphical
    # session; user-runtime-dir@ owns XDG_RUNTIME_DIR, and user@ Requires= it,
    # so stopping it stops the manager too.
    user@*.service | user-runtime-dir@*.service) return 0 ;;
    # Restarting a getty kills the login shell on that terminal.
    getty@* | autovt@* | serial-getty@* | container-getty@* | console-getty.service) return 0 ;;
    # Display managers are the parent of every graphical session they host.
    # needrestart's list plus gdm3 (Debian's historical name) and the Arch
    # display managers greetd and ly; any other one is caught through the
    # display-manager.service alias by the caller.
    gdm.service | gdm3.service | kdm.service | lightdm.service | lxdm.service | \
      nodm.service | sddm.service | slim.service | wdm.service | xdm.service | \
      greetd.service | ly.service | ly@*.service) return 0 ;;
    # logind tracks sessions, seats, and device ACLs (Debian #798097);
    # seatd fills that role for seatd-based compositors.
    # systemd 258+ also has logind's Varlink socket, which pam_systemd uses;
    # restarting it rebinds the socket while logind keeps the old one.
    systemd-logind.service | systemd-logind-varlink.socket | elogind.service | \
      seatd.service) return 0 ;;
    # The system bus, in every implementation plus its activation socket;
    # logind, polkit, and desktop sessions depend on it. dbus.service is only
    # an alias where the daemon ships as dbus-daemon.service (Fedora, Arch's
    # dbus-daemon-units), and list-units reports the real name.
    dbus.service | dbus-daemon.service | dbus-broker.service | dbus.socket) return 0 ;;
    # These are the operator's shell when active.
    emergency.service | rescue.service) return 0 ;;
  esac
  return 1
}

# Deferred session-critical restarts outlive the run that deferred them: an
# unattended host could otherwise keep a D-Bus or logind security fix unloaded
# indefinitely after one easily missed message. Record them host-wide, root-
# owned under /var/lib, because sysup may run as the operator (through sudo)
# or as root, and every later run must see the same record. Overridable for
# tests.
SYSUP_STATE_DIR="${SYSUP_STATE_DIR:-/var/lib/sysup}"
# The kernel regenerates boot_id on every boot, so it decides "rebooted since
# the deferral" without comparing wall clocks that may have been adjusted.
SYSUP_BOOT_ID_FILE="${SYSUP_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"

sysup_deferred_state_file() {
  printf '%s/deferred-restarts\n' "$SYSUP_STATE_DIR"
}

sysup_boot_id() {
  local id=""

  [[ -r "$SYSUP_BOOT_ID_FILE" ]] || return 1
  IFS= read -r id <"$SYSUP_BOOT_ID_FILE" || true
  [[ -n "$id" ]] || return 1
  printf '%s\n' "$id"
}

# Print when a unit last entered the active state, on systemd's own monotonic
# clock. A deferred unit whose value changes was restarted since the deferral.
# Returns 1 when the unit is inactive or failed (stopped or gone, so nothing
# runs the old code) and 2 when systemd could not be queried. Transient states
# (reloading, activating, deactivating) still count as running: pruning on
# them would drop a reminder for good.
sysup_unit_active_since() {
  local output line state="" since=""

  output="$(systemctl show --property=ActiveState \
    --property=ActiveEnterTimestampMonotonic -- "$1" 2>/dev/null </dev/null)" || return 2
  while IFS= read -r line; do
    case "$line" in
      ActiveState=*) state="${line#*=}" ;;
      ActiveEnterTimestampMonotonic=*) since="${line#*=}" ;;
    esac
  done <<<"$output"
  case "$state" in
    inactive | failed) return 1 ;;
    "") return 2 ;;
  esac
  [[ -n "$since" ]] || return 2
  printf '%s\n' "$since"
}

# Print the recorded deferrals that still apply, as "boot<TAB>unit<TAB>since"
# lines. An entry is spent once the host rebooted, or the unit stopped or was
# restarted. When the boot or the unit cannot be checked the entry is kept:
# a redundant reminder is safer than silently dropping one.
sysup_pending_deferred_restarts() {
  local state boot="" entry_boot unit since current rc seen=" "

  state="$(sysup_deferred_state_file)"
  [[ -e "$state" ]] || return 0
  if [[ ! -r "$state" ]]; then
    printf 'warning: could not read %s; deferred service restarts are unverified\n' \
      "$state" >&2
    return 1
  fi
  boot="$(sysup_boot_id)" || boot=""

  while IFS=$'\t' read -r entry_boot unit since _ || [[ -n "${entry_boot:-}" ]]; do
    [[ -n "${entry_boot:-}" && "$entry_boot" != \#* ]] || continue
    [[ -n "${unit:-}" && -n "${since:-}" ]] || continue
    # A hand-edited duplicate is reported once.
    [[ "$seen" != *" $unit "* ]] || continue
    if [[ -n "$boot" && "$entry_boot" != unknown && "$entry_boot" != "$boot" ]]; then
      continue
    fi
    rc=0
    current="$(sysup_unit_active_since "$unit")" || rc=$?
    ((rc != 1)) || continue
    if ((rc == 0)) && [[ "$since" != - && "$current" != "$since" ]]; then
      continue
    fi
    seen+="$unit "
    printf '%s\t%s\t%s\n' "$entry_boot" "$unit" "$since"
  done <"$state"
}

# Replace the state with the given entries, or remove it when none remain.
# The new file is installed beside the old one and renamed over it, so a
# reader never sees a partial record.
sysup_write_deferred_state() {
  local state tmp status=0

  state="$(sysup_deferred_state_file)"
  if (($# == 0)); then
    [[ -e "$state" ]] || return 0
    sysup_run_as_root rm -f -- "$state"
    return
  fi

  tmp="$(mktemp)" || return
  {
    printf '# sysup deferred session-critical restarts: boot id, unit, ActiveEnterTimestampMonotonic\n'
    printf '%s\n' "$@"
  } >"$tmp" || status=$?
  if ((status == 0)); then
    sysup_run_as_root install -d -m 0755 -- "$SYSUP_STATE_DIR" || status=$?
  fi
  if ((status == 0)); then
    sysup_run_as_root install -m 0644 -- "$tmp" "$state.new" || status=$?
  fi
  if ((status == 0)); then
    sysup_run_as_root mv -f -- "$state.new" "$state" || status=$?
  fi
  rm -f -- "$tmp"
  return "$status"
}

# Add the units deferred by this run to the pending record. A unit deferred
# again is refreshed: this upgrade is the one a restart has to pick up.
# user-runtime-dir@ is deferred but not recorded: it is a oneshot that only
# mounts XDG_RUNTIME_DIR, so there is no old code left running to remind about.
sysup_record_deferred_restarts() {
  local boot listing entry_boot unit since new
  local -a entries=() record=()

  for unit in "$@"; do
    [[ "$unit" == user-runtime-dir@* ]] || record+=("$unit")
  done
  ((${#record[@]})) || return 0
  set -- "${record[@]}"

  boot="$(sysup_boot_id)" || boot=unknown
  # An existing record that cannot be read must not be overwritten: that
  # would silently drop the reminders it holds.
  listing="$(sysup_pending_deferred_restarts)" || return 1
  while IFS=$'\t' read -r entry_boot unit since; do
    [[ -n "${unit:-}" ]] || continue
    for new in "$@"; do
      [[ "$new" != "$unit" ]] || continue 2
    done
    entries+=("$entry_boot"$'\t'"$unit"$'\t'"$since")
  done <<<"$listing"
  for unit in "$@"; do
    since="$(sysup_unit_active_since "$unit")" || since=-
    entries+=("$boot"$'\t'"$unit"$'\t'"$since")
  done

  if ! sysup_write_deferred_state "${entries[@]}"; then
    printf 'warning: could not record deferred restarts in %s; later runs will not repeat this reminder\n' \
      "$SYSUP_STATE_DIR" >&2
    return 1
  fi
}

# Remind on every run while deferred units still run pre-upgrade code. The
# single "reboot recommended:" line on stderr is a stable marker automation can
# match. Like debup's reboot-required report it is advisory and never changes
# the exit status. With $1 = 1 the run also prunes spent entries; --check-only
# passes 0 and leaves the host untouched.
sysup_report_deferred_restarts() {
  local may_prune="${1:-0}" state listing line entry_boot unit total=0
  local -a pending=() units=()

  command -v systemctl >/dev/null 2>&1 || return 0
  state="$(sysup_deferred_state_file)"
  [[ -e "$state" ]] || return 0
  listing="$(sysup_pending_deferred_restarts)" || return 0
  if [[ -n "$listing" ]]; then
    mapfile -t pending <<<"$listing"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    total=$((total + 1))
  done <"$state"
  if ((may_prune && ${#pending[@]} != total)); then
    sysup_write_deferred_state "${pending[@]+"${pending[@]}"}" ||
      printf 'warning: could not prune spent entries from %s\n' "$state" >&2
  fi

  ((${#pending[@]})) || return 0
  for line in "${pending[@]}"; do
    IFS=$'\t' read -r entry_boot unit _ <<<"$line"
    units+=("$unit")
  done
  # "may": package scripts can re-exec some managers in place without
  # changing their activation time, so this cannot be certain.
  printf 'reboot recommended: session-critical units may still run pre-upgrade code: %s; restart them manually or reboot\n' \
    "${units[*]}" >&2
}

sysup_restart_upgraded_services() {
  local -a units=()
  local -a active_units=()
  local -a session_units=()
  local can_stop display_manager="" policy_output policy_status unit unit_listing
  local deferred_count=0 discovery_status=0

  if (($# == 0)); then
    if [[ "${SYSUP_PACKAGE_DIFF_UNVERIFIED:-0}" == 1 ]]; then
      printf 'error: could not determine which packages changed; upgraded service restarts are unverified\n' >&2
      return 1
    fi
    printf 'ok: no packages upgraded during this run\n'
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'skipped: systemctl is not available\n'
    return 0
  fi

  unit_listing="$(sysup_upgraded_active_service_units "$@")" || discovery_status=$?
  if [[ -n "$unit_listing" ]]; then
    mapfile -t active_units <<<"$unit_listing"
  fi

  if ((${#active_units[@]})); then
    # Capability properties must come from the newly installed definitions.
    # Otherwise an upgrade that introduces a manual-control refusal can pass
    # the old check and then reject the restart after daemon-reload.
    sysup_run_as_root systemctl daemon-reload || return
    # list-units reports the display manager under its own name, never the
    # display-manager.service alias, so resolve the alias to cover display
    # managers the static list does not know. Best effort: the static list
    # still applies when the alias is unset or the query fails.
    display_manager="$(systemctl show --property=Id --value -- display-manager.service 2>/dev/null)" ||
      display_manager=""
  fi

  # Active includes boot-time oneshots that remain active after they exit.
  # Some of those deliberately refuse manual stop, so sending the entire set
  # through one try-restart request makes an otherwise healthy upgrade noisy
  # and fails the restart batch. Ask systemd for the effective capability
  # instead of maintaining a release-sensitive list of special unit names.
  for unit in "${active_units[@]}"; do
    # Session safety is decided before systemd capability: a session unit
    # is deferred even when systemd would allow restarting it.
    if sysup_session_critical_unit "$unit" ||
      [[ -n "$display_manager" && "$unit" == "$display_manager" ]]; then
      session_units+=("$unit")
      continue
    fi
    if ! can_stop="$(systemctl show --property=CanStop --value -- "$unit")"; then
      printf 'warning: could not determine whether %s supports manual restart\n' \
        "$unit" >&2
      discovery_status=1
      continue
    fi
    case "$can_stop" in
      yes)
        if policy_output="$(sysup_backend_check_service_restart "$unit")"; then
          units+=("$unit")
          continue
        else
          policy_status=$?
        fi
        [[ -z "$policy_output" ]] || printf '%s\n' "$policy_output" >&2
        if ((policy_status == 1)); then
          ((deferred_count += 1))
        else
          discovery_status=1
        fi
        ;;
      no) ;;
      *)
        printf 'warning: could not determine whether %s supports manual restart\n' \
          "$unit" >&2
        discovery_status=1
        ;;
    esac
  done
  # Report deferrals explicitly: silently skipping would leave the operator
  # believing every upgraded service already runs the new code.
  if ((${#session_units[@]})); then
    ((deferred_count += ${#session_units[@]}))
    printf 'deferred: session-critical units not restarted: %s\n' \
      "${session_units[*]}" >&2
    # Not reboot-only: some distributions' package scripts re-exec user
    # managers themselves, and a manual restart from outside the affected
    # sessions is enough for the rest.
    printf 'hint: restart them manually from outside the affected sessions, or reboot, to load the upgraded code\n' >&2
    # Advisory: this run already reported the deferral, so a failed record
    # only costs the reminder on later runs.
    sysup_record_deferred_restarts "${session_units[@]}" || true
  fi
  if ((${#units[@]} == 0)); then
    if ((discovery_status != 0)); then
      printf 'error: could not fully determine active services from upgraded packages; service restarts are unverified\n' >&2
      return "$discovery_status"
    fi
    if ((deferred_count != 0)); then
      printf 'ok: no active services eligible for immediate restart\n'
      return 0
    fi
    printf 'ok: no active services shipped by upgraded packages\n'
    return 0
  fi

  sysup_log "restarting active services from upgraded packages: ${units[*]}"
  # try-restart, not restart: a unit that stopped between the listing and now
  # must not be started back up by an upgrade.
  sysup_run_as_root systemctl try-restart "${units[@]}" || return

  if ((discovery_status != 0)); then
    printf 'error: could not fully determine active services from upgraded packages; some service restarts are unverified\n' >&2
    return "$discovery_status"
  fi
}
