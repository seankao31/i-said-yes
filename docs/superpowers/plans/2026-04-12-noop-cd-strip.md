# Noop CD Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Final review includes cross-model verification via codex-review-gate.

**Goal:** Strip no-op `cd <cwd> &&` prefixes from compound Bash commands so the remaining command goes through normal permission flow.

**Architecture:** A new PreToolUse hook script (`noop-cd-strip.sh`) that detects when a compound command's leading `cd` target resolves to the current working directory, strips it, and returns `updatedInput` with no `permissionDecision`. Listed first in `hooks.json` so it runs before `cd-git-approve.sh`.

**Tech Stack:** Bash, jq, BATS (bats-assert, bats-support)

**Spec:** `docs/superpowers/specs/2026-04-12-noop-cd-strip-design.md`

---

### Task 1: Scaffold test file and script with early-exit tests

**Files:**
- Create: `test/noop-cd-strip.bats`
- Create: `scripts/noop-cd-strip.sh`

- [ ] **Step 1: Create the test file with early-exit tests**

```bash
#!/usr/bin/env bats

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/noop-cd-strip.sh"

# Helper: pipe input to script via run (for tests asserting empty output)
run_script() {
  local input="$1"
  run bash -c 'echo "$1" | "$2"' _ "$input" "$SCRIPT"
}

# --- Early exit: non-matching inputs ---

@test "ignores non-Bash tools" {
  local input='{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"cwd":"/tmp"}'
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores empty command" {
  local input
  input=$(hook_input "Bash" "" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores missing cwd" {
  local input='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores bare cd with no &&" {
  local input
  input=$(hook_input "Bash" "cd /tmp" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores cd with semicolon separator" {
  local input
  input=$(hook_input "Bash" "cd /tmp ; echo hello" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores simple commands (no cd prefix)" {
  local input
  input=$(hook_input "Bash" "git status" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}
```

- [ ] **Step 2: Create minimal script that exits silently**

```bash
#!/bin/bash
# PreToolUse hook: strip no-op "cd <path> &&" prefix from compound commands
# when the cd target resolves to the current working directory.
# Returns updatedInput with the remaining command, no permissionDecision.
# Security for the remaining command is delegated to normal permission flow.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" != "Bash" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$COMMAND" ] || [ -z "$CWD" ] && exit 0

exit 0
```

Make it executable:
```bash
chmod +x scripts/noop-cd-strip.sh
```

- [ ] **Step 3: Run tests — all should pass (early exits)**

Run: `./node_modules/.bin/bats test/noop-cd-strip.bats`
Expected: 6 tests, all pass

- [ ] **Step 4: Commit**

```bash
git add test/noop-cd-strip.bats scripts/noop-cd-strip.sh
git commit -m "Scaffold noop-cd-strip with early-exit tests"
```

---

### Task 2: Implement no-op cd detection and rewrite

**Files:**
- Modify: `test/noop-cd-strip.bats`
- Modify: `scripts/noop-cd-strip.sh`

- [ ] **Step 1: Add failing tests for no-op cd rewrite**

Append to `test/noop-cd-strip.bats`:

```bash
# --- No-op cd detected: rewrite ---

@test "strips cd . && from compound command" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd . && echo hello" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "echo hello"
}

@test "strips cd <absolute-cwd> && from compound command" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd \"$dir\" && git status" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "git status"
}

@test "strips cd with single-quoted cwd path" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd '$dir' && npm install" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "npm install"
}

@test "strips cd with unquoted cwd path" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd $dir && cargo build" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "cargo build"
}

@test "strips cd with tilde path matching cwd" {
  # Use $HOME as cwd since ~ expands to $HOME
  local output
  output=$(hook_input "Bash" "cd ~ && echo hello" "$HOME" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "echo hello"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./node_modules/.bin/bats test/noop-cd-strip.bats`
Expected: 5 new tests FAIL (script exits without output for all commands)

- [ ] **Step 3: Implement rewrite logic**

Replace the `exit 0` at the end of `scripts/noop-cd-strip.sh` with:

```bash
# Match: cd <path> && <rest>
if [[ "$COMMAND" =~ ^cd[[:space:]]+(\"[^\"]+\"|\'[^\']+\'|[^[:space:]&]+)[[:space:]]*\&\&[[:space:]]*(.+)$ ]]; then
  TARGET="${BASH_REMATCH[1]}"
  REST="${BASH_REMATCH[2]}"

  # Strip quotes if present
  TARGET="${TARGET#\"}"
  TARGET="${TARGET%\"}"
  TARGET="${TARGET#\'}"
  TARGET="${TARGET%\'}"

  # Expand ~ to $HOME (tilde is literal in JSON, not shell-expanded)
  TARGET="${TARGET/#\~/$HOME}"

  # Resolve both paths
  CWD_RESOLVED=$(realpath "$CWD" 2>/dev/null) || exit 0
  TARGET_RESOLVED=$(cd "$CWD" 2>/dev/null && realpath "$TARGET" 2>/dev/null) || exit 0

  # Only rewrite if cd target == cwd (no-op cd)
  if [ "$TARGET_RESOLVED" = "$CWD_RESOLVED" ]; then
    jq -n --arg cmd "$REST" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: {
          command: $cmd
        }
      }
    }'
    exit 0
  fi
fi

# Not a matching command
exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./node_modules/.bin/bats test/noop-cd-strip.bats`
Expected: 11 tests, all pass

- [ ] **Step 5: Commit**

```bash
git add test/noop-cd-strip.bats scripts/noop-cd-strip.sh
git commit -m "Implement no-op cd detection and rewrite via updatedInput"
```

---

### Task 3: Add non-matching and edge case tests

**Files:**
- Modify: `test/noop-cd-strip.bats`

- [ ] **Step 1: Add tests for cd to different directory (no rewrite)**

Append to `test/noop-cd-strip.bats`:

```bash
# --- Non-matching cd: no rewrite ---

@test "does not strip cd to different directory" {
  local dir="$TEST_TEMP/here"
  local other="$TEST_TEMP/there"
  mkdir -p "$dir" "$other"

  local input
  input=$(hook_input "Bash" "cd \"$other\" && echo hello" "$dir")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not strip cd to nonexistent path" {
  local dir="$TEST_TEMP/here"
  mkdir -p "$dir"

  local input
  input=$(hook_input "Bash" "cd /no/such/path && echo hello" "$dir")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not strip cd to subdirectory of cwd" {
  local dir="$TEST_TEMP/parent"
  mkdir -p "$dir/child"

  local input
  input=$(hook_input "Bash" "cd \"$dir/child\" && echo hello" "$dir")
  run_script "$input"
  assert_success
  assert_output ""
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `./node_modules/.bin/bats test/noop-cd-strip.bats`
Expected: 14 tests, all pass

- [ ] **Step 3: Add chained compound command test**

Append to `test/noop-cd-strip.bats`:

```bash
# --- Chained compounds ---

@test "strips only leading cd, preserves chained &&" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd \"$dir\" && echo a && echo b" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "echo a && echo b"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./node_modules/.bin/bats test/noop-cd-strip.bats`
Expected: 15 tests, all pass

- [ ] **Step 5: Add output format tests**

Append to `test/noop-cd-strip.bats`:

```bash
# --- Output format ---

@test "output includes hookEventName PreToolUse" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd . && echo hello" "$dir" | "$SCRIPT")
  local event
  event=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')
  assert_equal "$event" "PreToolUse"
}

@test "output does not include permissionDecision" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd . && echo hello" "$dir" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "absent"')
  assert_equal "$decision" "absent"
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./node_modules/.bin/bats test/noop-cd-strip.bats`
Expected: 17 tests, all pass

- [ ] **Step 7: Commit**

```bash
git add test/noop-cd-strip.bats
git commit -m "Add non-matching, chained, and output format tests for noop-cd-strip"
```

---

### Task 4: Register hook in hooks.json

**Files:**
- Modify: `hooks/hooks.json`

- [ ] **Step 1: Update hooks.json to list noop-cd-strip first**

Replace the PreToolUse section in `hooks/hooks.json` with:

```json
"PreToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/scripts/noop-cd-strip.sh"
      },
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/scripts/cd-git-approve.sh"
      }
    ]
  }
],
```

- [ ] **Step 2: Run all existing tests to verify nothing broke**

Run: `./node_modules/.bin/bats test/`
Expected: All tests pass (existing cd-git-approve, cd-git-offer-trust, cd-git-trust, cd-git-worktree, smoke, and new noop-cd-strip)

- [ ] **Step 3: Commit**

```bash
git add hooks/hooks.json
git commit -m "Register noop-cd-strip hook before cd-git-approve in hooks.json"
```

---

### Task 5: Manual integration test and hook ordering verification

This task requires a live Claude Code session to verify end-to-end behavior.

- [ ] **Step 1: Reload plugin**

In a Claude Code session, run `/reload-plugins` or restart.

- [ ] **Step 2: Test no-op cd stripping**

Ask the agent to run `cd . && echo hello`. Verify:
- The command that executes is `echo hello` (cd stripped)
- Normal permission flow applies (no auto-approve from the hook)

- [ ] **Step 3: Test hook ordering**

Ask the agent to run `cd . && git status` in a trusted project. Verify:
- The command that executes is `git status` (cd stripped by noop-cd-strip)
- Observe whether cd-git-approve also fires (check if it auto-approves or if normal flow handles it)

If cd-git-approve sees the original input and auto-approves, note this as a follow-up: add an early-exit to cd-git-approve when cd target == cwd.

- [ ] **Step 4: Test non-matching cd preserved**

Ask the agent to run `cd /some/other/path && echo hello`. Verify:
- The cd is NOT stripped (different directory)
- Normal compound-command permission prompt appears

- [ ] **Step 5: Commit any fixes**

If the manual tests reveal issues, fix and commit. Otherwise, no action needed.

---

### Task 6: Update documentation

**Files:**
- Modify: `docs/spec.md`
- Modify: `README.md`

- [ ] **Step 1: Add noop-cd-strip to spec.md**

Add to the Plugin structure section in `docs/spec.md`, after the `cd-git-worktree.sh` entry:
```
│   ├── noop-cd-strip.sh            # PreToolUse: strip no-op cd prefix from compounds
```

Add a new section after "Auto-approve flow (PreToolUse)":

```markdown
## No-op cd strip (PreToolUse)

When any compound command starts with `cd <path> &&`:

```
Pattern match: cd <path> && <rest>
Resolve cd target relative to CWD
if target == CWD:
    return updatedInput: { command: <rest> }   (no permissionDecision)
```

Runs before cd-git-approve in hooks.json. When the cd is a no-op, the remaining command goes through normal permission evaluation — no trust gate, no pattern gate.
```

Add `noop-cd-strip.bats` to the test listing.

- [ ] **Step 2: Update README.md**

Add a brief mention in the README that the plugin also strips no-op cd prefixes from compound commands, simplifying them before permission evaluation.

- [ ] **Step 3: Run all tests one final time**

Run: `./node_modules/.bin/bats test/`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add docs/spec.md README.md
git commit -m "Document noop-cd-strip hook in spec and README"
```
