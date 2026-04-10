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

1. Parsing CWD's `.git` gitfile directly to derive the claimed main repo path (a shape check rejects gitfiles that do not live under `.../worktrees/<name>`).
2. Checking that the derived main repo path is in the trust list — equality or subdirectory of a trusted ancestor.
3. Running `git worktree list --porcelain` from the trusted main with sanitized environment (`GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`, `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM` unset) and confirming CWD is listed.

All three steps must succeed. The check is bidirectional: the suspect directory claims a main, and the trusted main must independently confirm the claim. This means trusting the main repo path covers all of its current and future worktrees without any extra configuration.

The offer-trust hook uses the same gitfile resolution (but not the bidirectional verification) to surface the main repo path instead of the ephemeral worktree path when Claude asks the user whether to trust a project. Unverified parsing is sufficient there — the user is the final arbiter.

## Trust offer flow (PostToolUse)

When a cd+git command completes in an untrusted project:

1. Hook injects `additionalContext` describing the situation factually
2. Claude presents a yes/no question via `AskUserQuestion`
3. If yes, Claude runs `cd-git-trust.sh` with the project path

## Auto-approve flow (PreToolUse)

When a cd+git command is about to run in a trusted project:

1. Pattern gate: regex match against `^cd <path> && git <cmd>`
2. Trust gate: project path or ancestor listed in trust file — or CWD is a verified worktree of such a main repo (see "Worktree support")
3. Same-repo gate: compare `--git-common-dir` between cd target and cwd
4. Output `permissionDecision: "allow"` if all pass

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
