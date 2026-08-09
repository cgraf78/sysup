# shellcheck shell=bash
# OS family vocabulary and detection for the sysup updaters.
#
# Sourced by the `sysup` dispatcher and by each backend. The family names here
# are the durable identifiers: they select a backend command, a human label, and
# the guard each backend runs before touching a package manager.

# The family vocabulary: `family|backend command|human label`, one row per
# supported family. A new family is added here and nowhere else.
#
# A plain table rather than associative arrays because those need bash 4, and
# macOS still ships bash 3.2 as /bin/bash. This file is what tells an
# unsupported host so — it has to survive the oldest shell it can land on and
# print that message, not abort with an unbound-variable error.
_sysup_family_table() {
  printf '%s\n' \
    'arch|archup|Arch Linux' \
    'debian|debup|Debian-based'
}
_sysup_family_field() {
  local want="$1" field="$2" family command label

  while IFS='|' read -r family command label; do
    [[ "$family" == "$want" ]] || continue
    case "$field" in
      command) printf '%s\n' "$command" ;;
      label) printf '%s\n' "$label" ;;
    esac
    return 0
  done <<EOF
$(_sysup_family_table)
EOF

  return 1
}

# Backend command for a family. Read by the dispatcher and the backend guards.
sysup_family_command() {
  _sysup_family_field "$1" command
}

# Human label for a family, used only in messages.
sysup_family_label() {
  _sysup_family_field "$1" label
}

# Filesystem root the OS identification files are read from. Overridable so
# tests can point detection at a fixture tree instead of the live system.
SYSUP_OS_ROOT="${SYSUP_OS_ROOT:-}"

# Print one os-release field. The file is sourced in a subshell because it
# assigns unprefixed names (ID, VERSION, NAME) that would otherwise land in the
# caller's scope.
sysup_os_release_field() {
  local field="$1" path="$SYSUP_OS_ROOT/etc/os-release"

  [[ -r "$path" ]] || return 0
  (
    # shellcheck disable=SC1090,SC1091 # Host file, path varies for tests.
    . "$path"
    case "$field" in
      ID) printf '%s' "${ID:-}" ;;
      ID_LIKE) printf '%s' "${ID_LIKE:-}" ;;
    esac
  )
}

# Print the sysup family for this host; return 1 when it is not supported.
sysup_os_family() {
  local id id_like token

  [[ "$(uname -s 2>/dev/null || true)" == Linux ]] || return 1

  id=$(sysup_os_release_field ID)
  id_like=$(sysup_os_release_field ID_LIKE)

  # ID_LIKE is a space-separated list, so it is deliberately unquoted here.
  # shellcheck disable=SC2086
  for token in "$id" $id_like; do
    case "$token" in
      arch)
        printf 'arch\n'
        return 0
        ;;
      debian | ubuntu)
        printf 'debian\n'
        return 0
        ;;
    esac
  done

  # Derivatives that ship an unhelpful os-release still carry a family marker.
  if [[ -r "$SYSUP_OS_ROOT/etc/arch-release" ]]; then
    printf 'arch\n'
    return 0
  fi
  if [[ -r "$SYSUP_OS_ROOT/etc/debian_version" ]]; then
    printf 'debian\n'
    return 0
  fi

  return 1
}

# Describe the host for error messages when detection fails or mismatches.
sysup_os_description() {
  local id id_like

  id=$(sysup_os_release_field ID || true)
  id_like=$(sysup_os_release_field ID_LIKE || true)
  printf 'ID=%s ID_LIKE=%s' "${id:-unknown}" "${id_like:-unknown}"
}

# Print supported families as a sorted, comma-separated list.
sysup_supported_families() {
  _sysup_family_table | cut -d'|' -f1 | sort | paste -sd, -
}

# Fail unless this host belongs to `family`. Backends call this first so running
# the wrong backend stops before any package manager is invoked.
sysup_require_family() {
  local want="$1" got

  got=$(sysup_os_family || true)
  [[ "$got" == "$want" ]] && return 0

  printf 'error: %s only supports %s hosts; detected %s\n' \
    "${SYSUP_BACKEND_NAME:-$(sysup_family_command "$want")}" \
    "$(sysup_family_label "$want")" \
    "$(sysup_os_description)" >&2
  return 1
}
