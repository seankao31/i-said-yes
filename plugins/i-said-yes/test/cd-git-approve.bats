#!/usr/bin/env bats

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cd-git-approve.sh"

# Helper: pipe input to script via run (for tests asserting empty output)
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
  trust_project "$repo"

  local input
  input=$(hook_input "Bash" "git status" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores non-git compound commands" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local input
  input=$(hook_input "Bash" "cd /tmp && ls -la" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

# --- Gate 1: Trust gate ---

@test "does not auto-approve untrusted project" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  local input
  input=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not auto-approve when trust file is missing" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  rm -f "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"

  local input
  input=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

# --- Gate 2: Pattern gate (cd <path> && git <cmd>) ---

@test "approves cd <path> && git status in trusted project" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "approves cd <path> && git log in trusted project" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git log --oneline" "$repo" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "approves cd with single-quoted path" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local output
  output=$(hook_input "Bash" "cd '$repo' && git status" "$repo" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "approves cd with unquoted path" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local output
  output=$(hook_input "Bash" "cd $repo && git status" "$repo" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

# --- Gate 3: Same-repo gate ---

@test "rejects cd into a different git repo" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local other_repo
  other_repo="$TEST_TEMP/other-project"
  create_git_repo "$other_repo"

  local input
  input=$(hook_input "Bash" "cd \"$other_repo\" && git status" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "approves cd into subdirectory of same repo" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  mkdir -p "$repo/subdir"
  trust_project "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo/subdir\" && git status" "$repo" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "approves cd into worktree of same repo" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  git -C "$repo" branch worktree-branch HEAD 2>/dev/null
  local wt="$TEST_TEMP/worktree"
  git -C "$repo" worktree add "$wt" worktree-branch --quiet

  local output
  output=$(hook_input "Bash" "cd \"$wt\" && git status" "$repo" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "rejects cd into nested repo (submodule-like)" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local nested="$repo/vendor/evil"
  create_git_repo "$nested"

  local input
  input=$(hook_input "Bash" "cd \"$nested\" && git status" "$repo")
  run_script "$input"
  assert_success
  assert_output ""
}

# --- Trust path matching ---

@test "trusts subdirectory when parent is trusted" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local subdir="$repo/src"
  mkdir -p "$subdir"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$subdir" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

# --- Output format ---

@test "output includes correct hookEventName and reason" {
  local repo
  repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  trust_project "$repo"

  local output
  output=$(hook_input "Bash" "cd \"$repo\" && git status" "$repo" | "$SCRIPT")

  local event_name
  event_name=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')
  assert_equal "$event_name" "PreToolUse"

  local reason
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  assert [ -n "$reason" ]
}

# --- Edge cases ---

@test "handles empty command gracefully" {
  local input
  input=$(hook_input "Bash" "" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "handles missing tool_input gracefully" {
  local input='{"tool_name":"Bash","cwd":"/tmp"}'
  run_script "$input"
  assert_success
  assert_output ""
}

# --- Worktree fallback: CWD is a worktree of a trusted main ---

@test "approves when cwd is a worktree of a trusted main repo" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  trust_project "$main"
  local wt="$TEST_TEMP/wt"
  make_worktree "$main" "$wt"

  local output
  output=$(hook_input "Bash" "cd \"$wt\" && git status" "$wt" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "does not approve when cwd is a worktree of an untrusted main" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  local wt="$TEST_TEMP/wt"
  make_worktree "$main" "$wt"

  local input
  input=$(hook_input "Bash" "cd \"$wt\" && git status" "$wt")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "approves when cwd is a worktree of a main trusted via ancestor path" {
  local workspace="$TEST_TEMP/workspace"
  mkdir -p "$workspace"
  local main="$workspace/project"
  create_git_repo "$main"
  trust_project "$workspace"
  local wt="$TEST_TEMP/wt"
  make_worktree "$main" "$wt"

  local output
  output=$(hook_input "Bash" "cd \"$wt\" && git status" "$wt" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "approves cd into sibling worktree when cwd is a trusted worktree" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  trust_project "$main"
  local wt_a="$TEST_TEMP/wt-a"
  local wt_b="$TEST_TEMP/wt-b"
  make_worktree "$main" "$wt_a" branch-a
  make_worktree "$main" "$wt_b" branch-b

  local output
  output=$(hook_input "Bash" "cd \"$wt_b\" && git status" "$wt_a" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  assert_equal "$decision" "allow"
}

@test "rejects cd into an unrelated repo from a trusted worktree" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  trust_project "$main"
  local wt="$TEST_TEMP/wt"
  make_worktree "$main" "$wt"
  local other="$TEST_TEMP/other"
  create_git_repo "$other"

  local input
  input=$(hook_input "Bash" "cd \"$other\" && git status" "$wt")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not approve directory with spoofed .git gitfile (shape check)" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  trust_project "$main"
  # Evil dir's gitfile points outside any worktrees/ directory
  local evil="$TEST_TEMP/evil"
  mkdir -p "$evil"
  printf 'gitdir: %s/.git\n' "$main" > "$evil/.git"

  local input
  input=$(hook_input "Bash" "cd \"$evil\" && git status" "$evil")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not approve directory whose gitfile fakes a worktrees/ path but isn't registered" {
  local main="$TEST_TEMP/project"
  create_git_repo "$main"
  trust_project "$main"
  # Evil dir's gitfile points to a fake worktrees/ subdir of the trusted main.
  # Shape check passes (parent is literally "worktrees"), resolution derives
  # $main as the main repo path, trust check passes — only bidirectional
  # verification against the real worktree list stops this.
  mkdir -p "$main/.git/worktrees/fake-w"
  local evil="$TEST_TEMP/evil"
  mkdir -p "$evil"
  printf 'gitdir: %s/.git/worktrees/fake-w\n' "$main" > "$evil/.git"

  local input
  input=$(hook_input "Bash" "cd \"$evil\" && git status" "$evil")
  run_script "$input"
  assert_success
  assert_output ""
}
