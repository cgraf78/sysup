# shellcheck shell=bash
# Keep execution and pending-update queries on the same installed-release
# resolver policy: new dependencies are allowed, package removals are not.
sysup_apt_upgrade() {
  local runner="$1"
  shift
  "$runner" --with-new-pkgs upgrade "$@"
}
