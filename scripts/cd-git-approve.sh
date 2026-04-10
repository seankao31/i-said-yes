#!/bin/bash
# PreToolUse hook: auto-approve "cd <path> && git <cmd>" when ALL of:
#   1. Trust gate — project (or the main repo it is a worktree of) is listed
#      in $CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json
#   2. Pattern gate — command matches cd <path> && git <cmd>
#   3. Same-repo gate — cd target shares git-common-dir with cwd
#
# All three must pass. Any failure defers to Claude Code's normal permission prompt.

TRUST_FILE="$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cd-git-worktree.sh
source "$SCRIPT_DIR/cd-git-worktree.sh"

# Return 0 if the given canonicalized path equals a trusted path or sits
# beneath one. Reads the trust file on each call; callers hit it at most
# twice per invocation, so caching is not worth the complexity.
is_path_trusted() {
  local candidate="$1"
  [ -f "$TRUST_FILE" ] || return 1
  local tp resolved_tp
  while IFS= read -r tp; do
    [ -z "$tp" ] && continue
    tp="${tp/#\~/$HOME}"
    resolved_tp=$(realpath "$tp" 2>/dev/null) || continue
    if [[ "$candidate" == "$resolved_tp" || "$candidate" == "$resolved_tp"/* ]]; then
      return 0
    fi
  done < <(jq -r '.[]' "$TRUST_FILE" 2>/dev/null)
  return 1
}

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
  if is_path_trusted "$CWD_RESOLVED"; then
    TRUSTED=true
  else
    # Fallback: CWD may be a git worktree of a trusted main repo. Resolve
    # CWD to its claimed main, require that main to be trusted, then ask
    # the main to confirm CWD is one of its worktrees.
    MAIN_REPO=$(cd_git_resolve_main_repo "$CWD_RESOLVED")
    if [ -n "$MAIN_REPO" ]; then
      MAIN_REAL=$(realpath "$MAIN_REPO" 2>/dev/null)
      if [ -n "$MAIN_REAL" ] && is_path_trusted "$MAIN_REAL"; then
        if cd_git_verify_worktree "$CWD_RESOLVED" "$MAIN_REAL"; then
          TRUSTED=true
        fi
      fi
    fi
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
