#!/usr/bin/env bats

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cd-git-offer-trust.sh"

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
  rm -f "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"

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

  [[ "$context" == *"cd-git-trusted-projects.json"* ]]
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

# --- Worktree awareness ---

@test "worktree of untrusted main: offer contains main repo path, not worktree path" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  local wt="$TEST_TEMP/wt"
  make_worktree "$main" "$wt"

  local output
  output=$(hook_input "Bash" "cd \"$wt\" && git status" "$wt" | "$SCRIPT")
  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

  local main_real wt_real
  main_real=$(realpath "$main")
  wt_real=$(realpath "$wt")

  [[ "$context" == *"$main_real"* ]]
  [[ "$context" != *"$wt_real"* ]]
}

@test "worktree of already-trusted main: silent exit" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  trust_project "$main"
  local wt="$TEST_TEMP/wt"
  make_worktree "$main" "$wt"

  local input
  input=$(hook_input "Bash" "cd \"$wt\" && git status" "$wt")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "worktree of main under a trusted ancestor: silent exit" {
  local workspace="$TEST_TEMP/workspace"
  mkdir -p "$workspace"
  trust_project "$workspace"
  local main="$workspace/project"
  create_git_repo "$main"
  local wt="$TEST_TEMP/wt"
  make_worktree "$main" "$wt"

  local input
  input=$(hook_input "Bash" "cd \"$wt\" && git status" "$wt")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "stale gitfile claiming a trusted main does not silently suppress the offer" {
  # If a directory's .git gitfile claims to belong to a trusted main but the
  # claim does not round-trip through the main's git worktree list, the
  # PreToolUse hook will continue to reject auto-approval. Silently
  # suppressing the PostToolUse offer in that case strands the user with no
  # way to either get auto-approval or be offered a recoverable trust
  # decision — so the hook must still emit an offer, falling back to CWD.
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  trust_project "$main"
  mkdir -p "$main/.git/worktrees/fake-w"
  local evil="$TEST_TEMP/evil"
  mkdir -p "$evil"
  printf 'gitdir: %s/.git/worktrees/fake-w\n' "$main" > "$evil/.git"

  local output
  output=$(hook_input "Bash" "cd \"$evil\" && git status" "$evil" | "$SCRIPT")
  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  assert [ -n "$context" ]

  local evil_real
  evil_real=$(realpath "$evil")
  [[ "$context" == *"$evil_real"* ]]
}

@test "untrusted main repo: offer still contains the main repo path (regression)" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"

  local output
  output=$(hook_input "Bash" "cd \"$main\" && git status" "$main" | "$SCRIPT")
  local context
  context=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')

  local main_real
  main_real=$(realpath "$main")
  [[ "$context" == *"$main_real"* ]]
}
