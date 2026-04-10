# I Said Yes

![DID I STUTTER?](https://github.com/user-attachments/assets/e1f70b41-3fa1-4b18-93e0-5aeab51c69d7)

## What is this

A Claude Code plugin that remembers your trust decisions. Approve once, auto-approve forever.

Claude Code asks for permission every time it runs `cd <path> && git status` (or any compound cd+git command) to protect against bare repository attacks.
In trusted personal projects, this means approving the same prompt dozens of times per session.

No more "Compound commands with cd and git require approval to prevent bare repository attacks"

## Getting Started

### Install

```
/plugin marketplace add seankao31/i-said-yes
/plugin install i-said-yes
```

Then run `/reload-plugins` to apply.

### Usage

Just use Claude Code normally. When you run a cd+git command in an untrusted project, Claude will ask:

> This project is not in the trusted git projects list. Would you like to trust it?

Say yes. That's it — future cd+git commands in that project are auto-approved.

## Supported commands

| Pattern | Example |
|---|---|
| `cd <path> && git <cmd>` | `cd /my/project && git status` |

That's currently it. The plugin is designed to support additional patterns in the future (cd+npm, cd+cargo, etc.), but only cd+git is implemented today.

## How it works

The first time a cd+git command runs in a project, Claude asks if you want to trust it. Say yes, and future cd+git commands in that project are auto-approved — as long as they pass three security gates:

1. **Pattern gate** — Is this a known-safe command pattern (`cd <path> && git <cmd>`)?
2. **Trust gate** — Is this project in your trust list?
3. **Same-repo gate** — Does `git rev-parse --git-common-dir` match between the cd target and the project root? This catches cd into nested malicious repos, submodules, or unrelated repositories.

If any gate fails, Claude Code's normal permission prompt takes over.

### Worktrees

Trust a project once and its git worktrees come along for free. When Claude Code operates from inside a worktree, the plugin resolves the worktree to its main repo and asks that main repo to confirm the worktree is really one of its own — so you only ever trust the main repo path, never the ephemeral worktree path.

## Trust storage

Trusted projects are stored in `~/.claude/plugins/data/{plugin-id}/cd-git-trusted-projects.json` — a JSON array of absolute paths. This file lives in Claude Code's plugin data directory, outside any project's reach.

## Security

- A malicious repo **cannot** grant itself trust — the trust list lives in user-scoped plugin data.
- Nested repos, submodules, and unrelated repositories are **not** auto-approved — the same-repo gate catches them using `git rev-parse --git-common-dir`.
- Spoofed worktree gitfiles are **rejected** — the plugin bidirectionally verifies any worktree claim against `git worktree list` on the trusted main repo before granting trust.
- Only specific compound patterns are approved, not arbitrary commands.

## Development

```bash
bun install               # install test dependencies
bun run test              # run all tests
```

Test the plugin live:

```bash
claude --plugin-dir /path/to/i-said-yes
```

Use `/reload-plugins` inside a session to pick up changes without restarting.

## License

MIT
