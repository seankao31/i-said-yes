#!/usr/bin/env bats

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/noop-cd-strip.sh"

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

@test "ignores empty command" {
  local input
  input=$(hook_input "Bash" "" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores missing cwd" {
  local input='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores bare cd with no &&" {
  local input
  input=$(hook_input "Bash" "cd /tmp" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores cd with semicolon separator" {
  local input
  input=$(hook_input "Bash" "cd /tmp ; echo hello" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "ignores simple commands (no cd prefix)" {
  local input
  input=$(hook_input "Bash" "git status" "/tmp")
  run_script "$input"
  assert_success
  assert_output ""
}

# --- No-op cd detected: rewrite ---

@test "strips cd . && from compound command" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd . && echo hello" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "echo hello"
}

@test "strips cd <absolute-cwd> && from compound command" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd \"$dir\" && git status" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "git status"
}

@test "strips cd with single-quoted cwd path" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd '$dir' && npm install" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "npm install"
}

@test "strips cd with unquoted cwd path" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd $dir && cargo build" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "cargo build"
}

@test "strips cd with tilde path matching cwd" {
  # Use $HOME as cwd since ~ expands to $HOME
  local output
  output=$(hook_input "Bash" "cd ~ && echo hello" "$HOME" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "echo hello"
}

# --- Non-matching cd: no rewrite ---

@test "does not strip cd to different directory" {
  local dir="$TEST_TEMP/here"
  local other="$TEST_TEMP/there"
  mkdir -p "$dir" "$other"

  local input
  input=$(hook_input "Bash" "cd \"$other\" && echo hello" "$dir")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not strip cd to nonexistent path" {
  local dir="$TEST_TEMP/here"
  mkdir -p "$dir"

  local input
  input=$(hook_input "Bash" "cd /no/such/path && echo hello" "$dir")
  run_script "$input"
  assert_success
  assert_output ""
}

@test "does not strip cd to subdirectory of cwd" {
  local dir="$TEST_TEMP/parent"
  mkdir -p "$dir/child"

  local input
  input=$(hook_input "Bash" "cd \"$dir/child\" && echo hello" "$dir")
  run_script "$input"
  assert_success
  assert_output ""
}

# --- Chained compounds ---

@test "strips only leading cd, preserves chained &&" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd \"$dir\" && echo a && echo b" "$dir" | "$SCRIPT")
  local cmd
  cmd=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command')
  assert_equal "$cmd" "echo a && echo b"
}

# --- Output format ---

@test "output includes hookEventName PreToolUse" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd . && echo hello" "$dir" | "$SCRIPT")
  local event
  event=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')
  assert_equal "$event" "PreToolUse"
}

@test "output does not include permissionDecision" {
  local dir="$TEST_TEMP/mydir"
  mkdir -p "$dir"

  local output
  output=$(hook_input "Bash" "cd . && echo hello" "$dir" | "$SCRIPT")
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "absent"')
  assert_equal "$decision" "absent"
}
