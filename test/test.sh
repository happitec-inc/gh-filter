#!/bin/bash
# test.sh: gh-filter test harness. Exercises allow + block paths without
# spamming Pushover or touching real GitHub state (where possible).
#
# Run from the repo root:
#   ./test/test.sh

set -uo pipefail

FILTER="$(cd "$(dirname "$0")/.." && pwd)/gh-filter"
export GH_FILTER_NOTIFY=/usr/bin/true

# The default allowlist is empty (gh-filter loads it from a config file).
# Write a temp config so the allow-path tests have something to allow against.
TEST_CONFIG=$(/usr/bin/mktemp -t gh-filter-test-config)
trap '/bin/rm -f "$TEST_CONFIG"' EXIT
/bin/echo "ALLOWED_OWNERS=test-allowed-org" > "$TEST_CONFIG"
export GH_FILTER_CONFIG="$TEST_CONFIG"

if [ ! -x "$FILTER" ]; then
  echo "test.sh: ERROR — $FILTER missing or not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

assert_exit() {
  local label="$1"; shift
  local expected="$1"; shift
  "$FILTER" "$@" >/dev/null 2>&1
  local actual=$?
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1))
    echo "PASS: $label"
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $label  (expected exit $expected, got $actual)"
    echo "       cmd: gh $*"
  fi
}

assert_block() {
  local label="$1"; shift
  assert_exit "$label" 77 "$@"
}

assert_allow() {
  # "Allow" means NOT blocked (exit ≠ 77). The real gh may exit 0 (success),
  # 1 (rate-limited / not-found / etc.), but never 77 if our filter passed
  # the call through.
  local label="$1"; shift
  "$FILTER" "$@" >/dev/null 2>&1
  local actual=$?
  if [ "$actual" != "77" ]; then
    PASS=$((PASS+1))
    echo "PASS: $label (passed through, gh exit $actual)"
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $label  (was blocked unexpectedly)"
    echo "       cmd: gh $*"
  fi
}

echo "=== Pass-through subcommands ==="
assert_exit "--version" 0 --version
assert_exit "--help" 0 --help
assert_exit "auth status" 0 auth status
assert_exit "extension list" 0 extension list

echo ""
echo "=== Block: third-party --repo flag ==="
assert_block "issue list --repo disallowed/X"    issue list --repo disallowed-test-owner/test-repo --limit 1
assert_block "issue create --repo disallowed/X"  issue create --repo disallowed-test-owner/test-repo --title t --body b
assert_block "issue list -R disallowed/X"        issue list -R disallowed-test-owner/test-repo
assert_block "issue list --repo=disallowed/X"    issue list --repo=disallowed-test-owner/test-repo
assert_block "pr create --repo disallowed/X"     pr create --repo disallowed-test-owner/test-repo --title t --body b

echo ""
echo "=== Block: third-party via api path ==="
assert_block "api /repos/disallowed/X"            api /repos/disallowed-test-owner/test-repo
assert_block "api repos/disallowed/X (no slash)"  api repos/disallowed-test-owner/test-repo/issues
assert_block "api -X POST /repos/disallowed/X"    api -X POST /repos/disallowed-test-owner/test-repo/issues

echo ""
echo "=== Block: positional repo arg ==="
assert_block "repo view disallowed/X"   repo view disallowed-test-owner/test-repo
assert_block "repo clone disallowed/X"  repo clone disallowed-test-owner/test-repo

echo ""
echo "=== Block: structural denies ==="
assert_block "api graphql"                  api graphql -f query="query{}"
assert_block "extension install"            extension install disallowed-test-owner/test-extension
# The "no target detectable" case must run from a directory with no git
# remote, otherwise the filter's fallback would resolve a target and either
# allow or block based on the remote's owner. Run from a tmp non-git dir.
(
  cd "$(/usr/bin/mktemp -d)"
  "$FILTER" issue list >/dev/null 2>&1
  ec=$?
  if [ "$ec" = "77" ]; then
    PASS=$((PASS+1))
    echo "PASS: no target detectable (in tmp non-git dir) → blocked"
  else
    FAIL=$((FAIL+1))
    echo "FAIL: no target detectable — expected exit 77, got $ec"
  fi
)

echo ""
echo "=== Allow: configured owner via --repo ==="
assert_allow "issue list --repo test-allowed-org/X"  issue list --repo test-allowed-org/test-repo --limit 1
assert_allow "api /repos/test-allowed-org/X"          api /repos/test-allowed-org/test-repo
assert_allow "repo view test-allowed-org/X"           repo view test-allowed-org/test-repo

echo ""
echo "=== Allow: meta api paths ==="
assert_allow "api /user"                    api /user
assert_allow "api /orgs/test-allowed-org"   api /orgs/test-allowed-org

echo ""
echo "=== Git-remote fallback ==="
TMP=$(/usr/bin/mktemp -d)
(
  cd "$TMP"
  /usr/bin/git init -q
  /usr/bin/git remote add origin git@github.com:disallowed-test-owner/test-repo.git
  "$FILTER" issue list >/dev/null 2>&1
  ec=$?
  if [ "$ec" = "77" ]; then
    echo "PASS: git-remote third-party detected → blocked"
  else
    echo "FAIL: git-remote third-party not blocked (exit $ec)"
  fi
)
/bin/rm -rf "$TMP"

TMP=$(/usr/bin/mktemp -d)
(
  cd "$TMP"
  /usr/bin/git init -q
  /usr/bin/git remote add origin git@github.com:test-allowed-org/test-repo.git
  "$FILTER" issue list >/dev/null 2>&1
  ec=$?
  if [ "$ec" != "77" ]; then
    echo "PASS: git-remote allowed-owner detected → passed through (exit $ec)"
  else
    echo "FAIL: git-remote allowed-owner blocked"
  fi
)
/bin/rm -rf "$TMP"

echo ""
echo "=== Unconfigured filter (no allowlist) ==="
# Point GH_FILTER_CONFIG at a path that doesn't exist. The filter should
# block any repo-targeted call with exit 77 and the no-allowlist reason,
# NOT crash with set-u + empty-array errors.
NONEXISTENT=$(/usr/bin/mktemp -t gh-filter-no-config)
/bin/rm -f "$NONEXISTENT"  # ensure absence
GH_FILTER_CONFIG="$NONEXISTENT" "$FILTER" issue list --repo any/repo >/dev/null 2>&1
ec=$?
if [ "$ec" = "77" ]; then
  PASS=$((PASS+1))
  echo "PASS: missing config → exit 77 (fails closed, not crash)"
else
  FAIL=$((FAIL+1))
  echo "FAIL: missing config — expected exit 77, got $ec"
fi

# Empty config file (no ALLOWED_OWNERS line). Same expectation.
EMPTY_CONFIG=$(/usr/bin/mktemp -t gh-filter-empty-config)
: > "$EMPTY_CONFIG"
GH_FILTER_CONFIG="$EMPTY_CONFIG" "$FILTER" issue list --repo any/repo >/dev/null 2>&1
ec=$?
/bin/rm -f "$EMPTY_CONFIG"
if [ "$ec" = "77" ]; then
  PASS=$((PASS+1))
  echo "PASS: empty config → exit 77 (fails closed, not crash)"
else
  FAIL=$((FAIL+1))
  echo "FAIL: empty config — expected exit 77, got $ec"
fi

# Config with ALLOWED_OWNERS= (empty value). Same expectation.
BLANK_CONFIG=$(/usr/bin/mktemp -t gh-filter-blank-config)
/bin/echo "ALLOWED_OWNERS=" > "$BLANK_CONFIG"
GH_FILTER_CONFIG="$BLANK_CONFIG" "$FILTER" issue list --repo any/repo >/dev/null 2>&1
ec=$?
/bin/rm -f "$BLANK_CONFIG"
if [ "$ec" = "77" ]; then
  PASS=$((PASS+1))
  echo "PASS: ALLOWED_OWNERS= (blank) → exit 77 (fails closed, not crash)"
else
  FAIL=$((FAIL+1))
  echo "FAIL: ALLOWED_OWNERS= (blank) — expected exit 77, got $ec"
fi

echo ""
echo "================================================================"
echo "Total: $((PASS+FAIL)) | Passed: $PASS | Failed: $FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
