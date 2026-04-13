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
