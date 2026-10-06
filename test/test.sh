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

# The mirror of the helper above, from a checkout whose remote is NOT
# allowlisted. This dimension did not exist until now, and its absence is what
# let a fail-open ship: extra owners were folded into the target, which
# suppressed the cwd fallback, so `issue develop --branch-repo <allowed>/x`
# went ALLOW from a foreign checkout — while all 43 allowlisted-checkout
# assertions stayed green. Reintroducing that defect surgically left the suite
# at 127/127.
#
# The distinction these assertions exist to hold: naming an ALLOWLISTED owner
# in a flag must not license the call when the repo it would also act on is
# foreign. Both must pass.
assert_in_foreign_checkout() {
  local label="$1"; shift
  local expected="$1"; shift
  local tmp; tmp=$(/usr/bin/mktemp -d)
  (
    cd "$tmp"
    /usr/bin/git init -q
    /usr/bin/git remote add origin git@github.com:disallowed-test-owner/test-repo.git
    "$FILTER" "$@" >/dev/null 2>&1
  )
  local ec=$?
  /bin/rm -rf "$tmp"
  if [ "$expected" = "block" ] && [ "$ec" = "77" ]; then
    PASS=$((PASS+1)); echo "PASS: $label (blocked from foreign checkout)"
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

# --- `gh project`: --owner on 19 subcommands, 15 of them writes -------------
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

# `gh project copy` takes NO `--owner`. Receipt: `gh project copy --help` gives
# `--source-owner` (what is read) and `--target-owner` (where the copy lands).
# Neither was parsed, so a project copy INTO a foreign org was decided by the
# cwd remote. Both are real targets; every named owner must pass. These run
# from an allowlisted checkout because that is the only configuration in which
# the laundering reproduces.
#
# Negative control for this block, so the claim is reproducible: strip the
# `--source-owner|--target-owner` arms from the parse loop AND their entries in
# the guard's flag list, and the four BLOCK cases go red at exit 0 (they reach
# the binary). Strip the parse arms ALONE and the two ALLOW cases go red at 77
# instead — those are the assertions that isolate the parse arms from the
# guard, which is why both halves are kept.
assert_in_allowlisted_checkout "project copy --target-owner disallowed"  block project copy 1 --target-owner disallowed-test-owner
assert_in_allowlisted_checkout "project copy --source-owner disallowed"  block project copy 1 --source-owner disallowed-test-owner
assert_in_allowlisted_checkout "project copy --target-owner=disallowed"  block project copy 1 --target-owner=disallowed-test-owner
assert_in_allowlisted_checkout "project copy allowed->disallowed"        block project copy 1 --source-owner test-allowed-org --target-owner disallowed-test-owner
assert_in_allowlisted_checkout "project copy allowed->allowed"           allow project copy 1 --source-owner test-allowed-org --target-owner test-allowed-org
assert_in_allowlisted_checkout "project copy --target-owner @me"         allow project copy 1 --target-owner @me

# `gh project link|unlink` take `-T, --team [HOST/]OWNER/TEAM`, and the team's
# OWNER sets the project owner. Unparsed, every spelling reached the binary
# from an allowlisted checkout while `--repo` on the same subcommand blocked —
# which is what proved it was the flag and not the fallback. The owner is the
# component before the last, in both the OWNER/TEAM and HOST/OWNER/TEAM forms.
assert_in_allowlisted_checkout "project link --team disallowed/x"    block project link 1 --team disallowed-test-owner/eng
assert_in_allowlisted_checkout "project link -T disallowed/x"        block project link 1 -T disallowed-test-owner/eng
assert_in_allowlisted_checkout "project link --team=disallowed/x"    block project link 1 --team=disallowed-test-owner/eng
assert_in_allowlisted_checkout "project link -Tdisallowed/x"         block project link 1 -Tdisallowed-test-owner/eng
assert_in_allowlisted_checkout "project unlink --team disallowed/x"  block project unlink 1 --team disallowed-test-owner/eng
assert_in_allowlisted_checkout "project link --team HOST/disallowed/x" block project link 1 --team github.com/disallowed-test-owner/eng
# Every named owner is gated, so an allowlisted --owner cannot shield a foreign
# team — this is the case a per-flag "first target wins" parser would miss.
assert_in_allowlisted_checkout "project link --owner allowed --team disallowed/x" block project link 1 --owner test-allowed-org --team disallowed-test-owner/eng
assert_in_allowlisted_checkout "project link --team allowed/x"       allow project link 1 --team test-allowed-org/eng
assert_in_allowlisted_checkout "project link --team HOST/allowed/x"  allow project link 1 --team github.com/test-allowed-org/eng
# `@me` is documented for --owner, NOT for --team, whose value is
# `[HOST/]OWNER/TEAM`. `--team @me` is not a form gh accepts, so the filter
# refusing it is the correct fail-closed answer — this assertion previously
# said `allow` because it was written before the no-slash rule, and the
# no-slash rule is what makes it wrong.
assert_in_allowlisted_checkout "project link --team @me (not a valid form)" block project link 1 --team @me

# `-T` is `--template` on issue/pr create. Guarding it CLI-wide false-blocked
# those — a regression this branch introduced and this pair now guards.
assert_in_allowlisted_checkout "issue create -T template"    allow issue create -T bug.md --title x --body y
assert_in_allowlisted_checkout "pr create -T template"       allow pr create -T pr.md --title x --body y
assert_in_allowlisted_checkout "issue create -Ttemplate"     allow issue create -Tbug.md --title x --body y

# gh reads an owner out of --team only when the value contains a slash
# (link.go). `--team my_team` is gh's own documented example and names no
# owner; the owner comes from --owner.
assert_in_allowlisted_checkout "project link --team NAME (no slash)" allow project link 1 --owner test-allowed-org --team my_team

# `codespace --repo-owner` targets an owner on 11 subcommands. It contains
# "owner", so a name-based flag sweep would have caught it — the earlier miss
# was that the sweep never left the `project` tree.
assert_in_allowlisted_checkout "codespace --repo-owner disallowed"  block codespace delete --repo-owner disallowed-test-owner --all
assert_in_allowlisted_checkout "codespace --repo-owner=disallowed"  block codespace ssh --repo-owner=disallowed-test-owner
assert_in_allowlisted_checkout "codespace --repo-owner allowed"     allow codespace delete --repo-owner test-allowed-org --all

# `gh search issues|prs --project owner/number` names an owner. Only under
# `search` — `--project` elsewhere is a project NAME, and gating it there would
# be the third false-block class of this branch.
assert_in_allowlisted_checkout "search --project disallowed/N"      block search issues --project disallowed-test-owner/5
assert_in_allowlisted_checkout "search --project=disallowed/N"      block search prs --project=disallowed-test-owner/5
assert_in_allowlisted_checkout "search --project allowed/N"         allow search issues --project test-allowed-org/5

# `gh issue develop --branch-repo <Name|OWNER/NAME|URL>` creates the branch in
# THAT repo. All three value shapes reach the same field.
assert_in_allowlisted_checkout "issue develop --branch-repo disallowed/x"  block issue develop 1 --branch-repo disallowed-test-owner/x
assert_in_allowlisted_checkout "issue develop --branch-repo=disallowed/x"  block issue develop 1 --branch-repo=disallowed-test-owner/x
assert_in_allowlisted_checkout "issue develop --branch-repo URL"           block issue develop 1 --branch-repo https://github.com/disallowed-test-owner/x
assert_in_allowlisted_checkout "issue develop --branch-repo allowed/x"     allow issue develop 1 --branch-repo test-allowed-org/x
# A BARE name resolves under the current owner and names no owner of its own.
# Guarding a flag we already parse turned this into a block; that is why
# --branch-repo is deliberately absent from the guard's flag list.
assert_in_allowlisted_checkout "issue develop --branch-repo bare-name"     allow issue develop 1 --branch-repo just-a-name

# `gh search --team-mentions OWNER/TEAM` names an owner exactly as --team does.
assert_in_allowlisted_checkout "search --team-mentions disallowed/x"       block search issues --team-mentions disallowed-test-owner/eng
assert_in_allowlisted_checkout "search --team-mentions allowed/x"          allow search issues --team-mentions test-allowed-org/eng

# `gh repo fork <upstream> --org X` WRITES the fork into X. Both ends are
# gated: an allowlisted upstream does not license a foreign destination, and
# round 2's closure (foreign upstream, allowlisted destination) must survive.
assert_in_allowlisted_checkout "repo fork allowed/x --org disallowed"      block repo fork test-allowed-org/x --org disallowed-test-owner
# NOTE: `gh repo fork` has no `-o` shorthand — receipt: `--org string`, no
# shorthand listed. This asserted on argv gh rejects, which is a test of
# nothing. The long form above is the real case.
assert_in_allowlisted_checkout "repo fork disallowed/x --org allowed"      block repo fork disallowed-test-owner/x --org test-allowed-org
assert_in_allowlisted_checkout "repo fork allowed/x --org allowed"         allow repo fork test-allowed-org/x --org test-allowed-org

# --- Foreign checkout: an allowlisted FLAG owner must not license a foreign
# --- cwd repo. These are the assertions that can see a fifth fail-open on the
# --- extra-owner path; without them the suite reported 127/127 with the
# --- round-12 Critical surgically reintroduced.
assert_in_foreign_checkout "branch-repo allowed, cwd foreign"   block issue develop 1 --branch-repo test-allowed-org/x
assert_in_foreign_checkout "branch-repo foreign, cwd foreign"   block issue develop 1 --branch-repo disallowed-test-owner/x
assert_in_foreign_checkout "fork --org allowed, cwd foreign"    block repo fork --org test-allowed-org
assert_in_foreign_checkout "fork allowed/x --org allowed, cwd foreign" allow repo fork test-allowed-org/x --org test-allowed-org
assert_in_foreign_checkout "issue list, cwd foreign"            block issue list
assert_in_foreign_checkout "secret list --org allowed, cwd foreign" allow secret list --org test-allowed-org
# The previous version of this used --repo, which sets TARGET_REPO and
# short-circuits the guard — so it passed with the guard scoped OR un-scoped.
# Measured: un-scoping the guard CLI-wide left the suite at 117/117. Running it
# from an allowlisted checkout with no --repo is what makes it discriminate.
assert_in_allowlisted_checkout "issue list --project NAME (not an owner)" allow issue list --project "Some Board"

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
#    Allocate a pty via `script` so `[ -t 2 ]` is true.
#
#    `< /dev/null` is REQUIRED, not tidiness. macOS `script` calls tcgetattr on
#    its OWN stdin to clone terminal settings, so its behaviour depends on what
#    stdin it inherits — measured:
#
#      socket  -> "script: tcgetattr/ioctl: Operation not supported on socket",
#                 exit 1, no output
#      pipe    -> runs, but the capture comes back EMPTY
#      /dev/null or a regular file -> works; 0 failures in 60 consecutive runs
#
#    That is the whole of the ~6% flake this assertion used to carry (issue #6):
#    the verdict depended on how the suite itself had been invoked, not on the
#    filter. Pinning stdin removes the dependency.
#
#    The exit status is checked separately from the substring so an INSTRUMENT
#    failure can never be reported as a filter verdict — the distinction issue
#    #6 asked for.
if command -v script >/dev/null 2>&1; then
  tty_raw=$(script -q /dev/null env GH_FILTER_REAL_GH="$STUB_GH" \
      GH_FILTER_AGENT_TOKEN_COMMAND="$TOK_CMD" GH_FILTER_AGENT_MARKER_ENVS=TEST_MARKER \
      "$FILTER" api /user < /dev/null 2>&1)
  tty_ec=$?
  tty_out=$(printf '%s' "$tty_raw" | /usr/bin/tr -d '\r')
  if [ "$tty_ec" != "0" ] || [ -z "$tty_out" ]; then
    FAIL=$((FAIL+1))
    echo "FAIL: human TTY — INSTRUMENT failure, not a filter verdict (script exit $tty_ec, output '$tty_out')"
  elif [[ "$tty_out" == *"REALGH_TOKEN=<none>"* ]]; then
    PASS=$((PASS+1)); echo "PASS: human TTY (no marker) → no injection, ambient credential"
  else
    FAIL=$((FAIL+1)); echo "FAIL: human TTY passthrough  (got '$tty_out')"
  fi
else
  echo "SKIP: human-TTY test (no 'script' binary to allocate a pty)"
fi

/bin/rm -rf "$IDENT_DIR"

echo ""
echo "=== @-mention guard ==="
# A body that @-mentions a registry name is refused (exit 77) and must never
# reach the real binary — "nothing is posted" is asserted, not assumed, via a
# stub that leaves a marker when it runs. The stub also captures its stdin so
# the `--body-file -` path can prove the caller's input still arrives intact
# after the guard has read it.
#
# Negative control, measured when this block was written: delete the
# `mention_guard "$@"` call in gh-filter and "pr comment --body 'thanks @queen'"
# goes red (exit 0, stub reached), along with every other BLOCK case here. The
# ALLOW cases stay green in that world, which is why they cannot be the proof.
MG_DIR=$(/usr/bin/mktemp -d)
MG_REG="$MG_DIR/registry.json"
# Objects with a "name" (the shape of a session registry), a bare string, and
# an object with no name at all, which must be skipped rather than break parsing.
/bin/cat > "$MG_REG" <<'EOF'
[
  {"name": "queen", "dir": "/x"},
  {"name": "agents-app"},
  {"name": "test-operator"},
  {"dir": "/no/name/field"},
  "thinker"
]
EOF
MG_STUB="$MG_DIR/stub-gh"
/bin/cat > "$MG_STUB" <<EOF
#!/bin/bash
: > "$MG_DIR/reached"
/bin/cat > "$MG_DIR/stdin"
exit 0
EOF
/bin/chmod +x "$MG_STUB"

# mg_run ARGS... — run the filter with the guard pointed at the fixture
# registry. MG_REGISTRY (set, possibly empty) overrides the registry path;
# MG_ALLOW sets the exempt list; MG_IN is the file fed on stdin.
mg_run() {
  /bin/rm -f "$MG_DIR/reached" "$MG_DIR/stdin" "$MG_DIR/err"
  env GH_FILTER_REAL_GH="$MG_STUB" \
      GH_FILTER_MENTION_GUARD_REGISTRY="${MG_REGISTRY-$MG_REG}" \
      GH_FILTER_MENTION_GUARD_ALLOW="${MG_ALLOW:-}" \
      "$FILTER" "$@" < "${MG_IN:-/dev/null}" >/dev/null 2>"$MG_DIR/err"
}

# assert_mention LABEL block|allow ARGS...
# block = exit 77, the real binary NOT reached, and the refusal names the
#         backticked form to write instead.
# allow = not 77 and the real binary reached.
assert_mention() {
  local label="$1" expected="$2"; shift 2
  mg_run "$@"
  local ec=$?
  local reached=no
  [ -e "$MG_DIR/reached" ] && reached=yes
  if [ "$expected" = "block" ] && [ "$ec" = "77" ] && [ "$reached" = "no" ] \
     && /usr/bin/grep -q '^    `' "$MG_DIR/err"; then
    PASS=$((PASS+1)); echo "PASS: $label (refused, nothing posted)"
  elif [ "$expected" = "allow" ] && [ "$ec" != "77" ] && [ "$reached" = "yes" ]; then
    PASS=$((PASS+1)); echo "PASS: $label (passed through)"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $label  (expected $expected, exit $ec, real gh reached: $reached)"
    echo "       cmd: gh $*"
  fi
}

R="--repo=test-allowed-org/x"

# --- The incident, and its exact remedy text ---------------------------------
mg_run pr comment 1 "$R" --body "thanks @queen"
ec=$?
# shellcheck disable=SC2016  # literal backticks: Markdown code spans in the body
if [ "$ec" = "77" ] && [ ! -e "$MG_DIR/reached" ] \
   && /usr/bin/grep -q '`queen`' "$MG_DIR/err" \
   && /usr/bin/grep -q 'the queen agent' "$MG_DIR/err"; then
  PASS=$((PASS+1)); echo "PASS: pr comment --body 'thanks @queen' → refused, suggests \`queen\`, nothing posted"
else
  FAIL=$((FAIL+1)); echo "FAIL: pr comment --body 'thanks @queen' (exit $ec, reached: $([ -e "$MG_DIR/reached" ] && echo yes || echo no))"
fi

# --- Every body spelling on every covered command ----------------------------
assert_mention "pr comment --body=…@queen"        block pr comment 1 "$R" "--body=thanks @queen"
assert_mention "pr comment -b …@queen"            block pr comment 1 "$R" -b "thanks @queen"
assert_mention "pr comment -b…@queen (attached)"  block pr comment 1 "$R" "-b@queen thanks"
assert_mention "issue comment -b=…@queen"         block issue comment 1 "$R" "-b=hi @queen"
assert_mention "issue create --body @queen"       block issue create "$R" --title t --body "cc @queen"
assert_mention "issue new (alias) --body @queen"  block issue new "$R" --title t --body "cc @queen"
assert_mention "issue edit --body @queen"         block issue edit 1 "$R" --body "cc @queen"
assert_mention "pr create --body @queen"          block pr create "$R" --title t --body "cc @queen"
assert_mention "pr new (alias) --body @queen"     block pr new "$R" --title t --body "cc @queen"
assert_mention "pr edit --body @queen"            block pr edit 1 "$R" --body "cc @queen"
assert_mention "pr review --body @queen"          block pr review 1 "$R" --comment --body "cc @queen"

MG_BODY="$MG_DIR/body.md"
printf 'Review notes.\n\nThanks @queen for the catch.\n' > "$MG_BODY"
assert_mention "issue create --body-file FILE"    block issue create "$R" --title t --body-file "$MG_BODY"
assert_mention "issue comment -F FILE"            block issue comment 1 "$R" -F "$MG_BODY"
assert_mention "pr comment --body-file=FILE"      block pr comment 1 "$R" "--body-file=$MG_BODY"
assert_mention "pr edit -FFILE (attached)"        block pr edit 1 "$R" "-F$MG_BODY"
MG_IN="$MG_BODY" assert_mention "pr review --body-file - (stdin)" block pr review 1 "$R" --comment --body-file -

# `gh api`: -F reads `@path` / `@-` from a file / stdin; -f is always literal.
API=(api repos/test-allowed-org/x/issues/1/comments)
assert_mention "api -F body=@FILE"                block "${API[@]}" -F "body=@$MG_BODY"
assert_mention "api --field=body=@FILE"           block "${API[@]}" "--field=body=@$MG_BODY"
MG_IN="$MG_BODY" assert_mention "api -F body=@- (stdin)" block "${API[@]}" -F body=@-
assert_mention "api -F body=literal @queen"       block "${API[@]}" -F "body=thanks @queen"
assert_mention "api -f body=@queen (raw: literal)" block "${API[@]}" -f "body=@queen"
assert_mention "api --raw-field=body=…"           block "${API[@]}" "--raw-field=body=cc @queen"
assert_mention "api -fbody=… (attached)"          block "${API[@]}" "-fbody=cc @queen"
assert_mention "api -f comments[][body]=…"        block api repos/test-allowed-org/x/pulls/1/reviews -f event=COMMENT -f "comments[][body]=cc @queen"

# --- Matching rules: case-insensitive, word-boundary, any registry shape ------
assert_mention "@QUEEN (case-insensitive)"        block pr comment 1 "$R" -b "thanks @QUEEN"
assert_mention "(@queen) punctuation"             block pr comment 1 "$R" -b "thanks (@queen)."
assert_mention "@queen, at start of body"         block pr comment 1 "$R" -b "@queen, thanks"
assert_mention "@agents-app (hyphenated name)"    block pr comment 1 "$R" -b "ping @agents-app"
assert_mention "@thinker (string registry entry)" block pr comment 1 "$R" -b "ping @thinker"
assert_mention "mention AFTER a closed fence"     block pr comment 1 "$R" -b $'```\ncode\n```\nthanks @queen'
assert_mention "unmatched backtick hides nothing" block pr comment 1 "$R" -b 'a ` stray tick, thanks @queen'
mg_run pr comment 1 "$R" -b "thanks @queen and @thinker"
if /usr/bin/grep -q '@queen @thinker' "$MG_DIR/err"; then
  PASS=$((PASS+1)); echo "PASS: refusal lists every offending name"
else
  FAIL=$((FAIL+1)); echo "FAIL: refusal did not list both names: $(/usr/bin/grep Mentioned "$MG_DIR/err")"
fi

# --- Allowed: not a mention, not an agent, or exempt -------------------------
assert_mention "@some-human (not in registry)"    allow pr comment 1 "$R" -b "thanks @some-human"
# shellcheck disable=SC2016  # literal backticks: Markdown code spans in the body
assert_mention "inline code \`@queen\`"           allow pr comment 1 "$R" -b 'thanks `@queen`'
# shellcheck disable=SC2016  # literal backticks: Markdown code spans in the body
assert_mention "double-backtick span"             allow pr comment 1 "$R" -b 'see ``a ` @queen`` here'
assert_mention "fenced \`\`\` block"              allow pr comment 1 "$R" -b $'log:\n```text\n@queen said hi\n```\ndone'
assert_mention "fenced ~~~ block"                 allow pr comment 1 "$R" -b $'~~~\n@queen\n~~~'
assert_mention "indented fence (3 spaces)"        allow pr comment 1 "$R" -b $'   ```\n@queen\n   ```'
assert_mention "unclosed fence runs to end"       allow pr comment 1 "$R" -b $'```\n@queen'
assert_mention "email-like foo@queen.example"         allow pr comment 1 "$R" -b "mail foo@queen.example"
assert_mention "@queenbee (longer token)"         allow pr comment 1 "$R" -b "thanks @queenbee"
assert_mention "@queen-bee (longer token)"        allow pr comment 1 "$R" -b "thanks @queen-bee"
assert_mention "the queen agent (no @)"           allow pr comment 1 "$R" -b "thanks to the queen agent"
assert_mention "api -f title=@queen (not a body)" allow "${API[@]}" -f "title=@queen"
assert_mention "issue view (not a write)"         allow issue view 1 "$R"
MG_ALLOW="test-operator" assert_mention "exempt handle via MENTION_GUARD_ALLOW" allow pr comment 1 "$R" -b "cc @test-operator"
MG_ALLOW="@Test-Operator" assert_mention "exempt list is case-insensitive, @ optional" allow pr comment 1 "$R" -b "cc @test-operator"
assert_mention "not exempt without the allow entry" block pr comment 1 "$R" -b "cc @test-operator"

# stdin is read by the guard and must still reach the real gh, byte for byte.
# shellcheck disable=SC2016  # literal backticks: Markdown code spans in the body
printf 'all clear, `@queen` in code\n' > "$MG_DIR/clean.md"
MG_IN="$MG_DIR/clean.md" mg_run pr comment 1 "$R" --body-file -
if [ -e "$MG_DIR/reached" ] && /usr/bin/cmp -s "$MG_DIR/clean.md" "$MG_DIR/stdin"; then
  PASS=$((PASS+1)); echo "PASS: --body-file - : real gh receives the caller's stdin intact"
else
  FAIL=$((FAIL+1)); echo "FAIL: --body-file - : stdin not passed through intact"
fi
MG_IN="$MG_DIR/clean.md" mg_run "${API[@]}" -F body=@-
if [ -e "$MG_DIR/reached" ] && /usr/bin/cmp -s "$MG_DIR/clean.md" "$MG_DIR/stdin"; then
  PASS=$((PASS+1)); echo "PASS: api -F body=@- : real gh receives the caller's stdin intact"
else
  FAIL=$((FAIL+1)); echo "FAIL: api -F body=@- : stdin not passed through intact"
fi

# --- Off by default, and fail OPEN on a bad registry -------------------------
MG_REGISTRY="" assert_mention "guard not configured → no-op" allow pr comment 1 "$R" -b "thanks @queen"
for bad in missing unreadable malformed empty; do
  case "$bad" in
    missing)    MG_BAD="$MG_DIR/does-not-exist.json" ;;
    unreadable) MG_BAD="$MG_DIR/unreadable.json"; /bin/cp "$MG_REG" "$MG_BAD"; /bin/chmod 000 "$MG_BAD" ;;
    malformed)  MG_BAD="$MG_DIR/malformed.json"; /bin/echo '{not json' > "$MG_BAD" ;;
    empty)      MG_BAD="$MG_DIR/empty.json"; /bin/echo '[]' > "$MG_BAD" ;;
  esac
  MG_REGISTRY="$MG_BAD" mg_run pr comment 1 "$R" -b "thanks @queen"
  ec=$?
  # A root-run suite can read a mode-000 file; skip that case rather than lie.
  if [ "$bad" = "unreadable" ] && [ -r "$MG_BAD" ]; then
    echo "SKIP: $bad registry (running as root; the file is readable anyway)"
  elif [ "$ec" != "77" ] && [ -e "$MG_DIR/reached" ] && /usr/bin/grep -q 'WARNING.*failing open' "$MG_DIR/err"; then
    PASS=$((PASS+1)); echo "PASS: $bad registry → fails open with a warning"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $bad registry (exit $ec, reached: $([ -e "$MG_DIR/reached" ] && echo yes || echo no))"
  fi
done

# The config-file key works too, not just the env override.
MG_CFG="$MG_DIR/config"
printf 'ALLOWED_OWNERS=test-allowed-org\nMENTION_GUARD_REGISTRY=%s\n' "$MG_REG" > "$MG_CFG"
/bin/rm -f "$MG_DIR/reached"
GH_FILTER_CONFIG="$MG_CFG" GH_FILTER_REAL_GH="$MG_STUB" "$FILTER" pr comment 1 "$R" -b "thanks @queen" </dev/null >/dev/null 2>&1
ec=$?
if [ "$ec" = "77" ] && [ ! -e "$MG_DIR/reached" ]; then
  PASS=$((PASS+1)); echo "PASS: MENTION_GUARD_REGISTRY in the config file enables the guard"
else
  FAIL=$((FAIL+1)); echo "FAIL: config-file MENTION_GUARD_REGISTRY (exit $ec)"
fi

/bin/chmod 600 "$MG_DIR/unreadable.json" 2>/dev/null
/bin/rm -rf "$MG_DIR"

echo ""
echo "================================================================"
echo "Total: $((PASS+FAIL)) | Passed: $PASS | Failed: $FAIL"
echo "================================================================"
[ "$FAIL" = "0" ]
