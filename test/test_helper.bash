#!/usr/bin/env bash
# Shared setup for all bats tests

# Load bats libraries from node_modules
BATS_LIB="${BATS_TEST_DIRNAME}/../node_modules"
load "${BATS_LIB}/bats-support/load.bash"
load "${BATS_LIB}/bats-assert/load.bash"

# Path to the scripts under test
SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../scripts"

# Create a temporary directory for each test (trust files, git repos, etc.)
setup() {
  TEST_TEMP="$(mktemp -d)"
  export CLAUDE_PLUGIN_DATA="$TEST_TEMP/plugin-data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
}

teardown() {
  rm -rf "$TEST_TEMP"
}

# Helper: create a minimal git repo at the given path
create_git_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init --quiet
  git -C "$path" commit --allow-empty --quiet -m "init"
}

# Helper: build hook input JSON
hook_input() {
  local tool="${1:-Bash}"
  local command="${2:-}"
  local cwd="${3:-$(pwd)}"
  jq -n \
    --arg tool "$tool" \
    --arg cmd "$command" \
    --arg cwd "$cwd" \
    '{tool_name: $tool, tool_input: {command: $cmd}, cwd: $cwd}'
}

# Helper: add a path to the trust list
trust_project() {
  local path="$1"
  local trust_file="$CLAUDE_PLUGIN_DATA/trusted-projects.json"
  if [ -f "$trust_file" ]; then
    jq --arg p "$path" '. + [$p]' "$trust_file" > "${trust_file}.tmp"
    mv "${trust_file}.tmp" "$trust_file"
  else
    jq -n --arg p "$path" '[$p]' > "$trust_file"
  fi
}
