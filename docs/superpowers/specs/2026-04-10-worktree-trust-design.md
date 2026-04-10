# Worktree-aware trust gate

Design for extending the i-said-yes plugin to recognize git worktrees of trusted main repositories, so `cd <path> && git <cmd>` auto-approves correctly when Claude Code is operating from inside a worktree.

## Background

The plugin's trust gate is path-based: a project is trusted if its absolute path (or an ancestor of that path) appears in `${CLAUDE_PLUGIN_DATA}/cd-git-trusted-projects.json`. This works for normal main repositories but fails for git worktrees, which live at unrelated filesystem paths.

Example failing scenario: a user has trusted `/Users/sean/project-a`. Claude Code creates a worktree at `/private/tmp/cc-worktree-abc` and operates from there. When Claude runs `cd . && git status`, the PreToolUse hook resolves CWD to `/private/tmp/cc-worktree-abc`, finds no match in the trust list, and defers to the normal permission prompt. The PostToolUse hook then offers to trust the ephemeral worktree path, which becomes a dead entry in the trust file once the worktree is cleaned up.

## Goals

1. Auto-approve `cd <path> && git <cmd>` when CWD is a verified worktree of a trusted main repository.
2. Make the offer-trust hook suggest the main repository path (not the worktree path) when CWD is a worktree.
3. Suppress redundant offer-trust prompts when CWD is a worktree of an already-trusted main.
4. Add no new false-positive auto-approvals: a directory must be a *real* worktree of a trusted main, not a directory that merely *claims* to be one.

## Non-goals

This design intentionally does not address the following pre-existing issues. They are accepted under the plugin's threat model (Claude itself generates commands in a trusted user environment; the attacker is not actively probing the trust gate). They are documented as known limitations in `docs/decisions.md`.

1. `git rev-parse --git-common-dir` honors `.git/commondir` blindly, making the same-repo gate spoofable.
2. The pattern gate's cd-path alternatives admit `$(...)` and backtick command substitution.
3. The pattern gate is prefix-only — anything after `git <cmd>` is unchecked.
4. All git subcommands are auto-approved equally, including `push`, `config`, `reset --hard`.
5. The hook's non-worktree git invocations honor `GIT_DIR` / `GIT_COMMON_DIR` / `GIT_WORK_TREE` environment variables.

## Threat model

Claude Code generates the commands the plugin sees. The trust gate's job is to reduce permission-prompt fatigue for commands Claude legitimately needs to run in trusted personal projects. The attacker we worry about is Claude generating something inadvertently destructive — not a malicious local directory actively trying to bypass the gate.

The one exception, which this design *does* defend against: a directory that is not a worktree must not be able to trick the trust gate into accepting it as one. This is the line between "worktree support" and "we accept any directory that says please."

## Architecture

The plugin currently has two scripts touching trust logic:

- `cd-git-approve.sh` (PreToolUse) — makes auto-approval decisions
- `cd-git-offer-trust.sh` (PostToolUse) — emits a context message suggesting which path to trust

Both need to understand worktrees. Shared logic lives in a new file:

- **New:** `scripts/cd-git-worktree.sh` — sourced (not executed) by both hooks. Provides two bash functions:
  - `cd_git_resolve_main_repo <dir>` — given a directory, prints the main repo path it belongs to (as a worktree), or empty if it's not a worktree. Pure file I/O, no subprocess.
  - `cd_git_verify_worktree <dir> <main_repo>` — returns 0 if `<dir>` is a legitimately listed worktree of `<main_repo>` according to `git worktree list --porcelain` run from the main repo with sanitized environment. Used only by the approve hook.

- **Modified:** `cd-git-approve.sh` — trust gate gains a fallback branch after the path check.
- **Modified:** `cd-git-offer-trust.sh` — uses `cd_git_resolve_main_repo` to derive a main repo path for the offer.
- **Unchanged:** `cd-git-trust.sh`, `hooks.json`, the same-repo gate logic in `cd-git-approve.sh`, the pattern gate regex.

The same-repo gate is intentionally not modified. With the existing `git rev-parse --git-common-dir` comparison, it already correctly handles all four worktree scenarios under the relaxed threat model:

| CWD | cd target | git-common-dir match | Result |
|---|---|---|---|
| worktree of trusted M | subdir of same worktree | yes | approve |
| worktree of M | M itself | yes | approve |
| worktree of M | sibling worktree of M | yes | approve |
| worktree of M | unrelated repo | no | reject |

The fix is purely in the trust gate.

## `cd_git_resolve_main_repo`

No git subprocess, no verification. Only `realpath` and shell file tests. Used by both hooks.

**Input:** a directory path.
**Output:** main repo path on stdout, or empty (and exit non-zero).

**Steps:**

1. Look at `<dir>/.git`.
   - If it is a **directory**, `<dir>` is itself a main repo. Print `<dir>`, exit 0.
   - If it is a **file**, it is a worktree gitfile. Continue.
   - Otherwise, exit non-zero.

2. Read the gitfile, first line only. Require the literal prefix `gitdir: ` (8 chars including the space). Extract everything after the prefix up to the first newline. Reject empty content.

3. Canonicalize the extracted path: `gitdir_real = realpath <gitdir>`. Reject on failure.

4. **Shape check:** require `basename $(dirname "$gitdir_real") == "worktrees"`. The gitdir path must look like `.../worktrees/<name>`. Reject anything else. This step is the critical safeguard against a gitfile that claims `gitdir: /any/path/the/attacker/wants` — without it, the function would hand back arbitrary paths.

5. Derive the main git directory: `main_git = realpath "$gitdir_real/../.."`.

6. Derive the main repo path:
   - If `main_git` ends in `/.git` → main repo is `realpath "$main_git/.."`
   - Otherwise → main repo is `main_git` itself (bare repo case)

7. Print the main repo path, exit 0.

**Why the function returns the main repo for both worktrees and main repos:** the offer-trust hook needs to ask "what main repo does this CWD belong to" for both shapes. Returning `<dir>` itself when CWD is already a main repo gives both callers a single function to call regardless of CWD shape.

**Out of scope:** CWD being itself a bare repository (`<dir>` is `something.git/` with no inner `.git`). Step 1 falls through to non-zero in that case. The existing path-based trust check still handles bare repos that are explicitly listed in the trust file; only the worktree fallback branch ignores them. Operating Claude from inside a bare repo directly is exotic and not worth complicating the function for.

## `cd_git_verify_worktree`

Bidirectional verification. Used only by the approve hook, only after `cd_git_resolve_main_repo` has produced a candidate main repo path that is itself trusted.

**Input:** a directory path and a main repo path. Both should already be canonicalized, but the function canonicalizes them again as a safety measure.
**Output:** exit 0 if verified, non-zero otherwise.

**Steps:**

1. Canonicalize `dir_real = realpath <dir>` and `main_real = realpath <main_repo>`. Exit non-zero on failure.

2. Run `git worktree list` on the trusted side with sanitized environment:
   ```bash
   env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE \
       -u GIT_CEILING_DIRECTORIES -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
       git -C "$main_real" worktree list --porcelain -z
   ```

   The `-z` flag gives null-separated records, robust against pathological paths. `git -C` avoids a subshell `cd`. Sanitizing the environment ensures the listing reflects the actual on-disk state of the trusted repo even if the hook process inherited a poisoned env from upstream.

3. Parse porcelain output. Each record is a block of lines: `worktree <path>`, `HEAD <sha>`, `branch <ref>` or `bare`/`detached`, optional `locked`/`prunable`. Extract every `worktree <path>` value. Canonicalize each via `realpath`.

4. If any canonicalized path equals `dir_real`, exit 0. Otherwise exit non-zero.

**What this does not do:**
- It does not try to make `git rev-parse --git-common-dir` trustworthy.
- It does not verify the worktree's internal structure beyond what `git worktree list` already validates.
- It does not check that the cd target is a worktree.

It answers exactly one question: "does the trusted main repo acknowledge `<dir>` as one of its worktrees?" That is sufficient because the answer is combined with the path-based trust check on the main repo itself. The trusted main is filesystem-write-protected from the attacker's perspective; a directory the attacker created cannot have planted entries in the trusted main's `.git/worktrees/`.

**Edge cases:**
- **`dir_real` is the main repo itself.** `git worktree list` reports the main repo as the first entry, so this case naturally succeeds.
- **Bare main repo.** Porcelain output reports the bare dir as a `worktree <bare-dir>` entry with a `bare` line instead of `HEAD`/`branch`. The parse logic only cares about the `worktree` line, so it works uniformly.
- **Prunable worktrees.** Accepted. A `prunable` annotation indicates git suspects the gitdir target is stale, but the worktree was once legitimately registered. Rejecting them serves no purpose under the threat model.
- **`git worktree list` fails** (corrupted metadata, missing git binary, etc.). Treated as "not verified." The trust gate falls through to the normal permission prompt.

## Approve hook trust gate flow

The path-check logic in `cd-git-approve.sh` is unchanged. Only the fallback branch is new.

```
Pattern gate: extract TARGET from command          (unchanged)
CWD_RESOLVED = realpath CWD

─── Trust gate ───

# Branch 1: path check (existing, unchanged)
for each tp in trust file:
    tp = tilde-expand tp
    tp_real = realpath tp
    if CWD_RESOLVED == tp_real OR CWD_RESOLVED is under tp_real:
        TRUSTED=true
        break

# Branch 2: worktree fallback (new)
if not TRUSTED:
    main_repo = cd_git_resolve_main_repo "$CWD_RESOLVED"
    if main_repo is non-empty:
        main_real = realpath "$main_repo"
        for each tp in trust file:
            tp = tilde-expand tp
            tp_real = realpath tp
            if main_real == tp_real OR main_real is under tp_real:
                if cd_git_verify_worktree "$CWD_RESOLVED" "$main_real"; then
                    TRUSTED=true
                fi
                break

if not TRUSTED: exit 0    # defer to normal prompt

─── Same-repo gate (existing, unchanged) ───
```

**Key properties:**

- **Path check runs first, subprocess-free.** The common case (Claude operating in a regularly-trusted main repo) stays as fast as today. No new cost unless the path check fails.
- **Worktree fallback short-circuits early.** If `cd_git_resolve_main_repo` returns empty, we skip the rest. No wasted git calls.
- **The inner loop checks main-repo-is-trusted using the same path logic** — equality or subdir-of-trusted-ancestor. So ancestor trust still works: if `/Users/sean/Workplace/` is trusted, a worktree of any repo under there auto-approves.
- **`cd_git_verify_worktree` runs last** — it's the most expensive step (one `git worktree list` subprocess), and only runs for a CWD we've already determined is a worktree whose claimed main is trusted.

The same-repo gate runs unchanged after either trust branch. Under the relaxed threat model, this is correct.

## Offer-trust hook flow

`cd-git-offer-trust.sh` is simpler than the approve side because it is not making a security decision — it just emits context suggesting the user trust a path.

```
Pattern match: cd <path> && git <cmd>              (unchanged)
CWD_RESOLVED = realpath CWD

# Resolve CWD to a main repo (NEW)
main_repo = cd_git_resolve_main_repo "$CWD_RESOLVED"
offer_path = main_repo if non-empty, else CWD_RESOLVED

# Already-trusted check (EXTENDED — checks offer_path, not CWD)
for each tp in trust file:
    tp = tilde-expand tp
    tp_real = realpath tp
    if offer_path == tp_real OR offer_path is under tp_real:
        exit 0    # already trusted (directly or via main repo)

# Emit offer (UNCHANGED shape, new path)
emit additionalContext with offer_path substituted
```

**What this fixes:**

1. Ephemeral worktree paths no longer get dumped into the trust file. If CWD is `/private/tmp/cc-worktree-abc`, we resolve to the real main repo path (e.g., `/Users/sean/project-a`) and offer that.
2. No duplicate offers when the main repo is already trusted. The hook exits silently instead of repeatedly asking about the worktree path.
3. Main repos operating normally still work unchanged. `cd_git_resolve_main_repo` returns CWD itself when `.git` is a directory, so existing behavior is preserved.

**What does not change:**
- The `additionalContext` message format. Same `[i-said-yes] This project (…) is not trusted…` wording.
- The embedded trust command Claude runs to add to the list.
- Early exits for non-Bash tools, non-matching patterns, empty CWD.

The offer-trust hook deliberately does not call `cd_git_verify_worktree`. It is a UX suggestion, not a security decision; the user is the final arbiter. Unverified gitfile parsing is sufficient to derive a useful offer.

## Testing strategy

Tests use bats with real git operations against fixture repos. No mocks of git itself.

### New test file: `test/cd-git-worktree.bats`

Unit tests for the shared library functions.

For `cd_git_resolve_main_repo`:
- Main repo (`.git` is a directory) → returns the main repo path itself
- Legitimate worktree created by `git worktree add` → returns the main repo path
- Plain directory, no `.git` → empty, exits non-zero
- `.git` file with malformed content (no `gitdir:` prefix) → empty, exits non-zero
- `.git` file with `gitdir:` pointing outside a `worktrees/` directory → empty (shape check rejects)
- Bare main repo with a worktree → returns the bare repo path

For `cd_git_verify_worktree`:
- Legit worktree + its correct main → exits 0
- Legit worktree + a different main repo → exits non-zero
- Main repo itself passed as the "worktree" with itself as main → exits 0
- Attacker directory with spoofed `commondir` file passed as worktree of its claimed main → exits non-zero (because `git worktree list` from the real main does not list it)
- `git worktree list` fails → exits non-zero
- Env vars `GIT_DIR` / `GIT_COMMON_DIR` set in hook's env → still returns the correct answer (proves env sanitization works)

### Extended: `test/cd-git-approve.bats`

New cases added to the existing file:
- CWD is a worktree of a trusted main → approves
- CWD is a worktree of an untrusted main → does not approve
- CWD is a worktree of a main repo trusted via ancestor path → approves
- cd target is a sibling worktree of the same trusted main → approves
- cd target is a completely different repo, CWD is a trusted worktree → rejects
- Spoofed `.git` gitfile (shape check rejects) → does not approve
- Path-trusted case is unaffected by the new code path (regression coverage)

### Extended: `test/cd-git-offer-trust.bats`

New cases:
- CWD is a worktree of an untrusted main → offer includes the main repo path, not the worktree path
- CWD is a worktree of an already-trusted main → emits nothing (silent exit)
- CWD is an untrusted main repo → offer includes CWD (unchanged behavior)
- CWD is an untrusted worktree of an untrusted main that is under a trusted ancestor → emits nothing

### Test helper additions

Two helpers in `test_helper.bash`:
- `make_worktree <main_repo> <worktree_path>` — wraps `git worktree add`.
- `make_spoofed_commondir <evil_repo> <target_common_dir>` — writes a `commondir` file to reproduce the attacker scenario.

### Out of scope for tests

- End-to-end runs against a live Claude Code instance. Covered manually via `claude --plugin-dir`.
- Mocking git. Real git is fast enough.

## Documentation updates

Three files updated atomically with the code change.

### `docs/spec.md`

In the "Security model: three gates" section, extend the trust gate description:

> **Trust gate** — Is the project in the trust list? Trust is stored in user-scoped plugin data, outside any project's reach. A malicious repo cannot grant itself trust. The trust check accepts both direct path matches and verified worktrees of trusted main repos (see "Worktree support" below).

Add a new section after the gate descriptions:

> ### Worktree support
>
> When CWD is a git worktree, the trust gate falls back to:
> 1. Parsing CWD's `.git` gitfile to derive the claimed main repo path
> 2. Checking that main repo is in the trust list
> 3. Running `git worktree list --porcelain` from the trusted main (with sanitized env) and confirming CWD is listed
>
> All three must succeed. The check is bidirectional: the suspect dir claims a main, and the trusted main must independently confirm it.

### `docs/decisions.md`

New entries under Architecture decisions:

- **Why bidirectional verification:** the naive `git rev-parse --git-common-dir` fallback is spoofable via a planted `.git/commondir` file and approves any repo claiming a common dir, not just real worktrees. Bidirectional verification matches the user's mental model ("trust this repo and its worktrees") and asks the trusted side to confirm.
- **Why the offer-trust hook offers the main repo path:** ephemeral worktree paths in the trust list become dead entries; main repo paths are stable and cover all current and future worktrees.
- **Why the offer-trust hook does not bidirectionally verify:** it is a UX suggestion, not a security decision; the user is the final arbiter. Unverified gitfile parsing is enough to derive a useful suggestion.
- **Why env sanitization on the worktree-list call:** `GIT_DIR` / `GIT_COMMON_DIR` / `GIT_WORK_TREE` can redirect git's discovery. If inherited from upstream, they would defeat the bidirectional check.
- **Why worktree check after path check:** path check is subprocess-free; the common case stays fast.

New section under Discoveries titled "Known limitations":

> The plugin's threat model assumes Claude itself is generating commands in a trusted user environment, not a malicious third party actively probing the trust gate. The following are known weaknesses against an active attacker; they are accepted because fixing them would not measurably help against the assumed threat.
>
> 1. `git rev-parse --git-common-dir` honors `.git/commondir` blindly. A directory with a crafted `commondir` file can claim any common dir for the same-repo gate. Affects the same-repo gate only; the trust gate is unaffected because it uses bidirectional verification.
> 2. Pattern gate cd-path admits command substitution. Double-quoted and unquoted cd target alternatives allow `$(...)` and backtick expansion.
> 3. Pattern gate is prefix-only. Anything after `git <cmd>` is unchecked — `cd /trusted && git status && <anything>` passes.
> 4. No git subcommand allowlisting. `git push`, `git config`, `git reset --hard` are auto-approved equally with `git status`.
> 5. The hook's non-worktree git invocations honor `GIT_*` environment variables. Only the worktree-list call sanitizes them.

### `README.md`

A short subsection under "How it works" or similar, explaining that trusting a project also covers its worktrees, and that you only need to trust the main repo path. No technical depth — the depth lives in `spec.md`.

## File manifest

| Path | Change |
|---|---|
| `scripts/cd-git-worktree.sh` | New — sourced library with `cd_git_resolve_main_repo` and `cd_git_verify_worktree` |
| `scripts/cd-git-approve.sh` | Modified — trust gate gains worktree fallback branch, sources `cd-git-worktree.sh` |
| `scripts/cd-git-offer-trust.sh` | Modified — uses `cd_git_resolve_main_repo` for offer path, sources `cd-git-worktree.sh` |
| `test/cd-git-worktree.bats` | New — unit tests for the shared library |
| `test/cd-git-approve.bats` | Extended — new worktree cases |
| `test/cd-git-offer-trust.bats` | Extended — new worktree cases |
| `test/test_helper.bash` | Extended — `make_worktree`, `make_spoofed_commondir` helpers |
| `docs/spec.md` | Extended — trust gate description and new "Worktree support" section |
| `docs/decisions.md` | Extended — new decision entries and "Known limitations" section |
| `README.md` | Extended — short worktree subsection |
