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

Target repo detection sources, in order:

1. `--repo OWNER/NAME` or `-R OWNER/NAME` (also `=` form)
2. For `gh api`: `/repos/OWNER/NAME/...` extracted from the path argument
3. For `gh repo <verb>`: positional `OWNER/NAME` argument
4. Fallback: `git config --get remote.origin.url` in the current directory

If no target can be determined and the subcommand isn't a recognized no-repo operation (`auth status`, `--version`, `api /user`, etc.), the call is refused with a suggestion to pass `--repo` explicitly.

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
