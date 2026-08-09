#!/usr/bin/env bash
# Small test harness owned by sysup. Keeping this local prevents the extracted
# suites from silently depending on dotfiles' much broader test environment.

PASS=0
FAIL=0

_pass() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

_fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s\n' "$1" >&2
}

_assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected '$expected', got '$actual')"
  fi
}

_assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected to contain '$expected', got '$actual')"
  fi
}

_assert_not_contains() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$actual" != *"$unexpected"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (should not contain '$unexpected')"
  fi
}

# Every fixture is created beneath one validated root. The EXIT trap therefore
# has one narrow deletion target instead of tracking arbitrary caller paths.
_SYSUP_TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sysup-test.XXXXXXXX") || {
  printf 'sysup test: could not create temporary root\n' >&2
  exit 1
}
case "$_SYSUP_TEST_TMP_ROOT" in
  "${TMPDIR:-/tmp}"/sysup-test.*) ;;
  *)
    printf 'sysup test: unsafe temporary root: %s\n' "$_SYSUP_TEST_TMP_ROOT" >&2
    exit 1
    ;;
esac
[[ -d "$_SYSUP_TEST_TMP_ROOT" ]] || {
  printf 'sysup test: temporary root is not a directory: %s\n' \
    "$_SYSUP_TEST_TMP_ROOT" >&2
  exit 1
}

_sysup_test_cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$_SYSUP_TEST_TMP_ROOT"
  exit "$status"
}
trap _sysup_test_cleanup EXIT

_tmpdir() {
  local path
  path=$(mktemp -d "$_SYSUP_TEST_TMP_ROOT/dir.XXXXXXXX") || {
    printf 'sysup test: could not create suite temporary directory\n' >&2
    return 1
  }
  case "$path" in
    "$_SYSUP_TEST_TMP_ROOT"/*) ;;
    *)
      printf 'sysup test: unsafe suite temporary directory: %s\n' "$path" >&2
      return 1
      ;;
  esac
  [[ -d "$path" ]] || {
    printf 'sysup test: suite temporary directory does not exist: %s\n' \
      "$path" >&2
    return 1
  }
  printf '%s\n' "$path"
}

_tmpfile() {
  local path
  path=$(mktemp "$_SYSUP_TEST_TMP_ROOT/file.XXXXXXXX") || {
    printf 'sysup test: could not create suite temporary file\n' >&2
    return 1
  }
  case "$path" in
    "$_SYSUP_TEST_TMP_ROOT"/*) ;;
    *)
      printf 'sysup test: unsafe suite temporary file: %s\n' "$path" >&2
      return 1
      ;;
  esac
  [[ -f "$path" ]] || {
    printf 'sysup test: suite temporary file does not exist: %s\n' \
      "$path" >&2
    return 1
  }
  printf '%s\n' "$path"
}

_mock_bin() {
  _tmpdir
}

_test_summary() {
  printf '\n================================\n'
  printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
  printf '================================\n'
  [[ "$FAIL" -eq 0 ]] && exit 0
  exit 1
}
