#!/usr/bin/env bats

load test_helper

LIB="$BATS_TEST_DIRNAME/../scripts/cd-git-worktree.sh"

setup_file() {
  :
}

# Source the library in each test via a fresh subshell so function state does
# not leak between cases.
resolve() {
  bash -c 'set -euo pipefail; source "$1"; cd_git_resolve_main_repo "$2"' _ "$LIB" "$1"
}

verify() {
  bash -c 'set -euo pipefail; source "$1"; cd_git_verify_worktree "$2" "$3"' _ "$LIB" "$1" "$2"
}

# --- cd_git_resolve_main_repo ---

@test "resolve: main repo (.git is a directory) returns itself" {
  local repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  run resolve "$repo"
  assert_success
  assert_output "$(realpath "$repo")"
}

@test "resolve: legitimate worktree returns the main repo path" {
  local repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  local wt="$TEST_TEMP/wt"
  make_worktree "$repo" "$wt"

  run resolve "$wt"
  assert_success
  assert_output "$(realpath "$repo")"
}

@test "resolve: plain directory with no .git exits non-zero and empty" {
  local plain="$TEST_TEMP/plain"
  mkdir -p "$plain"

  run resolve "$plain"
  assert_failure
  assert_output ""
}

@test "resolve: malformed .git gitfile (no gitdir prefix) exits non-zero" {
  local evil="$TEST_TEMP/evil"
  mkdir -p "$evil"
  printf 'banana: /tmp/whatever\n' > "$evil/.git"

  run resolve "$evil"
  assert_failure
  assert_output ""
}

@test "resolve: .git gitfile with empty gitdir value exits non-zero" {
  local evil="$TEST_TEMP/evil"
  mkdir -p "$evil"
  printf 'gitdir: \n' > "$evil/.git"

  run resolve "$evil"
  assert_failure
  assert_output ""
}

@test "resolve: .git gitfile pointing outside a worktrees/ directory is rejected" {
  local evil="$TEST_TEMP/evil"
  mkdir -p "$evil"
  # Point to a plausible-looking but wrong-shaped path
  local fake_gitdir="$TEST_TEMP/fake-repo/.git"
  mkdir -p "$fake_gitdir"
  printf 'gitdir: %s\n' "$fake_gitdir" > "$evil/.git"

  run resolve "$evil"
  assert_failure
  assert_output ""
}

@test "resolve: .git gitfile pointing to a path whose parent is 'worktrees' but grandparent is not a repo returns derived path" {
  # If the gitfile points to .../something/worktrees/w1, the function happily
  # derives .../something. This is the documented shape check behavior — it
  # does not verify that the derived path is a real repo, only that the
  # gitdir path has the expected shape. Verification is cd_git_verify_worktree's
  # job.
  local evil="$TEST_TEMP/evil"
  mkdir -p "$evil"
  local fake_wt_root="$TEST_TEMP/fake/worktrees/w1"
  mkdir -p "$fake_wt_root"
  printf 'gitdir: %s\n' "$fake_wt_root" > "$evil/.git"

  run resolve "$evil"
  assert_success
  assert_output "$(realpath "$TEST_TEMP/fake")"
}

@test "resolve: .git gitfile with a relative gitdir is interpreted relative to the gitfile's directory" {
  # Mirrors the on-disk shape git writes when worktree.useRelativePaths=true
  # (git 2.48+). The hook's CWD is deliberately irrelevant — the relative
  # gitdir must be resolved against the directory holding the .git file.
  local main="$TEST_TEMP/main"
  create_git_repo "$main"
  mkdir -p "$main/.git/worktrees/w1"
  local wt="$TEST_TEMP/wt"
  mkdir -p "$wt"
  printf 'gitdir: ../main/.git/worktrees/w1\n' > "$wt/.git"

  # Invoke with the shell's CWD set to a directory where the relative path
  # would NOT resolve correctly, to prove the function does not rely on it.
  run bash -c '
    set -euo pipefail
    source "$1"
    cd "$2"
    cd_git_resolve_main_repo "$3"
  ' _ "$LIB" "$TEST_TEMP" "$wt"

  assert_success
  assert_output "$(realpath "$main")"
}

@test "resolve: bare main repo with a worktree returns the bare repo path" {
  local bare="$TEST_TEMP/project.git"
  git init --bare --quiet "$bare"
  # Bare repos have no initial commit; stage one by adding a ref via a temp clone
  local seed="$TEST_TEMP/seed"
  git clone --quiet "$bare" "$seed"
  git -C "$seed" commit --allow-empty --quiet -m "init"
  git -C "$seed" push --quiet origin HEAD:refs/heads/main
  rm -rf "$seed"

  local wt="$TEST_TEMP/wt"
  git -C "$bare" worktree add --quiet "$wt" main

  run resolve "$wt"
  assert_success
  assert_output "$(realpath "$bare")"
}

# --- cd_git_verify_worktree ---

@test "verify: legitimate worktree of its main repo succeeds" {
  local repo="$TEST_TEMP/project"
  create_git_repo "$repo"
  local wt="$TEST_TEMP/wt"
  make_worktree "$repo" "$wt"

  run verify "$wt" "$repo"
  assert_success
}

@test "verify: main repo itself passed as the worktree of itself succeeds" {
  local repo="$TEST_TEMP/project"
  create_git_repo "$repo"

  run verify "$repo" "$repo"
  assert_success
}

@test "verify: worktree of one main verified against a different main fails" {
  local repo_a="$TEST_TEMP/a"
  create_git_repo "$repo_a"
  local repo_b="$TEST_TEMP/b"
  create_git_repo "$repo_b"
  local wt_a="$TEST_TEMP/wt-a"
  make_worktree "$repo_a" "$wt_a"

  run verify "$wt_a" "$repo_b"
  assert_failure
}

@test "verify: spoofed commondir attacker dir does not pass verification" {
  local repo="$TEST_TEMP/trusted"
  create_git_repo "$repo"
  local evil="$TEST_TEMP/evil"
  make_spoofed_commondir "$evil" "$repo/.git"

  run verify "$evil" "$repo"
  assert_failure
}

@test "verify: GIT_DIR/GIT_COMMON_DIR in env do not mislead verification" {
  local repo_a="$TEST_TEMP/a"
  create_git_repo "$repo_a"
  local repo_b="$TEST_TEMP/b"
  create_git_repo "$repo_b"
  local wt_a="$TEST_TEMP/wt-a"
  make_worktree "$repo_a" "$wt_a"

  # Point upstream env at repo_b while asking about wt_a vs repo_a.
  # Sanitization in the function should ignore these and still answer
  # correctly.
  run env GIT_DIR="$repo_b/.git" GIT_COMMON_DIR="$repo_b/.git" GIT_WORK_TREE="$repo_b" \
    bash -c 'set -euo pipefail; source "$1"; cd_git_verify_worktree "$2" "$3"' _ "$LIB" "$wt_a" "$repo_a"
  assert_success
}

@test "verify: missing main repo (realpath fails) returns non-zero" {
  local wt="$TEST_TEMP/wt-phantom"
  mkdir -p "$wt"

  run verify "$wt" "$TEST_TEMP/does-not-exist"
  assert_failure
}
