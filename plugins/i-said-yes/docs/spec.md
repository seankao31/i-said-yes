# i-said-yes

A Claude Code plugin that remembers your trust decisions. When you approve a compound command pattern once for a project, it stops asking.

## Problem

Claude Code prompts for permission on every compound `cd <path> && git <cmd>` command to prevent bare repository attacks. This is a legitimate security measure, but disruptive in trusted personal projects where you're approving the same prompt dozens of times per session.

## Solution

A plugin with two hooks that implement a "trust once, approve forever" flow:

1. **PostToolUse hook** — detects when a cd+git command runs in an untrusted project. Injects context so Claude offers to trust the project.
2. **PreToolUse hook** — for trusted projects, auto-approves matching commands that pass security checks.

The plugin is designed to be extensible beyond cd+git. Future patterns (cd+npm, cd+cargo, etc.) can reuse the same trust list and security gates.

## Plugin structure

```
i-said-yes/
├── .claude-plugin/
│   └── plugin.json
├── hooks/
│   └── hooks.json                  # PreToolUse + PostToolUse registrations
├── scripts/
│   ├── cd-git-approve.sh           # PreToolUse: pattern + trust + same-repo gates
│   ├── cd-git-offer-trust.sh       # PostToolUse: offer to trust untrusted projects
│   ├── cd-git-trust.sh             # Adds a project path to the cd+git trust list
│   └── cd-git-worktree.sh          # Sourced library: worktree resolution and verification
├── test/
│   ├── cd-git-approve.bats         # Three-gate approval logic
│   ├── cd-git-offer-trust.bats     # Trust offer detection
│   ├── cd-git-trust.bats           # Trust list manipulation
│   ├── cd-git-worktree.bats        # Worktree resolution and verification library
│   ├── smoke.bats                  # Bats infrastructure smoke test
│   └── test_helper.bash            # Shared setup, teardown, and helpers
├── docs/
│   ├── spec.md                     # This file
│   └── decisions.md                # Architecture decisions and discoveries
├── package.json
├── README.md
└── LICENSE
```

## Naming convention

All files are prefixed with their feature name (`cd-git-`). Nothing claims to be generic infrastructure. When a second feature is added (e.g., cd+npm), it gets its own `cd-npm-*` scripts and data file. Subdirectory grouping (`scripts/cd-git/`) is deferred until a second feature justifies it.

## Data storage

cd+git trust list: `${CLAUDE_PLUGIN_DATA}/cd-git-trusted-projects.json` — a JSON array of absolute paths.

`${CLAUDE_PLUGIN_DATA}` resolves to `~/.claude/plugins/data/{plugin-id}/`. Both `${CLAUDE_PLUGIN_DATA}` and `${CLAUDE_PLUGIN_ROOT}` are available as environment variables inside hook scripts and as string substitutions in JSON configs.

## Security model: three gates

All three must pass for auto-approval. Any failure defers to Claude Code's normal permission prompt.

1. **Trust gate** — Is the project in the trust list? Trust is stored in user-scoped plugin data, outside any project's reach. A malicious repo cannot grant itself trust. The trust check accepts both direct path matches and verified worktrees of trusted main repos (see "Worktree support" below).
2. **Pattern gate** — Does the command match a known-safe compound pattern? Only specific patterns are approved, not arbitrary compound commands.
3. **Same-repo gate** — Does `git rev-parse --git-common-dir` match between the cd target and the project root? Prevents auto-approving cd into nested malicious repos, submodules with untrusted code, or unrelated repositories.

### Worktree support

When CWD is a git worktree (its `.git` is a gitfile, not a directory), the trust gate falls back to:

1. Parsing CWD's `.git` gitfile to derive the claimed main repo path (a shape check rejects gitfiles that do not live under `.../worktrees/<name>`).
2. Checking that the derived main repo path is in the trust list — equality or subdirectory of a trusted ancestor.
3. Running `git worktree list --porcelain` from the trusted main with sanitized environment (`GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`, `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM` unset) and confirming CWD is listed.

All three steps must succeed. The check is bidirectional: the suspect directory claims a main, and the trusted main must independently confirm the claim. This means trusting the main repo path covers all of its current and future worktrees without any extra configuration.

The offer-trust hook also runs bidirectional verification before accepting the derived main as the offer path. Legitimate worktrees of trusted mains exit silently; stale or crafted gitfiles fall back to offering CWD so the user can make a deliberate choice. See `docs/decisions.md` for the rationale.

#### `cd_git_resolve_main_repo`

Pure file I/O, no git subprocess. Sourced by both hooks. Given a directory, returns the main repo path it belongs to — or the directory itself if it is already a main repo.

1. Check `<dir>/.git`:
   - **Directory** → `<dir>` is a main repo. Return `<dir>`.
   - **File** → it is a worktree gitfile. Continue.
   - Otherwise → fail.
2. Read the gitfile. First line must start with literal `gitdir: `. Extract the path after the prefix.
3. Resolve the gitdir path relative to the gitfile's own directory (handles `worktree.useRelativePaths=true` / git 2.48+ relative entries).
4. **Shape check:** require `basename $(dirname "$gitdir_real") == "worktrees"`. Rejects gitfiles pointing outside the expected `.../worktrees/<name>` shape.
5. Derive `main_git = realpath "$gitdir_real/../.."`.
6. Derive main repo path: if `main_git` ends in `/.git` → `realpath "$main_git/.."`. Otherwise → `main_git` itself (bare repo).
7. Return the main repo path.

**Out of scope:** CWD being a bare repo with no inner `.git`. Step 1 falls through; the path-based trust check still handles explicitly trusted bare repos.

#### `cd_git_verify_worktree`

Bidirectional verification. Sourced by both hooks. Given a directory and a main repo path, returns 0 if the directory is a registered worktree of that main.

1. Canonicalize both paths via `realpath`.
2. Run from the trusted main with sanitized environment:
   ```bash
   env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE \
       -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
       git -C "$main_real" worktree list --porcelain -z
   ```
   `-z` gives null-separated records; env sanitization prevents a poisoned upstream env from redirecting git's discovery.
3. Extract every `worktree <path>` value and canonicalize via `realpath`.
4. If any equals `dir_real`, return 0. Otherwise non-zero.

**Edge cases:**
- `dir_real` is the main repo itself → succeeds (main repo is the first entry in `git worktree list`).
- Bare main repo → reported as `worktree <bare-dir>` with a `bare` line; parse is unaffected.
- Prunable worktrees → accepted (once legitimately registered; rejecting them serves no purpose under the threat model).
- `git worktree list` fails → treated as "not verified"; trust gate defers to normal prompt.

## Trust offer flow (PostToolUse)

When a cd+git command completes:

```
Pattern match: cd <path> && git <cmd>

# Resolve offer path
main = cd_git_resolve_main_repo(CWD)
offer_path = main if non-empty, else CWD

# Verify worktree claim before using derived main
if main is non-empty and main != CWD:
    if not cd_git_verify_worktree(CWD, main):
        offer_path = CWD

# Already trusted? Stay silent
for each tp in trust file:
    if offer_path == tp or offer_path is under tp:
        exit

# Inject offer
emit additionalContext describing the untrusted project at offer_path
```

Claude presents a yes/no question via `AskUserQuestion`. If yes, Claude runs `cd-git-trust.sh` with `offer_path`.

## Auto-approve flow (PreToolUse)

When a cd+git command is about to run:

```
Pattern gate: regex match → extract TARGET from `cd <path> && git <cmd>`

─── Trust gate ───

# Branch 1: direct path check (subprocess-free)
for each tp in trust file:
    if CWD == tp or CWD is under tp:
        TRUSTED=true; break

# Branch 2: worktree fallback (only if branch 1 missed)
if not TRUSTED:
    main = cd_git_resolve_main_repo(CWD)
    if main is non-empty:
        for each tp in trust file:
            if main == tp or main is under tp:
                TRUSTED = cd_git_verify_worktree(CWD, main)
                break

if not TRUSTED: exit    # defer to normal prompt

─── Same-repo gate ───
compare git-common-dir of TARGET vs CWD
if mismatch: exit       # defer to normal prompt

→ output permissionDecision: "allow"
```

## Testing

Tests use bats (Bash Automated Testing System), installed as a dev dependency via bun.

```bash
bun run test              # run all tests
./node_modules/.bin/bats test/cd-git-approve.bats  # run one suite
```

End-to-end: `claude --plugin-dir /path/to/i-said-yes`, then `/reload-plugins` for live changes.

## Future extensibility

The trust list is pattern-agnostic — it just says "this project is trusted." New compound command patterns (cd+npm, cd+cargo, cd+make) can be added with new regex branches and appropriate safety gates. The PostToolUse hook would similarly expand its detection regex.

## Open questions

- Should there be a skill/command for managing the trust list? (e.g., `/i-said-yes:list`, `/i-said-yes:remove`)
- Should the plugin support pattern-specific trust? (e.g., trust project X for git but not npm)
- What's the right UX for revoking trust?
