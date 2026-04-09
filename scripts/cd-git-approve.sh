#!/bin/bash
# PreToolUse hook: auto-approve "cd <path> && git <cmd>" when ALL of:
#   1. Trust gate — project is in $CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json
#   2. Pattern gate — command matches cd <path> && git <cmd>
#   3. Same-repo gate — cd target shares git-common-dir with cwd
#
# All three must pass. Any failure defers to Claude Code's normal permission prompt.

TRUST_FILE="$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" != "Bash" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$COMMAND" ] || [ -z "$CWD" ] && exit 0

# --- Pattern gate: is this cd <path> && git <cmd>? ---
# Pattern gate runs first despite trust being "gate 1" conceptually:
# it's the cheapest check (pure regex, no I/O), and we need the regex
# match to extract the cd target path for the subsequent gates.
if [[ "$COMMAND" =~ ^cd[[:space:]]+(\"[^\"]+\"|\'[^\']+\'|[^[:space:]&]+)[[:space:]]*\&\&[[:space:]]*git[[:space:]] ]]; then
  TARGET="${BASH_REMATCH[1]}"
  # Strip quotes if present
  TARGET="${TARGET#\"}"
  TARGET="${TARGET%\"}"
  TARGET="${TARGET#\'}"
  TARGET="${TARGET%\'}"

  # Expand ~ to $HOME (tilde is literal in JSON, not shell-expanded)
  TARGET="${TARGET/#\~/$HOME}"

  # --- Trust gate: is this project trusted? ---
  CWD_RESOLVED=$(realpath "$CWD" 2>/dev/null) || exit 0
  TRUSTED=false
  if [ -f "$TRUST_FILE" ]; then
    while IFS= read -r tp; do
      [ -z "$tp" ] && continue
      tp="${tp/#\~/$HOME}"
      RESOLVED_TP=$(realpath "$tp" 2>/dev/null) || continue
      if [[ "$CWD_RESOLVED" == "$RESOLVED_TP" || "$CWD_RESOLVED" == "$RESOLVED_TP"/* ]]; then
        TRUSTED=true
        break
      fi
    done < <(jq -r '.[]' "$TRUST_FILE" 2>/dev/null)
  fi

  [ "$TRUSTED" != true ] && exit 0

  # Resolve cd target to absolute path
  RESOLVED=$(cd "$CWD" 2>/dev/null && realpath "$TARGET" 2>/dev/null) || exit 0

  # --- Same-repo gate: does git-common-dir match? ---
  # Uses --git-common-dir instead of --show-toplevel so worktrees are recognized
  # as the same repo, while nested repos and submodules are correctly rejected.
  TARGET_COMMON=$(cd "$RESOLVED" 2>/dev/null && realpath "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null) || exit 0
  PROJECT_COMMON=$(cd "$CWD_RESOLVED" 2>/dev/null && realpath "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null) || exit 0

  [ "$TARGET_COMMON" != "$PROJECT_COMMON" ] && exit 0

  # All three gates passed — auto-approve
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "cd+git in trusted project, same git repo (or worktree)"
    }
  }'
  exit 0
fi

# Not a matching command
exit 0
