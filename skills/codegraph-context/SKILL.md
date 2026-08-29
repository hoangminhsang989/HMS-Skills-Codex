---
name: codegraph-context
description: Use when an HMS workflow or Three-Level Delivery requires CodeGraph to synchronize the exact checkout and provide focused structural repository context before implementation or review.
---

# CodeGraph Context

Use this HMS compatibility skill to turn the pinned CodeGraph installation into bounded repository-intelligence evidence. CodeGraph is derived context, not source-of-truth authority.

## Authority boundary

Owner instruction, the latest valid HMS authority, Git/committed bytes, production source, and fresh runtime/test evidence outrank the graph. Never turn a CodeGraph result into mutation authority, a PASS verdict, or a substitute for required runtime evidence.

When `$three-level-delivery` invokes this skill, its stricter CodeGraph gate applies: no fallback to grep, another checkout's graph, or manual reconstruction when the gate itself requires CodeGraph.

## Exact-checkout gate

1. Establish the exact checkout/worktree path and Git identity first.
2. Require the HMS-managed CodeGraph binary at `%USERPROFILE%\.codex\codegraph\current\bin\codegraph.cmd` and require its version to match `delivery-tools.lock.json`.
3. Never use an index from another worktree. Run `codegraph status --json <checkout>` and reject a non-null `worktreeMismatch`.
4. If the checkout is not initialized, initialize only local tooling state with `codegraph init <checkout>` when the current authority permits that tooling-state write. Do not edit tracked product files merely to satisfy CodeGraph.
5. Keep `.codegraph/` local and untracked. Prefer repository-local Git exclude state such as `.git/info/exclude`; do not modify a tracked `.gitignore` unless that path is explicitly authorized.
6. Run `codegraph sync <checkout>` and then `codegraph status --json <checkout>` again.
7. Require an initialized usable index. A failed/partial/indexing state, unresolved worktree mismatch, or other health condition that makes structural results unreliable is non-PASS. If the installed CodeGraph reports that a full re-index is required, perform it only when local tooling-state mutation is allowed, then re-check status.

## Focused exploration

For Three-Level Delivery, run exactly one focused `codegraph_explore` MCP query in the actual writable checkout with `maxFiles: 2`, matching the canonical Three-Level Delivery contract. Record the query and result as context evidence. A genuine no-code/documentation-only result may be recorded as such, but does not waive the ensure/synchronize gate.

Outside Three-Level Delivery, prefer the smallest CodeGraph query that answers the structural question. Avoid dumping a whole repository graph into context.

## Failure rule

If the pinned binary, exact-checkout index, required MCP tool, synchronization, or focused exploration is unavailable, report the actual non-PASS state. Do not pretend CodeGraph ran and do not silently substitute another tool when the governing workflow forbids fallback.
