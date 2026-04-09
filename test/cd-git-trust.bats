#!/usr/bin/env bats

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cd-git-trust.sh"

@test "creates trust file and adds path when file does not exist" {
  rm -f "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"

  run "$SCRIPT" "/tmp/my-project" "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"
  assert_success

  local paths
  paths=$(jq -r '.[]' "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json")
  assert_equal "$paths" "/tmp/my-project"
}

@test "appends path to existing trust file" {
  trust_project "/tmp/existing-project"

  run "$SCRIPT" "/tmp/new-project" "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"
  assert_success

  local count
  count=$(jq 'length' "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json")
  assert_equal "$count" "2"

  local last
  last=$(jq -r '.[-1]' "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json")
  assert_equal "$last" "/tmp/new-project"
}

@test "does not duplicate an already-trusted path" {
  trust_project "/tmp/my-project"

  run "$SCRIPT" "/tmp/my-project" "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json"
  assert_success

  local count
  count=$(jq 'length' "$CLAUDE_PLUGIN_DATA/cd-git-trusted-projects.json")
  assert_equal "$count" "1"
}

@test "creates parent directory if needed" {
  local nested="$TEST_TEMP/deep/nested/dir"

  run "$SCRIPT" "/tmp/my-project" "$nested/cd-git-trusted-projects.json"
  assert_success
  assert [ -f "$nested/cd-git-trusted-projects.json" ]
}

@test "fails with usage message when path argument is missing" {
  run "$SCRIPT"
  assert_failure
}

@test "fails with usage message when trust file argument is missing" {
  run "$SCRIPT" "/tmp/my-project"
  assert_failure
}
