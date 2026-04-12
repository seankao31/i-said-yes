# Strip no-op cd from compound commands

ENG-116: Auto-approve compound Bash cd commands when target matches cwd

## Problem

Compound commands like `cd /some/path && git status` trigger a permission prompt every time, even when `/some/path` equals the agent's current working directory — making the `cd` a no-op. The compound syntax is the only reason Claude Code prompts; the tail command alone would go through normal permission flow.

## Solution

A new PreToolUse hook (`scripts/noop-cd-strip.sh`) that detects compound commands where the leading `cd` target resolves to the current working directory, strips the no-op `cd <path> &&` prefix, and returns the remaining command via `updatedInput` with no `permissionDecision`. The rewritten command then goes through Claude Code's normal permission evaluation.

## Hook behavior

`noop-cd-strip.sh` is a PreToolUse hook on Bash commands that:

1. Matches `cd <path> && <rest>` (any compound command starting with cd).
2. Resolves `<path>` relative to cwd, handling quoted paths (single/double), unquoted paths, and tilde expansion — same path resolution logic as existing hooks.
3. If resolved path == resolved cwd → returns `updatedInput: { command: "<rest>" }` with **no** `permissionDecision`.
4. Otherwise → exits silently (defers to other hooks / normal flow).

No trust gate, no pattern gate, no same-repo gate. This is pure command simplification. Security is delegated entirely to whatever handles the resulting command.

## Hook ordering

Both hooks are registered in the same `hooks.json` entry, with `noop-cd-strip.sh` listed first:

```json
{
  "matcher": "Bash",
  "hooks": [
    { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/noop-cd-strip.sh" },
    { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/cd-git-approve.sh" }
  ]
}
```

**Open question**: Does `cd-git-approve` see the rewritten input or the original? If rewritten, the separation is clean — `cd-git-approve` won't match a command that no longer starts with `cd`. If original, `cd-git-approve` would also fire and return `permissionDecision: "allow"`, auto-approving the rewritten command. In that case, an early-exit should be added to `cd-git-approve` when cd target == cwd. This will be tested empirically during implementation.

## Scope

**Stripped:**
- `cd <path> && <rest>` where resolved path == resolved cwd, for any `<rest>`
- Quoted paths (single/double), unquoted paths, tilde expansion
- Chained `&&`: `cd . && echo a && echo b` → `echo a && echo b` (everything after the first `&&` is `<rest>`)

**Not stripped:**
- `cd <different-path> && <rest>` — cd goes somewhere else
- `cd <path> ; <rest>` — semicolons (different semantics)
- `cd <path> || <rest>` — different operator
- Bare `cd <path>` with no `&&` — not a compound command
- Path doesn't exist — `realpath` fails, hook exits silently

## Naming

`noop-cd-strip.sh` — describes what it does (strips no-op cd prefixes), not tied to any specific tool. Test file: `test/noop-cd-strip.bats`.

## Testing

New test file `test/noop-cd-strip.bats` using existing BATS patterns (real git repos, isolated temp dirs):

1. **Early exits**: non-Bash tool, no command, no cwd, bare `cd <path>` (no `&&`), semicolon separator
2. **No-op cd detected (rewrites)**: `cd . && echo hello`, `cd <absolute-cwd> && git status`, `cd "<quoted-cwd>" && npm install`, tilde path matching cwd
3. **Non-matching cd (no rewrite)**: cd to different directory, cd to nonexistent path
4. **Chained compounds**: `cd . && echo a && echo b` → `echo a && echo b`
5. **Output format**: confirms `updatedInput.command` is set, confirms no `permissionDecision` in output

No changes to existing `cd-git-approve.bats`.

## Technical notes

`updatedInput` without `permissionDecision` is not documented in the official Claude Code hooks docs, but was verified empirically (2026-04-12): the rewrite is applied and the command goes through normal permission evaluation. This is distinct from `permissionDecision: "defer"`, which ignores `updatedInput`.
