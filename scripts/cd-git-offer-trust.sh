#!/bin/bash
# PostToolUse hook: after a cd+git command completes in an untrusted project,
# inject context so Claude offers to trust the project.
#
# Fires right when Claude is composing its response, so the context is fresh.
# States facts (not instructions) to avoid prompt injection detection.

TRUST_FILE="$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" != "Bash" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$COMMAND" ] || [ -z "$CWD" ] && exit 0

# Only care about cd <path> && git <cmd> patterns
[[ "$COMMAND" =~ ^cd[[:space:]].*\&\&[[:space:]]*git[[:space:]] ]] || exit 0

# Check if already trusted
CWD_RESOLVED=$(realpath "$CWD" 2>/dev/null) || exit 0

if [ -f "$TRUST_FILE" ]; then
  while IFS= read -r tp; do
    [ -z "$tp" ] && continue
    tp="${tp/#\~/$HOME}"
    RESOLVED_TP=$(realpath "$tp" 2>/dev/null) || continue
    if [[ "$CWD_RESOLVED" == "$RESOLVED_TP" || "$CWD_RESOLVED" == "$RESOLVED_TP"/* ]]; then
      exit 0  # Already trusted
    fi
  done < <(jq -r '.[]' "$TRUST_FILE" 2>/dev/null)
fi

# Not trusted — inject context for Claude to offer trust
TRUST_CMD="$CLAUDE_PLUGIN_ROOT/scripts/cd-git-trust.sh"
jq -n --arg cwd "$CWD_RESOLVED" --arg trust_file "$TRUST_FILE" --arg trust_cmd "$TRUST_CMD" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("[i-said-yes] This project (" + $cwd + ") is not in the trusted git projects list. Ask the user (via AskUserQuestion, yes/no) if they want to trust this project so future compound commands with cd and git are auto-approved. Only trust projects the user owns — not third-party clones or repos with untrusted submodules. If yes, run: " + $trust_cmd + " \"" + $cwd + "\" \"" + $trust_file + "\"")
  }
}'
exit 0
