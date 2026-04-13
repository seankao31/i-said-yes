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
