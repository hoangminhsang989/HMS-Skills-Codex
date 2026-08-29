---
name: hms-isolated-execution
description: Use when an HMS task will materially modify code, tests, configuration, authority artifacts, or release state and the work should be isolated from protected or owner-dirty baselines.
---

# HMS Isolated Execution

Prefer an isolated Git branch/worktree for material mutations.

## Preflight

Capture:

- repository root;
- current branch and HEAD;
- working-tree status;
- relevant remote tracking state;
- protected/owner-dirty files that must not be disturbed.

If upstream `using-git-worktrees` is installed and applicable, use it unless a higher HMS authority specifies another isolation mechanism.

## Isolation rules

- Never clean, reset, stash, discard, or overwrite owner changes merely to obtain a clean baseline without explicit authority.
- Do not have multiple agents mutate the same file set concurrently.
- Bind the candidate to a branch/commit/tree before independent review when the gate requires committed-byte review.
- Keep integration separate from implementation when authority distinguishes them.

If safe isolation cannot be established, stop rather than mutate the protected baseline.
