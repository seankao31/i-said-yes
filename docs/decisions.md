# Decisions and Discoveries

Architecture decisions, prototype discoveries, and design rationale for i-said-yes.

## Prototype discoveries

Learned the hard way during prototyping. All apply directly to the plugin implementation.

### 1. The `if` filter silently blocks compound commands

The hook schema supports an `if` field for pre-filtering. `{ "if": "Bash(cd *)" }` **never fires** on `cd /path && git status` because Claude Code's permission matching explicitly prevents prefix rules from covering compound commands with `&&`.

**Implication:** Don't use `if` filters on the hook entries. The hooks must run on every Bash call and exit early for non-matching commands. This is fast (microseconds for the early exit).

### 2. Tilde is a shell parser feature, not a filesystem feature

Paths in JSON preserve `~` as a literal character. When read via `jq`, `realpath` receives a literal `~` which is not a valid directory.

**Implication:** All paths from JSON must have manual tilde expansion before `realpath`:

```bash
tp="${tp/#\~/$HOME}"
```

### 3. `--show-toplevel` breaks worktree detection

`git rev-parse --show-toplevel` returns different paths for main repo vs worktree. `--git-common-dir` returns the shared `.git` directory for both.

**Implication:** The same-repo gate must use `--git-common-dir`, not `--show-toplevel`.

### 4. Directive `additionalContext` gets flagged as prompt injection

`additionalContext` that reads like instructions ("use AskUserQuestion with this EXACT call...") triggers Claude's safety training. It looks like an injection.

**Implication:** State facts, not instructions. Label the source:

```
"[i-said-yes] This project (/path) is not trusted. The trust list is at /path/to/file.json..."
```

### 5. PreToolUse context gets buried — use PostToolUse for follow-ups

PreToolUse `additionalContext` is injected before the permission prompt. By the time Claude responds, it's buried under the prompt + user approval + command output.

**Implication:** Auto-approve logic goes in PreToolUse. Trust-offer logic goes in PostToolUse (fires right when Claude is composing its response).

## Architecture decisions

### Gate ordering: pattern first, not trust first

Pattern gate runs before trust gate despite trust being conceptually "gate 1." It's the cheapest check (pure regex, no I/O), and must run first to extract the cd target path needed by subsequent gates.

### Embedded trust command in additionalContext

The PostToolUse context embeds the full `cd-git-trust.sh` command with resolved absolute paths. Without this, Claude improvises a multi-step file manipulation (Read, ls, mkdir, Write) requiring ~5 approval prompts instead of 2.

### Feature-scoped naming (`cd-git-` prefix)

The plugin name "i-said-yes" is broader than any single feature — it could eventually remember any "yes" decision. Individual scripts and data files are prefixed with their feature name (`cd-git-`) so that when a second feature is added (e.g., cd+npm), naming doesn't get confusing. Nothing claims to be generic infrastructure.

### No subdirectory grouping yet

Scripts live flat in `scripts/` rather than `scripts/cd-git/`. Grouping into subdirectories is deferred until a second feature justifies it. This is invisible to plugin users since paths resolve via `${CLAUDE_PLUGIN_ROOT}`.

### Hooks.json: no `if` filters

The hook entries in `hooks.json` intentionally omit the `if` field. This is not an oversight — see Discovery 1 above.

### Plugin variable strategy

`${CLAUDE_PLUGIN_DATA}` and `${CLAUDE_PLUGIN_ROOT}` are available both as string substitutions in JSON configs and as exported environment variables inside hook script subprocesses. The plugin uses environment variables in scripts and string substitutions in hooks.json.

### Worktree trust: bidirectional verification

A naive worktree fallback could ask `git rev-parse --git-common-dir` from CWD and trust the answer. That's spoofable — any directory can plant a `.git/commondir` file claiming any common dir. The trust gate instead asks the trusted main repo's own `git worktree list` to confirm the suspect directory is a registered worktree. The attacker controls their own directory, not files inside a trusted main's `.git/worktrees/`, so they cannot forge a registration.

### Why the offer-trust hook offers the main repo path

Ephemeral worktree paths (e.g. `/private/tmp/cc-worktree-abc`) become dead entries in the trust file once the worktree is cleaned up. Main repo paths are stable and cover all current and future worktrees. When CWD is a worktree, the hook resolves to the main and offers that.

### Why the offer-trust hook bidirectionally verifies worktree claims

The offer hook would be a pure UX decision if it only chose which path to suggest. The trap: it also decides when to *stay silent*. A directory with a stale or crafted `.git` gitfile that merely claims to be a worktree of a trusted main would — without verification — be silently suppressed by the already-trusted check while the approve hook (which does verify) continued to reject auto-approval. The user would be stranded, approving prompts manually with no way back. Verifying the claim before using the derived main eliminates the trap: legitimate worktrees of trusted mains still get a silent exit, stale or crafted gitfiles fall back to offering the CWD path so the user can make a deliberate choice.

### Env sanitization on the worktree-list call

`git worktree list` is only trustworthy if it reflects the on-disk state of the main repo. `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`, `GIT_CEILING_DIRECTORIES`, and `GIT_DISCOVERY_ACROSS_FILESYSTEM` can all redirect git's discovery. If inherited from upstream, they would defeat the bidirectional check. The `env -u ...` prefix strips them only for this call.

### Trust gate: path check first, worktree fallback second

The path check is subprocess-free and handles the common case (Claude operating in a regularly-trusted main repo). The worktree fallback only runs on a path-check miss, and short-circuits without invoking git unless the resolved main is itself trusted. No new cost in the common case.

## Discoveries

### Known limitations

The plugin is an alternative to `claude --dangerously-skip-permissions` for users who are already operating in trusted repositories. That baseline sets the threat model: Claude itself is generating commands in a trusted user environment, not a malicious third party actively probing the trust gate. The following are known weaknesses against an active attacker; they are accepted because fixing them would not measurably raise the bar over the `--dangerously-skip-permissions` baseline users are already accepting.

1. `git rev-parse --git-common-dir` honors `.git/commondir` blindly. A directory with a crafted `commondir` file can claim any common dir for the same-repo gate, so auto-approval fires when `cd <evil>` happens from any CWD whose own common dir matches the spoof — i.e., from a trusted main repo or, since the worktree-trust change, any verified worktree of that main. The trust gate itself is unaffected because it uses bidirectional verification; only the cd-target check is spoofable.
2. Pattern gate cd-path admits command substitution. Double-quoted and unquoted cd target alternatives allow `$(...)` and backtick expansion.
3. Pattern gate is prefix-only. Anything after `git <cmd>` is unchecked — `cd /trusted && git status && <anything>` passes.
4. No git subcommand allowlisting. `git push`, `git config`, `git reset --hard` are auto-approved equally with `git status`.
5. The hook's non-worktree git invocations honor `GIT_*` environment variables. Only the worktree-list call sanitizes them.

## Prior prototype

The original prototype hooks were at `~/.claude/hooks/` and registered in `~/.claude/settings.json`. Those hook registrations have been removed — the plugin replaces them. The prototype scripts remain at `~/.claude/hooks/` as reference but are inactive.

Prototype discovery notes: `~/.claude/skills/capture-decisions/cd-git-hook-discoveries.md`
