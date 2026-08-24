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
/bin/echo "ALLOWED_OWNERS=test-allowed-org" > "$TEST_CONFIG"
export GH_FILTER_CONFIG="$TEST_CONFIG"

# Pin the real-gh side of every call to a stub, for the whole suite.
#
# This closes a class, not a case. A BLOCK assertion execs the real binary in
# exactly the world it exists to detect — the one where the filter fails to
# block — and eight of them name mutating operations (`issue create`,
# `pr create`, `repo fork`, `project delete|item-add|item-delete`,
# `api -X POST .../issues`, `extension install`). Measured: in the pre-PR world
# all three `project` write verbs came back exit 0, i.e. reached the binary,
# before the assertion was evaluated. Under CI that is the real `gh`.
#
# What saved them until now is that `disallowed-test-owner` and
# `test-allowed-org` do not exist on GitHub (both 404). That is a real control
# but an implicit one, and "it did not land because the target was fictional"
# is the same standard as "it deleted nothing because the token had no user" —
# luck wearing a control's clothes. The stub makes the class unreachable.
STUB_REAL_GH=$(/usr/bin/mktemp -t gh-filter-test-stub)
/bin/cat > "$STUB_REAL_GH" <<'STUB'
#!/bin/sh
# Stands in for the real `gh`. Exits 0: allow-path assertions check "not 77",
# and the `--version`/`--help` pass-through cases assert exit 0 specifically.
# Nothing this suite runs can reach GitHub.
exit 0
STUB
/bin/chmod +x "$STUB_REAL_GH"
trap '/bin/rm -f "$TEST_CONFIG" "$STUB_REAL_GH"' EXIT
export GH_FILTER_REAL_GH="$STUB_REAL_GH"

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

# Run one call from inside a throwaway checkout whose remote is an ALLOWLISTED
# owner, and assert the verdict. This fixture is the point, not a detail: the
# cwd-remote fallback only *launders* a foreign target when the local checkout
# is allowlisted, which is the normal agent state. Assertions run from the
# suite's own directory block for the wrong reason (its remote is not in the
# test allowlist) and so stay green through the very regression they name.
assert_in_allowlisted_checkout() {
  local label="$1"; shift
  local expected="$1"; shift
  local tmp; tmp=$(/usr/bin/mktemp -d)
  (
    cd "$tmp"
    /usr/bin/git init -q
    /usr/bin/git remote add origin git@github.com:test-allowed-org/test-repo.git
    "$FILTER" "$@" >/dev/null 2>&1
  )
  local ec=$?
  /bin/rm -rf "$tmp"
  if [ "$expected" = "block" ] && [ "$ec" = "77" ]; then
    PASS=$((PASS+1)); echo "PASS: $label (blocked from allowlisted checkout)"
  elif [ "$expected" = "allow" ] && [ "$ec" != "77" ]; then
    PASS=$((PASS+1)); echo "PASS: $label (passed through, gh exit $ec)"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $label  (expected $expected, exit $ec)"
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
# --- org-targeted subcommands (--org OWNER, no repo to parse) ---------------
# `gh secret set --org X`, `gh variable set --org X`, `gh ruleset ... --org X`
# have no OWNER/NAME anywhere in argv. Before these were recognised, every such
# call fell through to the generic "could not determine target" deny — a false
# block on a legal call against an allowlisted owner.
assert_allow "secret list --org allowed"         secret list --org test-allowed-org
assert_allow "secret list --org=allowed"         secret list --org=test-allowed-org
assert_allow "variable list --org allowed"       variable list --org test-allowed-org
# --org only names the TARGET for org-operating subcommands. `gh repo fork --org X`
# names the fork DESTINATION while the write lands on the foreign upstream, and
# `gh repo read-file -o` is --output. Scoping is what keeps both honest.
assert_block "repo fork foreign/x --org allowed"  repo fork disallowed-test-owner/repo --org test-allowed-org
assert_allow "repo read-file -o out.txt -R allowed/x" repo read-file -o out.txt -R test-allowed-org/x README.md

# Attached shorthand. gh accepts `-oORG` and `-o=ORG` and routes them to the
# org; recognising only `-o ORG` left the target unset, so the cwd-remote
# fallback decided the verdict and a foreign org passed through from any
# allowlisted checkout. Same gap existed for `-R`.
assert_allow "secret list -oallowed (attached)"   secret list -otest-allowed-org
assert_allow "secret list -o=allowed"             secret list -o=test-allowed-org
assert_block "secret list -odisallowed (attached)" secret list -odisallowed-test-owner
assert_block "secret list -o=disallowed"          secret list -o=disallowed-test-owner
assert_block "issue list -Rdisallowed (attached)"  issue list -Rdisallowed-test-owner/test-repo

# --repo and --org are not mutually exclusive for secret/variable: gh ignores
# --repo and hits the org. The org must therefore decide the verdict, or an
# allowlisted repo launders a foreign org's call.
assert_block "secret list -R allowed/x -o disallowed" secret list -R test-allowed-org/x -o disallowed-test-owner
assert_allow "secret list -R disallowed/x -o allowed" secret list -R disallowed-test-owner/x -o test-allowed-org

assert_block "secret list --org disallowed"      secret list --org disallowed-test-owner
assert_block "secret list --org=disallowed"      secret list --org=disallowed-test-owner
assert_block "variable list --org disallowed"    variable list --org disallowed-test-owner

# --- `--owner`, the long form of -o on org-targeting subcommands ------------
# Receipt: `gh attestation verify --help` documents
#   `-o, --owner string   GitHub organization to scope attestation lookup by`
# so --owner names the TARGET here exactly as -o does. Before the parser
# recognised it, TARGET_ORG stayed empty and detection fell through to the
# cwd-remote fallback: `attestation verify --owner <foreign>` was ALLOWED from
# any allowlisted checkout while `-o <foreign>` blocked.
assert_allow "attestation verify --owner allowed"    attestation verify --owner test-allowed-org /nonexistent-subject
assert_allow "attestation verify --owner=allowed"    attestation verify --owner=test-allowed-org /nonexistent-subject
assert_block "attestation verify --owner disallowed" attestation verify --owner disallowed-test-owner /nonexistent-subject
assert_block "attestation verify --owner=disallowed" attestation verify --owner=disallowed-test-owner /nonexistent-subject

# --- `gh project`: --owner on 19 subcommands, 11 of them writes -------------
# Receipt: `gh project item-add --help` documents
#   `--owner string   Login of the owner. Use "@me" for the current user.`
# `project` was absent from ORG_SUBCMD, so --owner went unparsed and the
# cwd-remote fallback gated these on the local checkout. The write verbs are
# the ones that matter: item-add/item-delete/delete mutate a project owned by
# whatever org --owner names.
assert_allow "project list --owner allowed"       project list --owner test-allowed-org
# These MUST run from an allowlisted checkout to mean anything. Measured: run
# from the suite's own directory they pass even with `project` absent from
# ORG_SUBCMD and the fail-closed guard removed — the pre-PR world — because the
# suite's remote is not in the test allowlist, so the fallback blocks for an
# unrelated reason. From an allowlisted checkout they go red in that world,
# which is what makes them a guard on the write verbs.
assert_in_allowlisted_checkout "project delete --owner disallowed"   block project delete 1 --owner disallowed-test-owner
assert_in_allowlisted_checkout "project item-add --owner=disallowed" block project item-add 1 --owner=disallowed-test-owner --url https://example.invalid/x
assert_in_allowlisted_checkout "project item-delete -odisallowed"    block project item-delete 1 -odisallowed-test-owner --id X

# `--owner @me` names the authenticated identity, not a third party. It will
# never appear in an allowlist, so it must be allowed explicitly rather than
# gated or inferred — otherwise this is the third false-block of this PR.
assert_allow "project list --owner @me"           project list --owner @me

# --- `search` / `skill search`: --owner is a `strings` (list) flag ----------
# Receipt: `gh search repos --help` gives `--owner strings   Filter on owner`,
# and none of the six has an `-o` shorthand. `search issues --owner <org>` is
# the routine pre-file duplicate scan, so a false block here is expensive.
assert_allow "search issues --owner allowed"      search issues --owner test-allowed-org is:open
assert_allow "search repos --owner=allowed"       search repos --owner=test-allowed-org
assert_allow "skill search --owner allowed"       skill search --owner test-allowed-org
assert_block "search repos --owner disallowed"    search repos --owner disallowed-test-owner
assert_block "search code --owner disallowed"     search code --owner disallowed-test-owner foo

# A comma-separated list is legal for a `strings` flag. Every element is gated,
# so a list mixing an allowlisted owner with a foreign one is blocked and names
# the offending element — comparing the raw string would have false-blocked the
# all-allowed case and told you nothing about the mixed one.
assert_allow "search repos --owner allowed,allowed"    search repos --owner test-allowed-org,test-allowed-org
assert_block "search repos --owner allowed,disallowed" search repos --owner test-allowed-org,disallowed-test-owner

# --repo is the same `strings` list on the same commands. This block case is
# the discriminating one of the pair: with the raw string compared, `%%/*`
# yields the FIRST element's owner, so `<allowed>/x,<foreign>/y` was ALLOWED
# while the same call without a comma blocked. (The --owner block case above
# cannot discriminate — a raw comma-joined string matches no allowlist entry,
# so it blocks either way. Only its allow twin proves the split runs.)
assert_block "search --repo allowed/x,disallowed/y" search code --repo test-allowed-org/x,disallowed-test-owner/y foo
# Twin of the case above, and NOT a discriminator: raw comparison takes the
# first element's owner, which is allowlisted here, so this passes with or
# without the split. Kept as the blast-radius half of the pair — it is what
# would go red if the split ever over-refused an all-allowed list.
assert_allow "search --repo allowed/x,allowed/y"    search code --repo test-allowed-org/x,test-allowed-org/y foo
assert_allow "--owner allowed, (trailing comma)"    search repos --owner test-allowed-org,

# A value that yields NO elements must deny, not fall through. The first
# version of the split put `deny` inside the loop and `exec` after it, so an
# empty loop reached the exec: measured ALLOW. A gate whose safe answer depends
# on its loop body running is not a gate.
assert_block "--org , (separators only)"            secret set FOO --org , -R disallowed-test-owner/x
assert_block "--org ,, (separators only)"           secret list --org ,,

# `-o` is `--output` on `repo read-file`, which is why `repo` stays out of the
# org-subcommand list. Guarding `-o` unconditionally reintroduced that exact
# collision from the other side and false-blocked the canonical use.
# These must run from an allowlisted checkout: `repo read-file` with no `-R`
# targets the repo you are standing in, so from the suite's own directory they
# block on the cwd owner and say nothing about `-o`.
assert_in_allowlisted_checkout "repo read-file -o out.txt" allow repo read-file -o /dev/null README.md
assert_in_allowlisted_checkout "repo read-file -oout.txt"  allow repo read-file -o/dev/null README.md

# LAST occurrence wins, matching gh (`gh browse -R a/x -R b/y -n` targets b/y).
# Breaking on the first match gated these on the harmless value while gh would
# have targeted the foreign one.
assert_block "--owner @me then foreign"           project delete 1 --owner @me --owner disallowed-test-owner
assert_block "--org allowed then foreign"         secret list --org test-allowed-org --org disallowed-test-owner
assert_block "-R allowed then foreign"            issue list -R test-allowed-org/x -R disallowed-test-owner/y
# NOTE: an allow case must never name a mutating verb — `assert_allow` passing
# a call through to `gh` is the whole point of the assertion, and
# `gh project delete` takes no confirmation flag. Read-only verbs only.
#
# The other half of that rule: a BLOCK case execs the binary too, in the world
# where the filter has regressed — which is the world block cases exist for. Two
# invariants keep that safe, and both are required: every fixture owner must be
# one that does not exist on GitHub, and the suite pins GH_FILTER_REAL_GH to a
# stub (see the top of this file).
assert_allow "project view --owner=@me"           project view 1 --owner=@me --format json

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
#
# The `cd` is confined to a subshell, but the PASS/FAIL accounting is NOT:
# `PASS=$((PASS+1))` inside `( ... )` mutates a child shell and is discarded,
# so this assertion used to print FAIL while the suite still reported
# `Failed: 0` and exited 0. Measured: forcing the FAIL branch produced
# "FAIL: no target detectable" on stdout alongside a total that counted
# neither it nor the two git-remote assertions (61 PASS lines printed, "Total:
# 59" reported) and exit 0. Keep the subshell around the `cd` only; count in the
# parent.
( cd "$(/usr/bin/mktemp -d)" && "$FILTER" issue list ) >/dev/null 2>&1
ec=$?
if [ "$ec" = "77" ]; then
  PASS=$((PASS+1))
  echo "PASS: no target detectable (in tmp non-git dir) → blocked"
else
  FAIL=$((FAIL+1))
  echo "FAIL: no target detectable — expected exit 77, got $ec"
fi

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
# Both git-remote fixtures below used to `echo "PASS:"` / `echo "FAIL:"` with no
# counter at all, inside a subshell. They printed a verdict the suite never
# tallied: 61 PASS lines were emitted while the total read 59, and a FAIL here
# left `Failed: 0` and exit 0. That silence covered the two assertions that gate
# the cwd-remote inference path — the same fallback the `--owner` gap abused.
# Confine the `cd` to a subshell; count in the parent.
TMP=$(/usr/bin/mktemp -d)
(
  cd "$TMP"
  /usr/bin/git init -q
  /usr/bin/git remote add origin git@github.com:disallowed-test-owner/test-repo.git
  "$FILTER" issue list >/dev/null 2>&1
)
ec=$?
if [ "$ec" = "77" ]; then
  PASS=$((PASS+1)); echo "PASS: git-remote third-party detected → blocked"
else
  FAIL=$((FAIL+1)); echo "FAIL: git-remote third-party not blocked (exit $ec)"
fi
/bin/rm -rf "$TMP"

TMP=$(/usr/bin/mktemp -d)
(
  cd "$TMP"
  /usr/bin/git init -q
  /usr/bin/git remote add origin git@github.com:test-allowed-org/test-repo.git
  "$FILTER" issue list >/dev/null 2>&1
)
ec=$?
if [ "$ec" != "77" ]; then
  PASS=$((PASS+1)); echo "PASS: git-remote allowed-owner detected → passed through (exit $ec)"
else
  FAIL=$((FAIL+1)); echo "FAIL: git-remote allowed-owner blocked"
fi
/bin/rm -rf "$TMP"

# Pathname expansion must not reach the allow decision. The split was unquoted
# with globbing live, so `--org '*'` expanded against the CURRENT DIRECTORY —
# and a directory holding a file named after an allowlisted owner became an
# allow. Filesystem contents are not an input to this gate.
TMP=$(/usr/bin/mktemp -d)
: > "$TMP/test-allowed-org"
(
  cd "$TMP"
  "$FILTER" secret list --org '*' >/dev/null 2>&1
)
ec=$?
if [ "$ec" = "77" ]; then
  PASS=$((PASS+1)); echo "PASS: --org '*' in a dir holding an allowlisted-owner filename → blocked"
else
  FAIL=$((FAIL+1)); echo "FAIL: --org '*' expanded against the cwd (exit $ec)"
fi
/bin/rm -rf "$TMP"

# --- Fail closed when argv names a target this parser did not consume -------
# The discriminating fixture is an ALLOWLISTED checkout: that is the normal
# agent state, and it is what made every previous parse miss fail OPEN. `issue`
# is not an ORG_SUBCMD, so `--owner` is not parsed; before the guard, detection
# found nothing, the cwd-remote fallback resolved the allowlisted local owner,
# and the call was allowed while argv was visibly naming a different one.
TMP=$(/usr/bin/mktemp -d)
(
  cd "$TMP"
  /usr/bin/git init -q
  /usr/bin/git remote add origin git@github.com:test-allowed-org/test-repo.git
  "$FILTER" issue list --owner disallowed-test-owner >/dev/null 2>&1
)
ec=$?
if [ "$ec" = "77" ]; then
  PASS=$((PASS+1)); echo "PASS: unparsed target flag in allowlisted checkout → blocked, not inferred"
else
  FAIL=$((FAIL+1)); echo "FAIL: unparsed target flag inferred from cwd instead of blocking (exit $ec)"
fi
/bin/rm -rf "$TMP"

# Control on the guard's blast radius: ordinary argv in the same fixture must
# still pass through. A guard that blocks everything would satisfy the
# assertion above while breaking every real call. One row of bare argv is not
# enough — it cannot tell "does not fire on ordinary argv" from "fires on any
# argv carrying a guarded shape", which is what happened when `-o` was guarded
# unconditionally. The allow cases for `search --owner <allowed>` and
# `repo read-file -o` above are the rest of this control.
TMP=$(/usr/bin/mktemp -d)
(
  cd "$TMP"
  /usr/bin/git init -q
  /usr/bin/git remote add origin git@github.com:test-allowed-org/test-repo.git
  "$FILTER" issue list >/dev/null 2>&1
)
ec=$?
if [ "$ec" != "77" ]; then
  PASS=$((PASS+1)); echo "PASS: guard does not fire on ordinary argv (exit $ec)"
else
  FAIL=$((FAIL+1)); echo "FAIL: guard blocked ordinary argv"
fi
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

# The unconfigured section used to exercise only `issue list --repo any/repo`
# in all three of its config variants, so it could not see a new path that
# skipped the empty-allowlist deny. `--org @me` is exactly that path: it takes
# neither the TARGET_REPO nor the TARGET_ORG gate, and when it was introduced
# it exec'd unconditionally. "No allowlist" means the shim is not set up, and
# the answer to every call in that state is no — including one targeting the
# caller itself.
for selfarg in "--org @me" "--owner @me" "--owner=@me"; do
  # shellcheck disable=SC2086
  GH_FILTER_CONFIG="$NONEXISTENT" "$FILTER" secret list $selfarg >/dev/null 2>&1
  ec=$?
  if [ "$ec" = "77" ]; then
    PASS=$((PASS+1)); echo "PASS: no allowlist + $selfarg → exit 77 (self-target still gated)"
  else
    FAIL=$((FAIL+1)); echo "FAIL: no allowlist + $selfarg — expected 77, got $ec"
  fi
done

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
