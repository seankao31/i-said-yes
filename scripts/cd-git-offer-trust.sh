#!/bin/bash
# PostToolUse hook: after a cd+git command completes in an untrusted project,
# inject context so Claude offers to trust the project.
#
# Fires right when Claude is composing its response, so the context is fresh.
# States facts (not instructions) to avoid prompt injection detection.
#
# When CWD is a git worktree, the hook offers the main repo path rather than
# the worktree path. Ephemeral worktree paths in the trust file become dead
# entries; the main repo path covers the main and all of its worktrees.

TRUST_FILE="$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cd-git-worktree.sh
source "$SCRIPT_DIR/cd-git-worktree.sh"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" != "Bash" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$COMMAND" ] || [ -z "$CWD" ] && exit 0

# Only care about cd <path> && git <cmd> patterns
[[ "$COMMAND" =~ ^cd[[:space:]].*\&\&[[:space:]]*git[[:space:]] ]] || exit 0

CWD_RESOLVED=$(realpath "$CWD" 2>/dev/null) || exit 0

# Resolve CWD to the main repo it belongs to. cd_git_resolve_main_repo returns
# CWD itself for a main repo and the derived main for a worktree. Falling back
# to CWD preserves behavior for shapes it does not recognize.
OFFER_PATH=$(cd_git_resolve_main_repo "$CWD_RESOLVED")
[ -z "$OFFER_PATH" ] && OFFER_PATH="$CWD_RESOLVED"

# Already-trusted check runs against the offer path, not the original CWD,
# so a trusted main suppresses the offer for all of its worktrees. Unverified
# parsing is sufficient — this is a UX decision, not a security one.
if [ -f "$TRUST_FILE" ]; then
  while IFS= read -r tp; do
    [ -z "$tp" ] && continue
    tp="${tp/#\~/$HOME}"
    RESOLVED_TP=$(realpath "$tp" 2>/dev/null) || continue
    if [[ "$OFFER_PATH" == "$RESOLVED_TP" || "$OFFER_PATH" == "$RESOLVED_TP"/* ]]; then
      exit 0  # Already trusted (directly or via main repo)
    fi
  done < <(jq -r '.[]' "$TRUST_FILE" 2>/dev/null)
fi

# Not trusted — inject context for Claude to offer trust.
# The context embeds the exact trust command with resolved absolute paths.
# Without this, Claude improvises a multi-step file manipulation (Read, ls,
# mkdir, Write) requiring ~5 approval prompts instead of 2.
TRUST_CMD="$CLAUDE_PLUGIN_ROOT/scripts/cd-git-trust.sh"
jq -n --arg cwd "$OFFER_PATH" --arg trust_file "$TRUST_FILE" --arg trust_cmd "$TRUST_CMD" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("[i-said-yes] This project (" + $cwd + ") is not in the trusted git projects list. Ask the user (via AskUserQuestion, yes/no) if they want to trust this project so future compound commands with cd and git are auto-approved. Only trust projects the user owns — not third-party clones or repos with untrusted submodules. If yes, run: " + $trust_cmd + " \"" + $cwd + "\" \"" + $trust_file + "\"")
  }
}'
exit 0
