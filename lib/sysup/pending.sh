# shellcheck shell=bash
# Repository metadata queries have no upgrade or service-management side effects.

# shellcheck source=apt.sh
. "${BASH_SOURCE[0]%/*}/apt.sh"

sysup_pending() {
  local family="$1" action="$2" output status=0 errors parsed
  local -a elevated=()

  case "$family" in
    arch | debian) ;;
    *)
      printf 'error: pending updates are not supported on %s\n' "$family" >&2
      return 1
      ;;
  esac
  if [[ "$action" == --refresh-updates ]]; then
    ((EUID == 0)) || elevated=(sudo)
    case "$family" in
      arch) ${elevated[@]+"${elevated[@]}"} pacman -Sy >/dev/null ;;
      debian) ${elevated[@]+"${elevated[@]}"} apt-get -o APT::Update::Error-Mode=any update >/dev/null ;;
    esac
    return
  fi

  # Pacman returns 1 for both an empty result and a query error. Capture its
  # diagnostics separately so an error cannot masquerade as an empty result.
  errors=$(mktemp) || return 1
  case "$family" in
    arch) output=$(LC_ALL=C pacman -Qu 2>"$errors") || status=$? ;;
    # Quiet simulation emits only pkgSimulate operations. Let APT's resolver
    # exclude phasing, holds and dependency-kept candidates instead of treating
    # every newer repository version as an update this host can apply.
    debian)
      # APT otherwise adds a non-root notice on stdout even at quiet level 2.
      # Keep that explanatory prose out of the operation stream; genuine query
      # diagnostics still flow through stderr, and caller limits are documented.
      output=$(LC_ALL=C sysup_apt_upgrade apt-get --simulate --quiet=2 \
        -o APT::Get::Show-User-Simulation-Note=false 2>"$errors") || status=$?
      ;;
  esac
  if ((status != 0)); then
    if [[ "$family" == arch && "$status" == 1 && ! -s "$errors" && -z "$output" ]]; then
      rm -f "$errors"
      return 0
    fi
    cat "$errors" >&2
    rm -f "$errors"
    return "$status"
  fi
  cat "$errors" >&2
  rm -f "$errors"

  # Buffer the complete parsed output before printing: malformed or partial
  # listings must not be published as a valid empty or incomplete inventory.
  case "$family" in
    arch)
      parsed=$(printf '%s\n' "$output" | awk 'NF == 0 { next } NF != 4 || $3 != "->" { exit 1 } { print $1, $4 }') || {
        printf 'error: unrecognized pacman update listing\n' >&2
        return 1
      }
      ;;
    debian)
      # Inst/Conf are untranslated pkgSimulate records, not localized summaries.
      # Their release description is opaque; APT can also append temporary
      # dependency annotations. Only Inst contributes a package/version row.
      parsed=$(printf '%s\n' "$output" | awk '
        NF == 0 { next }
        $1 != "Inst" && $1 != "Conf" { exit 1 }
        {
          if ($2 !~ /^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$/) exit 1
          candidate = $0
          sub(/^[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", candidate)
          if ($1 == "Inst" && candidate ~ /^\[/) {
            if (!sub(/^\[[^][[:space:]]+\][[:space:]]+/, "", candidate)) exit 1
          }
          if (candidate !~ /^\([^()[:space:]]+[[:space:]].*\)([[:space:]]+\[[^][]*\])*[[:space:]]*$/) exit 1
          version = candidate
          sub(/^\(/, "", version)
          sub(/[[:space:]].*$/, "", version)
          if (version ~ /[][]/) exit 1
          if ($1 == "Inst") print $2, version
        }
      ') || {
        printf 'error: unrecognized apt upgrade plan\n' >&2
        return 1
      }
      ;;
  esac
  [[ -z "$parsed" ]] || printf '%s\n' "$parsed"
  return 0
}
