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
