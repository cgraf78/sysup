#!/usr/bin/env bash
# provision.sh - prepare a stock distro container image for sysup end-to-end
# runs. Executed inside the container, as root, before it is committed and
# booted with systemd as PID 1.
#
# It installs only what booting systemd and running sysup need, and leaves
# every other package at the image's version: pending updates are what the
# real upgrade run exercises. It never upgrades the whole system.

set -euo pipefail

# Mirror hiccups are the usual CI failure here, and they are transient.
retry() {
  local attempt

  for attempt in 1 2 3; do
    "$@" && return 0
    printf 'provision: attempt %s failed: %s\n' "$attempt" "$*" >&2
    sleep $((attempt * 10))
  done
  return 1
}

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  retry apt-get update
  # needrestart is optional for debup; installing it exercises its restart
  # path, which is the one Debian hosts normally take.
  retry apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus sudo needrestart procps findutils
elif command -v pacman >/dev/null 2>&1; then
  # -Sy without -u: refresh the sync database so these installs resolve, but
  # leave the rest of the image behind for the sysup run to upgrade.
  retry pacman -Sy --needed --noconfirm systemd sudo file pacman-contrib
elif command -v dnf >/dev/null 2>&1; then
  # The needs-restarting plugin lives in dnf5-plugins on dnf5 and in
  # dnf-plugins-core on dnf4.
  if dnf --version 2>/dev/null | grep -q '^dnf5'; then
    plugins=dnf5-plugins
  else
    plugins=dnf-plugins-core
  fi
  retry dnf -y install systemd sudo procps-ng findutils "$plugins"
elif command -v zypper >/dev/null 2>&1; then
  retry zypper --non-interactive refresh
  retry zypper --non-interactive install --no-recommends \
    systemd sudo procps findutils
else
  printf 'provision: no supported package manager in this image\n' >&2
  exit 1
fi

# A stable path for the container entrypoint: distributions install systemd
# under /usr/lib or, before merged /usr, /lib.
for init in /usr/lib/systemd/systemd /lib/systemd/systemd; do
  if [[ -x "$init" ]]; then
    ln -sf "$init" /sysup-init
    break
  fi
done
[[ -x /sysup-init ]] || {
  printf 'provision: systemd binary not found\n' >&2
  exit 1
}

# A non-root operator, so the sudo path (including the credential keeper) runs
# as it does on a workstation. NOPASSWD because CI has no one to type one.
useradd --create-home --shell /bin/bash sysupci
install -d -m 0750 /etc/sudoers.d
printf 'sysupci ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/sysupci
chmod 0440 /etc/sudoers.d/sysupci
