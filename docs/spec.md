# i-said-yes

A Claude Code plugin that remembers your trust decisions. When you approve a compound command pattern once for a project, it stops asking.

## Problem

Claude Code prompts for permission on every compound `cd <path> && git <cmd>` command to prevent bare repository attacks. This is a legitimate security measure, but disruptive in trusted personal projects where you're approving the same prompt dozens of times per session.

## Solution

A plugin with PreToolUse and PostToolUse hooks that implement a "trust once, approve forever" flow:

1. **PostToolUse hook** — detects when a cd+git command runs in an untrusted project. Injects context so Claude offers to trust the project.
2. **PreToolUse hook** — for trusted projects, auto-approves matching commands that pass security checks.

A separate PreToolUse hook strips no-op `cd` prefixes from compound commands before the approval hooks run, simplifying commands where the cd target matches the current working directory.

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
│   ├── cd-git-worktree.sh          # Sourced library: worktree resolution and verification
│   └── noop-cd-strip.sh            # PreToolUse: strip no-op cd prefix from compounds
├── test/
│   ├── cd-git-approve.bats         # Three-gate approval logic
│   ├── cd-git-offer-trust.bats     # Trust offer detection
│   ├── cd-git-trust.bats           # Trust list manipulation
│   ├── cd-git-worktree.bats        # Worktree resolution and verification library
│   ├── noop-cd-strip.bats          # No-op cd prefix stripping
│   ├── smoke.bats                  # Bats infrastructure smoke test
│   └── test_helper.bash            # Shared setup, teardown, and helpers
├── docs/
│   ├── spec.md                     # This file — plugin overview
│   ├── cd-git.md                   # cd+git auto-approve: security model, flows
│   ├── noop-cd-strip.md            # No-op cd strip: design and scope
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

## Feature documentation

- **[cd+git auto-approve](cd-git.md)** — three-gate security model, worktree support, trust offer and auto-approve flows.
- **[No-op cd strip](noop-cd-strip.md)** — strips `cd <cwd> &&` prefixes from compound commands before permission evaluation.
- **[Decisions](decisions.md)** — architecture decisions, prototype discoveries, and design rationale.

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
