#!/bin/bash
# Shared worktree helpers for the cd+git trust gate. Sourced (not executed)
# by cd-git-approve.sh and cd-git-offer-trust.sh.
#
# Provides:
#   cd_git_resolve_main_repo <dir>
#     Prints the main repo path that <dir> belongs to (as a worktree), or
#     the directory itself if it is already a main repo. Empty output + non-
#     zero exit on anything else. Pure file I/O — no git subprocess.
#
#   cd_git_verify_worktree <dir> <main_repo>
#     Exits 0 iff <main_repo>'s own git worktree list (run with sanitized
#     environment) confirms <dir> as one of its worktrees. Used by the
#     approve hook after cd_git_resolve_main_repo has produced a candidate
#     main that is itself trusted. Answers the one question a path-based
#     trust gate cannot: does the trusted main acknowledge this worktree?

cd_git_resolve_main_repo() {
  local dir="$1"
  [ -z "$dir" ] && return 1

  local git_entry="$dir/.git"

  # Main repo: .git is a directory. Return the canonicalized dir itself so
  # both callers can use a single function regardless of CWD shape.
  if [ -d "$git_entry" ]; then
    realpath "$dir" 2>/dev/null || return 1
    return 0
  fi

  # Otherwise it must be a worktree gitfile.
  [ -f "$git_entry" ] || return 1

  # Parse the gitfile: first line must start with the literal "gitdir: "
  # prefix. Anything else is malformed (or deliberately crafted) and rejected.
  local first_line gitdir
  IFS= read -r first_line < "$git_entry" || return 1
  case "$first_line" in
    "gitdir: "*) gitdir="${first_line#gitdir: }" ;;
    *) return 1 ;;
  esac

  [ -z "$gitdir" ] && return 1

  local gitdir_real
  gitdir_real=$(realpath "$gitdir" 2>/dev/null) || return 1

  # Shape check: the gitdir must look like .../worktrees/<name>. Without this
  # gate, a gitfile claiming "gitdir: /any/path" would hand back that path as
  # a supposed "main repo" — the opposite of the function's intent.
  local parent_name
  parent_name=$(basename "$(dirname "$gitdir_real")")
  [ "$parent_name" = "worktrees" ] || return 1

  # Derive the main git directory: two levels up from the gitdir.
  local main_git
  main_git=$(realpath "$gitdir_real/../.." 2>/dev/null) || return 1

  # Non-bare main repos have main_git ending in /.git; bare repos don't.
  if [[ "$main_git" == */.git ]]; then
    realpath "$main_git/.." 2>/dev/null || return 1
  else
    printf '%s\n' "$main_git"
  fi
}

cd_git_verify_worktree() {
  local dir="$1" main_repo="$2"
  local dir_real main_real
  dir_real=$(realpath "$dir" 2>/dev/null) || return 1
  main_real=$(realpath "$main_repo" 2>/dev/null) || return 1

  # Sanitize git-controlling env vars so the listing reflects the actual
  # on-disk state of the trusted main, not whatever the hook's parent pointed
  # at. -z terminates each attribute with NUL so paths with embedded newlines
  # round-trip correctly.
  local field wt_path wt_real
  while IFS= read -r -d '' field; do
    case "$field" in
      "worktree "*)
        wt_path="${field#worktree }"
        wt_real=$(realpath "$wt_path" 2>/dev/null) || continue
        if [ "$wt_real" = "$dir_real" ]; then
          return 0
        fi
        ;;
    esac
  done < <(env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE \
                -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
                git -C "$main_real" worktree list --porcelain -z 2>/dev/null)

  return 1
}
