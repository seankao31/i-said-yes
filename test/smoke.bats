#!/usr/bin/env bats

load test_helper

@test "bats and helpers load correctly" {
  assert [ -d "$CLAUDE_PLUGIN_DATA" ]
}

@test "hook_input builds valid JSON" {
  local json
  json=$(hook_input "Bash" "git status" "/tmp")
  assert_equal "$(echo "$json" | jq -r '.tool_name')" "Bash"
  assert_equal "$(echo "$json" | jq -r '.tool_input.command')" "git status"
  assert_equal "$(echo "$json" | jq -r '.cwd')" "/tmp"
}
