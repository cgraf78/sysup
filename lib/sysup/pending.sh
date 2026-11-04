# shellcheck shell=bash
# Repository metadata queries have no upgrade or service-management side effects.

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
    debian) output=$(LC_ALL=C apt list --upgradable 2>"$errors") || status=$? ;;
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
      parsed=$(printf '%s\n' "$output" | awk 'NF == 0 || $0 == "Listing..." { next } $1 !~ /\// || NF < 2 { exit 1 } { split($1, p, "/"); print p[1], $2 }') || {
        printf 'error: unrecognized apt update listing\n' >&2
        return 1
      }
      ;;
  esac
  [[ -z "$parsed" ]] || printf '%s\n' "$parsed"
  return 0
}
