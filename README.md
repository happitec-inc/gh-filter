# gh-filter

A shim for [GitHub CLI (`gh`)](https://cli.github.com/) that refuses any invocation targeting a repo outside an explicit owner allowlist. On block: prints a verbose explanation, sends a Pushover alert via `notify` (if installed), and exits non-zero. On allow: execs the real `gh` transparently.

Built after a security observation: an installation token scoped to one GitHub App / org can file issues on **any** public repo, regardless of the App's installation scope. The App permission `issues:write` is irrelevant for public repos outside its installation — `POST /repos/{owner}/{repo}/issues` is treated as "any authenticated actor with pull access," and every authenticated identity has implicit pull access on public repos.

There is no GitHub-side toggle for "scope this app's writes to installed repos only." This shim is the operational lock.

## Installation

Install via the `happitec-inc/tap` brew tap.

```bash
brew tap happitec-inc/tap     # one-time, if not already tapped
brew install gh-filter
```

This installs:

- The script at `$(brew --prefix gh-filter)/libexec/gh-filter`
- A `gh` shim at `$(brew --prefix gh-filter)/libexec/shim/gh` (a 2-line bash script that execs the filter)
- A `gh` formula dependency — the real GitHub CLI stays installed at `$(brew --prefix gh)/bin/gh` and is **never modified** by gh-filter.

### Configure the allowlist — REQUIRED

The filter ships with an empty allowlist. **Until you write a config file, every repo-targeted `gh` invocation is blocked.** That's intentional — an unconfigured filter fails closed.

Create `~/.config/gh-filter/config`:

```
ALLOWED_OWNERS=your-org,another-org
```

Format is `KEY=VALUE`, comma-separated owner names. Lines starting with `#` are treated as comments. Restart shells aren't required; the config is read on every `gh-filter` invocation.

### Activate the shim — ONE-TIME, MANUAL

After `brew install`, the filter exists on disk but isn't yet wired up to the name `gh`. To activate, **prepend the shim directory to your PATH** in your shell rc:

```bash
echo 'export PATH="$(brew --prefix gh-filter)/libexec/shim:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify:

```bash
which gh                    # → /opt/homebrew/opt/gh-filter/libexec/shim/gh
gh --version                # should still report the real gh version
```

The shim is **deliberately not auto-activated** by the formula. The formula installs files; the user owns their shell environment. To deactivate without uninstalling, just remove the `export PATH=...` line from `~/.zshrc`.

If your shell is something other than zsh, append the same `export` line to the equivalent rc file (`~/.bashrc`, `~/.config/fish/config.fish` with adjusted syntax, etc.).

### Test the filter

```bash
# Should be blocked (owner not in your allowlist) — exit 77, verbose error, Pushover alert if notify is installed:
gh issue create --repo some-other-org/test-repo --title test --body test

# Should pass through (substitute one of your allowed owners) — exit 0 or whatever gh returns:
gh api /repos/your-org/your-repo
```

### Why a separate shim directory instead of replacing `/opt/homebrew/bin/gh`?

So that `brew upgrade gh` and `brew upgrade gh-filter` can each run independently without breaking the other:

- `brew upgrade gh` updates the real binary at `/opt/homebrew/bin/gh`. The shim at `$(brew --prefix gh-filter)/libexec/shim/gh` is untouched. The filter still wraps the new gh transparently because it auto-resolves the highest version in `/opt/homebrew/Cellar/gh/` at runtime.
- `brew upgrade gh-filter` retargets the `opt_libexec` symlink to the new cellar version. The PATH entry stays valid because it points at the stable opt-prefix, not the version-pinned cellar path.

An earlier implementation symlinked `/opt/homebrew/bin/gh` directly to the filter. It worked at first, but `brew upgrade gh` would have silently overwritten the symlink and broken the lockdown without warning. The formula-based approach removes that fragility.

## How it works

`gh-filter` is a bash script that:

1. Inspects the arguments to detect the **target repo** (owner/name).
2. Checks the owner against an allowlist loaded from `~/.config/gh-filter/config`.
3. If outside the list: refuses, prints a verbose error to stderr, calls `notify` for a Pushover alert (if available), exits `77`.
4. If inside the list (or the call doesn't touch a repo): execs the real `gh` with the original args.

Target detection sources, in order:

1. **An org flag** — `--org`, `--owner`, or `-o` — on a subcommand where that flag names the target (see [Org-targeted commands](#org-targeted-commands))
2. `--repo OWNER/NAME` or `-R OWNER/NAME` (also `=` and attached forms)
3. For `gh api`: `/repos/OWNER/NAME/...` extracted from the path argument
4. For `gh repo <verb>`: positional `OWNER/NAME` argument
5. Fallback: `git config --get remote.origin.url` in the current directory

Two properties of that list are worth stating plainly, because they are the difference between a gate and a guess:

- **An explicit flag beats the git-remote fallback.** Step 5 infers a target from wherever the process happens to be standing. Steps 1–4 determine one from the arguments. If argv names a target, the fallback is not consulted — otherwise `gh secret set --org some-org`, run from inside an unrelated checkout, would be gated on *that checkout's* owner rather than on the org being addressed.
- **The scanners are positional-naive.** They walk argv word by word, with no `--` end-of-options handling and no notion of which words are a flag's *value* rather than a flag. This is why the guard below errs toward refusing.

If no target can be determined and the subcommand isn't a recognized no-repo operation (`auth status`, `--version`, `api /user`, etc.), the call is refused with a suggestion to pass `--repo` explicitly.

## Org-targeted commands

Some `gh` subcommands operate on an **organization**, not a repo. There is no `OWNER/NAME` anywhere in argv, so without special handling these calls fell through to the deny above — a false block on a perfectly legal call, whose suggested remedy (`--repo OWNER/NAME`) does not exist for a command that has no repo.

The org is gated through the same allowlist as a repo owner. This widens the argument **forms** the filter understands; it never widens the set of permitted owners.

### Which subcommands

`--org` / `--owner` / `-o` is treated as the target only for subcommands where it genuinely *is* the target:

`secret` · `variable` · `ruleset` · `codespace` · `attestation` · `project` · `search` · `skill`

`repo` is deliberately **excluded**. Two reasons, both load-bearing:

- On `gh repo fork --org X`, `--org` names the fork *destination* while the write lands on the foreign upstream. Treating it as the target would let `gh repo fork some-other-org/thing --org your-org` through.
- On `gh repo read-file -o out.txt`, `-o` is `--output`. Treating it as an org would swallow a filename and false-block.

### Accepted spellings

All of these are recognised, for both `--org` and `--owner`:

```bash
gh secret list --org your-org           # space-separated
gh secret list --org=your-org           # =-joined
gh secret list -o your-org              # shorthand
gh secret list -o=your-org              # =-joined shorthand
gh secret list -oyour-org               # attached shorthand
```

Missing any one of these spellings is not cosmetic. An unrecognised spelling used to leave the target unset, which sent the call to the git-remote fallback — so from inside any allowlisted checkout, a call naming a *foreign* org passed straight through.

### List values

`--owner` and `--repo` are `strings` (list) flags on `gh search`, so a comma-separated value is legal. **Every element is gated, and one foreign element blocks the whole call** — `gh` queries all of them, so a partial check would be no check.

```bash
gh search repos --owner your-org,another-org      # allowed if BOTH are allowlisted
gh search repos --owner your-org,some-other-org   # BLOCKED, names the offending element
gh search code  --repo your-org/a,your-org/b foo  # per-element, same rule
```

A value that names no owner at all is refused rather than passed:

```bash
gh secret list --org ,                             # blocked: no owner parsed
```

### `--owner @me`

`@me` is documented and legal on every `gh project` subcommand. It names the **authenticated identity**, not a third party, so it is neither an org to look up nor a target to infer — it is allowed explicitly:

```bash
gh project list --owner @me                        # allowed
```

It is still refused when no allowlist is configured, because "no allowlist" means the shim is not set up, and the answer to every call in that state is no — including one targeting the caller.

### Repeated flags: the last one wins

`gh` uses the **last** occurrence of a repeated flag (Cobra behaviour: `gh browse -R aaa/one -R bbb/two -n` opens `bbb/two`). The filter matches that, so a harmless first value cannot shield a foreign second one:

```bash
gh project delete 1 --owner @me --owner some-other-org   # BLOCKED on the foreign owner
gh secret list --org your-org --org some-other-org       # BLOCKED on the foreign org
```

## Restriction: unparsed target flags are refused, not guessed

If argv names a target through a flag the filter recognises the *shape* of but did not consume, the call is **refused** rather than resolved from the current directory:

```bash
$ gh issue list --owner some-other-org
gh-filter: BLOCKED
Detected target: <unparsed target flag: --owner>
Reason:          argv names a target via '--owner' that this filter did not parse;
                 refusing to infer the target from the current directory
```

**Why this exists.** Five separate argv spellings were added to the parser in five separate fixes, and *every* miss failed **open** — an unrecognised target flag left the target empty, and the fallback treated "I parsed nothing" as licence to guess from the current directory. For a shim whose contract is *fail closed when it cannot determine the target*, that is the contract inverted. Enumerating spellings can only ever be complete as of the `gh` version last read; this closes the class rather than the next instance.

**What it means for you.** If you see this block on a call you believe is legitimate, the filter is telling you it does not understand that flag on that subcommand — not that the owner is disallowed. Either name the target a way it does parse (`--repo OWNER/NAME`), or file an issue so the subcommand is handled properly.

**Its limits, stated rather than implied:** it recognises only flag shapes already known, so a future target flag spelled some other way still slips past; and because the scanners are positional-naive, a literal `--org` appearing as some *other* flag's value will trip it. That direction fails closed and is recoverable.

`-o` is guarded only on the org-targeting subcommands above, since elsewhere it may mean `--output`.

## Known gaps

Documented rather than implied, because a containment control that overstates its coverage is worse than one that does not:

- **`gh status --org` and `gh extension search --owner` are never gated.** Both are exec'd as pass-through *above* target detection, so adding them to the org-subcommand list would not help — the fix has to move the check. Both leak only public activity/listing data. Tracked as issue #8.
- **Owner comparison is case-sensitive** while GitHub treats owner names case-insensitively, so an owner may need listing in more than one spelling. Fails closed. Tracked as issue #7.

## Agent-identity injection (optional)

By default gh-filter only decides *whether* a call is allowed (the owner allowlist). It can optionally also decide *which identity* a call runs as — so automated ("agent") invocations authenticate with a token you supply, while your own interactive `gh` is left completely untouched.

This exists because `gh` with no explicit token falls back to whatever account is logged in via `gh auth login`. On a shared machine where both a human and automated agents invoke `gh` as the same OS user, every agent call silently spends the human's API rate-limit budget and acts as the human's identity. The identity stage closes that: it detects an agent context and swaps in a dedicated token.

### Configuration

Two optional keys in `~/.config/gh-filter/config`. The feature is **off unless `AGENT_TOKEN_COMMAND` is set** — with it unset, the identity stage is a complete no-op and gh-filter behaves as a pure owner-allowlist.

```
AGENT_TOKEN_COMMAND=/path/to/print-a-token       # command whose stdout is a token
AGENT_MARKER_ENVS=CLAUDECODE                      # env vars that mark an agent context
```

- **`AGENT_TOKEN_COMMAND`** — a single executable that prints a token to stdout (for example, a script that mints a short-lived GitHub App installation token). Run with no arguments; it **must not itself invoke `gh`** (that would recurse through this shim). If it is missing, errors, or prints nothing, the call **fails closed** (exit 78) rather than falling back to the ambient credential.
- **`AGENT_MARKER_ENVS`** — comma-separated list of environment variable *names*. If any is present and non-empty, the invocation is treated as an agent context. `CLAUDECODE` is the marker [Claude Code](https://docs.claude.com/en/docs/claude-code) sets in every tool subprocess; other harnesses set their own (add them here). An interactive human shell has none of these.

Both may also be supplied via the `GH_FILTER_AGENT_TOKEN_COMMAND` / `GH_FILTER_AGENT_MARKER_ENVS` environment variables (which take precedence — handy for tests).

### Precedence

When `AGENT_TOKEN_COMMAND` is configured, each call resolves identity in this order, *before* the allowlist gate:

1. **Caller already set `GH_TOKEN` or `GITHUB_TOKEN`** → honored as-is, nothing injected. (Preserves explicit `GH_TOKEN=$(...) gh ...` calls, and is the escape hatch to force a specific identity — including your own.)
2. **Agent context** (a marker env is set) → inject `AGENT_TOKEN_COMMAND`'s token.
3. **Interactive human** (stderr is a TTY) → leave the ambient credential untouched; you stay yourself.
4. **Neither** (detached process, cron, scrubbed environment — no token, no marker, no TTY) → **fail closed to `AGENT_TOKEN_COMMAND`**, never the ambient credential. A background job that lost its markers can never silently spend the human's budget.

Identity selection and the owner-allowlist are separate stages, and the allowlist stays the **final** gate — injecting a token never bypasses blast-radius protection.

### Note on cost

The identity stage runs `AGENT_TOKEN_COMMAND` on every agent-context call, **with no caching**. If your command performs a network round-trip (e.g. minting an installation token), every agent `gh` call pays that latency. Caching is intentionally not built in yet; wrap your command with your own cache if the cost matters.

## Subcommands always passed through (no repo check)

- `--version`, `--help`, `-v`, `-h`
- `help`, `completion`, `config`, `alias`, `gpg-key`, `ssh-key`, `cache`
- `auth` (all subcommands)
- `extension list`, `extension search`, `extension exec`

## Subcommands always blocked

- `extension install`, `extension upgrade`, `extension remove`, `extension create`, `extension browse` — state-changing extension ops; install manually if needed
- `api graphql` — the query body can target any repo and isn't reliably parseable

## Allowed `gh api` meta paths

These don't reference a repo and are allowed regardless of allowlist:

`/user`, `/users/*`, `/search/*`, `/rate_limit`, `/meta`, `/octocat`, `/zen`, `/emojis`, `/licenses*`, `/gitignore/*`, `/app`, `/app/*`, `/installation`, `/installation/*`, `/markdown`, `/markdown/*`, `/feeds`, `/notifications`, `/notifications/*`.

`/orgs/<owner>` and `/orgs/<owner>/*` are allowed only when `<owner>` appears in the configured allowlist.

The leading slash is optional on all of these — `gh api` treats `orgs/<owner>` and `/orgs/<owner>` identically, and the filter accepts both forms (matching the `repos/` handling). The owner allowlist is unaffected either way.

## Uninstallation

```bash
brew uninstall gh-filter
```

Brew removes the formula's files cleanly. The `export PATH=...` line in `~/.zshrc` remains — brew has no `post_uninstall` hook to clean it up. **Remove that line manually** to fully unwire the shim. If you forget, the PATH entry is harmless on its own (it points at a missing directory; PATH lookups fall through to the next match, which is the real `gh`).

## Configuration

The config file holds `KEY=VALUE` lines. Recognized keys:

| Config key            | Meaning                                                                 |
|-----------------------|-------------------------------------------------------------------------|
| `ALLOWED_OWNERS`      | Comma-separated owner allowlist (required for repo-targeted calls)      |
| `AGENT_TOKEN_COMMAND` | Optional. Command whose stdout is the token to inject for agent calls   |
| `AGENT_MARKER_ENVS`   | Optional. Comma-separated env-var names marking an agent context        |

The script also reads these environment variables at runtime (each overrides the corresponding config key or default):

| Variable                          | Default                                              | Meaning                                       |
|-----------------------------------|------------------------------------------------------|-----------------------------------------------|
| `GH_FILTER_CONFIG`                | `~/.config/gh-filter/config`                         | Path to the config file                       |
| `GH_FILTER_REAL_GH`               | highest-version `gh` in `/opt/homebrew/Cellar/gh/`   | Path to the real `gh` binary to exec          |
| `GH_FILTER_NOTIFY`                | resolved from `$PATH` via `command -v notify`        | Path to the `notify` binary (Pushover)        |
| `GH_FILTER_AGENT_TOKEN_COMMAND`   | value of `AGENT_TOKEN_COMMAND` in config             | Override the agent token command              |
| `GH_FILTER_AGENT_MARKER_ENVS`     | value of `AGENT_MARKER_ENVS` in config               | Override the agent marker env list            |

If `notify` isn't installed or isn't found, the filter silently skips the Pushover alert and still blocks the call. The phone alert is best-effort, not a precondition for enforcement.

## Bypass concerns

This shim catches the standard `gh ...` pattern. It does NOT catch:

- Invoking the real `gh` by absolute path (`/opt/homebrew/bin/gh ...`)
- Raw `curl https://api.github.com/repos/...` with a bot token
- `git push` to a foreign remote
- `gh extension exec` on an extension that itself makes raw API calls (e.g., extensions that use the GitHub SDK directly rather than shelling out to `gh api`). The extension's network traffic is not mediated by the filter.

The block message reminds operators that these are **separate, escalated violations**. A complete operational lockdown also needs companion guards for `curl` and `git push` — not yet shipped here.

## Exit codes

| Code | Meaning                                       |
|------|-----------------------------------------------|
| `0`  | Real `gh` ran and succeeded                   |
| `1`+ | Real `gh` ran and exited with that code       |
| `70` | gh-filter: real `gh` binary not found         |
| `77` | gh-filter: invocation blocked by the filter   |
| `78` | gh-filter: agent identity could not be resolved (fail-closed) |

## The Pushover notification

When a block happens, the shim calls `notify --message "..."` to alert the operator's phone. The message format:

```
gh-filter blocked: target=<owner/name> reason=<reason> cmd=<gh command preview>
```

Disable for local testing with `GH_FILTER_NOTIFY=/usr/bin/true`. (Don't disable in agent contexts — the alert is the whole point.)

## Why exit code 77

77 = `EX_NOPERM` in BSD sysexits.h: "permission denied." It distinguishes filter-blocks from real `gh` errors so callers can branch on the cause.

## License

[MIT](LICENSE).
