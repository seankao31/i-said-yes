#!/bin/bash
# Add a project path to the trusted-projects.json trust list.
# Creates the file and parent directory if they don't exist.
# Skips duplicates silently.
#
# Usage: trust.sh <project-path> <trust-file-path>

PROJECT_PATH="${1:?Usage: trust.sh <project-path> <trust-file-path>}"
TRUST_FILE="${2:?Usage: trust.sh <project-path> <trust-file-path>}"

# Create parent directory if needed
mkdir -p "$(dirname "$TRUST_FILE")"

# Initialize empty array if file doesn't exist
if [ ! -f "$TRUST_FILE" ]; then
  echo '[]' > "$TRUST_FILE"
fi

# Skip if already present
if jq -e --arg p "$PROJECT_PATH" 'map(. == $p) | any' "$TRUST_FILE" > /dev/null 2>&1; then
  exit 0
fi

# Append the path
jq --arg p "$PROJECT_PATH" '. + [$p]' "$TRUST_FILE" > "${TRUST_FILE}.tmp"
mv "${TRUST_FILE}.tmp" "$TRUST_FILE"
