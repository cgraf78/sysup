# shellcheck shell=bash
# rpm database helpers shared by the rpm-based sysup backends.
#
# dnfup and zypup drive different package managers over the same rpm
# database, so the package snapshot, package file listing, and pending
# config-file scan live here once rather than in each backend.

# Root of the pending config-file scan. Overridable so tests can point it at a
# fixture tree instead of the live system.
SYSUP_RPM_CONFFILE_ROOT="${SYSUP_RPM_CONFFILE_ROOT:-/etc}"

# Print the installed packages as sorted "<NAME.ARCH> <EPOCHNUM:VERSION-RELEASE>"
# rows, the format the driver's diff consumes.
#
# NAME.ARCH, not NAME: a multilib host installs both arches of a library, and a
# bare name would collapse their two versions into one, hiding an upgrade.
# rpm accepts the same NAME.ARCH form when listing files.
#
# Installonly (multiversion) packages, such as kernels, keep several versions
# under one NAME.ARCH. The driver's diff keys on the name, so each is written
# as one line holding its comma-joined versions: an unchanged kernel set then
# compares equal, and an added or removed kernel still shows as a change. The
# C locale keeps a package's rows adjacent; other collations can ignore
# punctuation.
#
# gpg-pubkey entries are imported signing keys, not packages: they have no
# architecture, several share one name, and `rpm -ql` cannot list them. A
# newly imported key would otherwise look like an upgrade the restart step
# cannot resolve.
sysup_rpm_snapshot() {
  rpm -qa --qf '%{NAME}.%{ARCH} %{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' |
    while read -r pkg version; do
      [[ -n "${pkg:-}" ]] || continue
      [[ "$pkg" != *.'(none)' ]] || continue
      printf '%s %s\n' "$pkg" "$version"
    done | LC_ALL=C sort | sysup_rpm_join_versions
}

# Merge adjacent rows of one package into "<pkg> <v1>,<v2>,...".
sysup_rpm_join_versions() {
  local pkg version current="" versions=""

  while read -r pkg version; do
    if [[ "$pkg" == "$current" ]]; then
      versions+=",$version"
      continue
    fi
    [[ -z "$current" ]] || printf '%s %s\n' "$current" "$versions"
    current="$pkg"
    versions="$version"
  done
  [[ -z "$current" ]] || printf '%s %s\n' "$current" "$versions"
}

# Print the files one package owns. "$1" is a NAME.ARCH from the snapshot.
sysup_rpm_package_files() {
  rpm -ql "$1"
}

# Config files an upgrade wrote beside a locally modified copy (.rpmnew), or
# saved when it replaced one (.rpmsave, .rpmorig). Either way the operator has
# a merge to review. Runs unprivileged, so a root-only directory can make it
# incomplete; the caller reports that rather than escalating to list filenames.
sysup_rpm_pending_conffiles() {
  find "$SYSUP_RPM_CONFFILE_ROOT" \
    \( -name '*.rpmnew' -o -name '*.rpmsave' -o -name '*.rpmorig' \) \
    -type f -print 2>/dev/null | sort
}

# Advisory report of the pending config files. Always returns 0: a merge
# waiting for review is the expected result of a successful upgrade, and an
# incomplete scan is reported as such rather than failing the run.
sysup_rpm_report_pending_conffiles() {
  local -a conffiles=()
  local listing="" status=0

  listing="$(sysup_rpm_pending_conffiles)" || status=$?
  if [[ -n "$listing" ]]; then
    mapfile -t conffiles <<<"$listing"
  fi
  if ((${#conffiles[@]})); then
    printf '\nconfig files awaiting a manual merge:\n'
    printf '  %s\n' "${conffiles[@]}"
  fi
  if ((status != 0)); then
    printf 'warning: could not completely scan for config files awaiting a manual merge\n' >&2
  elif ((${#conffiles[@]} == 0)); then
    printf 'ok: no config files awaiting a manual merge\n'
  fi
  return 0
}
