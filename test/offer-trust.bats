#!/usr/bin/env bats

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/offer-trust.sh"

# Helper: pipe input to script via run
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

@test "ignores simple git commands (no cd prefix)" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  local input
  input=$(hook_input "Bash" "git status" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores non-git compound commands" {
  local input
  input=$(hook_input "Bash" "cd /tmp && ls -la" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

# --- Already trusted: no offer ---

@test "does not offer trust for already-trusted project" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local input
  input=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not offer trust when subdirectory is under trusted parent" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local subdir="$repo/src"
  mkdir -p "$subdir"

  local input
  input=$(hook_input "Bash" "cd \"$repo\" && git status" "$subdir")
  run_script "$input"
  assert_success
  assert_output ""
}

# --- Untrusted project: offer trust ---

@test "offers trust for untrusted project" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")

  local event_name
  event_name=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')
  assert_equal "$event_name" "PostToolUse"

  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  assert [ -n "$context" ]
}

@test "offers trust when trust file does not exist" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  rm -f "$CLAUDE_PLUGIN_DATA/trusted-projects.json"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")

  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  assert [ -n "$context" ]
}

# --- Context content ---

@test "context includes plugin label" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")
  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

  [[ "$context" == *"[i-said-yes]"* ]]
}

@test "context includes project path" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  local resolved
  resolved=$(realpath "$repo")

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")
  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

  [[ "$context" == *"$resolved"* ]]
}

@test "context includes trust file path" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")
  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

  [[ "$context" == *"trusted-projects.json"* ]]
}

# --- Trust command in context ---

@test "context includes runnable trust command" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")
  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

  [[ "$context" == *"trust.sh"* ]]
  [[ "$context" == *"run:"* ]]
}

# --- Edge cases ---

@test "handles empty command gracefully" {
  local input
  input=$(hook_input "Bash" "" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "handles missing cwd gracefully" {
  local input='{"tool_name":"Bash","tool_input":{"command":"cd /tmp && git status"}}'
  run_script "$input"
  assert_success
  assert_output ""
}
