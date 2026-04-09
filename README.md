# i-said-yes

A Claude Code plugin that remembers your trust decisions. Approve once, auto-approve forever.

## The problem

Claude Code asks for permission every time it runs `cd <path> && git status` (or any compound cd+git command) to protect against bare repository attacks. In trusted personal projects, this means approving the same prompt dozens of times per session.

## How it works

The first time a cd+git command runs in a project, Claude asks if you want to trust it. Say yes, and future cd+git commands in that project are auto-approved — as long as they pass three security gates:

1. **Trust gate** — Is this project in your trust list?
2. **Pattern gate** — Is this a known-safe command pattern (`cd <path> && git <cmd>`)?
3. **Same-repo gate** — Does the cd target belong to the same git repo? (Prevents sneaky cd into nested malicious repos or submodules.)

If any gate fails, Claude Code's normal permission prompt takes over.

## Install

```bash
claude plugin add /path/to/i-said-yes
```

Or run with it temporarily:

```bash
claude --plugin-dir /path/to/i-said-yes
```

## Usage

Just use Claude Code normally. When you run a cd+git command in an untrusted project, Claude will ask:

> This project is not in the trusted git projects list. Would you like to trust it?

Say yes. That's it — future cd+git commands in that project are auto-approved.

## Trust storage

Trusted projects are stored in `~/.claude/plugins/data/{plugin-id}/cd-git-trusted-projects.json` — a JSON array of absolute paths. This file lives in Claude Code's plugin data directory, outside any project's reach.

## Security

- A malicious repo **cannot** grant itself trust — the trust list lives in user-scoped plugin data.
- Nested repos, submodules, and unrelated repositories are **not** auto-approved — the same-repo gate catches them using `git rev-parse --git-common-dir`.
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
