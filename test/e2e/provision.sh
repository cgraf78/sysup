#!/usr/bin/env bash
# provision.sh - prepare a stock distro container image for sysup end-to-end
# runs. Executed inside the container, as root, before it is committed and
# booted with systemd as PID 1.
#
# It installs only what booting systemd and running sysup need, and leaves
# every other package at the image's version: pending updates are what the
# real upgrade run exercises. It never upgrades the whole system, except on
# Arch (see the pacman branch): a partial upgrade there is unsupported and
# breaks on soname bumps. Arch upgrades coupled packages together, leaving
# one safe leaf update for the sysup run when available.

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

# Leave an unrequired update for sysup when the held-back transaction
# resolves. Query names instead of parsing pacman's localized package info.
pick_holdback() {
  local pkg updates leaves tried=0
  # Pacman returns 1 for an empty query as well as errors. Either way, a
  # full upgrade below is safe and supplies the authoritative failure status.
  updates=$(pacman -Quq 2>/dev/null) || return 0
  leaves=$(pacman -Qqt 2>/dev/null) || return 0
  while IFS= read -r pkg; do
    [[ -n $pkg ]] || continue
    # Explicit install targets override --ignore and cannot be held back.
    [[ " $* " != *" $pkg "* ]] || continue
    case $pkg in
      systemd* | glibc | openssl | pacman | linux | dbus | mkinitcpio | base) continue ;;
    esac
    [[ $'\n'"$leaves"$'\n' == *$'\n'"$pkg"$'\n'* ]] || continue
    # Bound expensive resolver probes, not the package scan: the first ten
    # outdated packages may all be coupled libraries with no safe holdback.
    ((tried += 1))
    if pacman -Su --print --ignore "$pkg" \
      "$@" >/dev/null 2>&1; then
      printf '%s\n' "$pkg"
      return 0
    fi
    ((tried < 10)) || break
  done <<<"$updates"
  return 0
}

# Refresh and provision Arch without leaving coupled packages out of date.
provision_arch() {
  local holdback
  local packages=(systemd sudo file pacman-contrib)
  # Refresh first, then upgrade all coupled packages together: partial Arch
  # upgrades break on soname bumps. A rejected holdback falls back to the
  # full transaction rather than making optional test coverage fatal.
  retry pacman -Sy
  holdback=$(pick_holdback "${packages[@]}")
  if [[ -n $holdback ]]; then
    if retry pacman -Su --needed --noconfirm --ignore "$holdback" \
      "${packages[@]}"; then
      printf 'provision: holding back %s for the sysup run\n' "$holdback"
    else
      retry pacman -Syu --needed --noconfirm "${packages[@]}"
    fi
  else
    printf 'provision: no safe pending update; upgrading all packages\n'
    retry pacman -Syu --needed --noconfirm "${packages[@]}"
  fi
}

# The mock-only unit suite sources the same provisioning functions. Sourcing
# must never configure the host; only executing this script enters setup.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  return 0
fi

set -euo pipefail

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  retry apt-get update
  # needrestart is optional for debup; installing it exercises its restart
  # path, which is the one Debian hosts normally take.
  retry apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus sudo needrestart procps findutils
elif command -v pacman >/dev/null 2>&1; then
  provision_arch
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

# A container has no virtual terminals or serial ports, so a getty on one
# fails, restarts, and can reach its start limit at any point, including in the
# middle of a run, where sysup would rightly report it as a failed unit; which
# image and which moment depends on timing, so CI flaked across distributions.
# Mask every getty unit systemd can start, templates included so no instance
# runs. A /dev/null link is what `systemctl mask` writes, and it needs no
# running systemd.
install -d /etc/systemd/system
for unit in getty@.service serial-getty@.service console-getty.service \
  container-getty@.service; do
  ln -sf /dev/null "/etc/systemd/system/$unit"
done

# A non-root operator, so the sudo path (including the credential keeper) runs
# as it does on a workstation. NOPASSWD because CI has no one to type one.
useradd --create-home --shell /bin/bash sysupci
install -d -m 0750 /etc/sudoers.d
printf 'sysupci ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/sysupci
chmod 0440 /etc/sudoers.d/sysupci
