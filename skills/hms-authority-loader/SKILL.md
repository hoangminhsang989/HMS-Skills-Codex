---
name: hms-authority-loader
description: Use when resuming an existing HMS project, continuing from a checkpoint, reconciling conflicting revisions, or determining the authoritative next action from repository and conversation state.
---

# HMS Authority Loader

Recover the newest valid authority before continuing stateful HMS work.

## Gather

Inspect only sources relevant to the current project. Prefer, as available:

- direct owner instruction in the current task;
- repository `AGENTS.md` and project instructions;
- explicit checkpoint, handoff, product-definition, architecture, or verdict artifacts;
- Git branch/HEAD/tree/status and remote relationship;
- test/evidence receipts bound to the checkpoint;
- prior conversation authority when supplied by the runtime.

Do not mix authority from a different HMS project merely because terminology overlaps.

## Reconcile

A newer checkpoint supersedes an older checkpoint only when its content/lineage actually establishes that relationship. Do not use filename sorting alone.

When authority artifacts conflict, preserve the conflict as a blocker unless a higher-precedence source resolves it.

## Produce an authority snapshot

Before material work, be able to state:

- project identity;
- newest valid authority/verdict;
- relevant immutable identity such as branch/commit/tree/hash;
- completed scope;
- unresolved blockers;
- exact allowed next action;
- required evidence/review gates;
- integration/push/UAC state when relevant.

Unknown mandatory fields remain UNKNOWN; never synthesize them.
