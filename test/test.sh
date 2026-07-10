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
# `auth status` and `extension list` are pass-through tests — the filter should
# exec real gh without inspecting. The point is "filter doesn't block" (exit ≠ 77),
# not "real gh succeeds" (exit 0). On CI the runner is unauthenticated and the gh
# extensions list is empty, so the real exit codes are 1 and 4 respectively. Use
# assert_allow which checks "not blocked" rather than asserting a specific exit.
assert_allow "auth status"     auth status
assert_allow "extension list"  extension list

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
# #220: meta/orgs paths must also be accepted WITHOUT a leading slash
# (gh api treats `orgs/OWNER` == `/orgs/OWNER`). The owner allowlist is unchanged.
assert_allow "api user (no slash)"                         api user
assert_allow "api licenses/mit (no slash)"                 api licenses/mit
assert_allow "api orgs/test-allowed-org (no slash)"        api orgs/test-allowed-org
assert_allow "api orgs/test-allowed-org/repos (no slash)"  api orgs/test-allowed-org/repos
# security regression: a disallowed org must still block, slash or no slash
assert_block "api orgs/disallowed (no slash) blocked"      api orgs/disallowed-test-owner/repos
assert_block "api /orgs/disallowed blocked"                api /orgs/disallowed-test-owner/repos

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
echo "=== Agent-identity injection ==="
# Stub "real gh" that reports the GH_TOKEN it was handed, so injection is
# directly observable. Stub token command that emits a fixed token.
IDENT_DIR=$(/usr/bin/mktemp -d)
STUB_GH="$IDENT_DIR/stub-gh"
TOK_CMD="$IDENT_DIR/tok-cmd"
EMPTY_TOK_CMD="$IDENT_DIR/empty-tok-cmd"
/bin/cat > "$STUB_GH" <<'EOF'
#!/bin/bash
echo "REALGH_TOKEN=${GH_TOKEN:-<none>}"
exit 0
EOF
/bin/cat > "$TOK_CMD" <<'EOF'
#!/bin/bash
echo "injected-token-xyz"
EOF
/bin/cat > "$EMPTY_TOK_CMD" <<'EOF'
#!/bin/bash
exit 0
EOF
/bin/chmod +x "$STUB_GH" "$TOK_CMD" "$EMPTY_TOK_CMD"

# assert_stdout LABEL EXPECTED_SUBSTRING -- <env KEY=VAL ...> -- <gh args...>
# Runs the filter with the given env, captures stdout, checks the substring.
assert_ident() {
  local label="$1" expect="$2"; shift 2
  local out
  out=$("$@" 2>/dev/null)
  if [[ "$out" == *"$expect"* ]]; then
    PASS=$((PASS+1)); echo "PASS: $label"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $label  (wanted substring '$expect', got '$out')"
  fi
}

# 1. Agent context (marker set) → token injected.
assert_ident "agent marker → token injected" "REALGH_TOKEN=injected-token-xyz" \
  env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$TOK_CMD" \
      GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 \
      "$FILTER" api /user

# 2. Caller-set GH_TOKEN is honored (never overridden), even in agent context.
assert_ident "caller GH_TOKEN honored over injection" "REALGH_TOKEN=caller-abc" \
  env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$TOK_CMD" \
      GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 GH_TOKEN=caller-abc \
      "$FILTER" api /user

# 2b. Caller-set GITHUB_TOKEN is also honored (gh reads both).
assert_ident "caller GITHUB_TOKEN honored" "REALGH_TOKEN=<none>" \
  env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$TOK_CMD" \
      GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 GITHUB_TOKEN=gh-abc \
      "$FILTER" api /user
# (GITHUB_TOKEN set → stage returns early, injects nothing → stub sees no GH_TOKEN)

# 3. Non-agent, non-TTY (detached/cron) → FAIL CLOSED to the bot token, never
#    the ambient credential. In this harness stderr is not a TTY, so rule 4 fires.
assert_ident "no marker + no TTY → fail-closed to bot token" "REALGH_TOKEN=injected-token-xyz" \
  env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$TOK_CMD" \
      GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER \
      "$FILTER" api /user

# 4. Feature OFF (no AGENT_TOKEN_COMMAND) → stage is a no-op even if a marker is
#    present; the ambient credential passes through untouched.
assert_ident "feature off → no injection (ambient credential)" "REALGH_TOKEN=<none>" \
  env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 \
      "$FILTER" api /user

# 5. Fail-closed: AGENT_TOKEN_COMMAND missing/not executable → exit 78, no exec.
env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$IDENT_DIR/does-not-exist" \
    GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 \
    "$FILTER" api /user >/dev/null 2>&1
ec=$?
if [ "$ec" = "78" ]; then PASS=$((PASS+1)); echo "PASS: missing token command → exit 78 (fail-closed)"; \
  else FAIL=$((FAIL+1)); echo "FAIL: missing token command — expected 78, got $ec"; fi

# 6. Fail-closed: AGENT_TOKEN_COMMAND runs but emits nothing → exit 78, no exec.
env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$EMPTY_TOK_CMD" \
    GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 \
    "$FILTER" api /user >/dev/null 2>&1
ec=$?
if [ "$ec" = "78" ]; then PASS=$((PASS+1)); echo "PASS: empty token output → exit 78 (fail-closed)"; \
  else FAIL=$((FAIL+1)); echo "FAIL: empty token output — expected 78, got $ec"; fi

# 6b. Re-entry guard: a misconfigured AGENT_TOKEN_COMMAND that itself shells out
#     to `gh` (without providing a token) must fail closed (exit 78), never loop.
RECURSE_CMD="$IDENT_DIR/recurse-cmd"
/bin/cat > "$RECURSE_CMD" <<EOF
#!/bin/bash
# Simulate a token command that (wrongly) invokes gh — recurses through the shim.
env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$RECURSE_CMD" \\
    GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 "$FILTER" api /user
EOF
/bin/chmod +x "$RECURSE_CMD"
env GH_FILTER_REAL_GH="$STUB_GH" GH_FILTER_AGENT_TOKEN_COMMAND="$RECURSE_CMD" \
    GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER TEST_MARKER=1 \
    "$FILTER" api /user >/dev/null 2>&1
ec=$?
if [ "$ec" = "78" ]; then PASS=$((PASS+1)); echo "PASS: token command recursing into gh → exit 78 (guard, no loop)"; \
  else FAIL=$((FAIL+1)); echo "FAIL: re-entry guard — expected 78, got $ec"; fi

# 7. Human interactive (stderr is a TTY) → NO injection; ambient credential kept.
#    Allocate a pty via `script` so `[ -t 2 ]` is true. Best-effort: if `script`
#    is unavailable the case is skipped rather than failing the suite.
if command -v script >/dev/null 2>&1; then
  tty_out=$(script -q /dev/null env GH_FILTER_REAL_GH="$STUB_GH" \
      GH_FILTER_AGENT_TOKEN_COMMAND="$TOK_CMD" GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER \
      "$FILTER" api /user 2>/dev/null | /usr/bin/tr -d '\r')
  if [[ "$tty_out" == *"REALGH_TOKEN=<none>"* ]]; then
    PASS=$((PASS+1)); echo "PASS: human TTY (no marker) → no injection, ambient credential"
  else
    FAIL=$((FAIL+1)); echo "FAIL: human TTY passthrough  (got '$tty_out')"
  fi
else
  echo "SKIP: human-TTY test (no 'script' binary to allocate a pty)"
fi

/bin/rm -rf "$IDENT_DIR"

echo ""
echo "================================================================"
echo "Total: $((PASS+FAIL)) | Passed: $PASS | Failed: $FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
