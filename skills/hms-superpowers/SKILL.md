---
name: hms-superpowers
description: Use when working on an HMS project, continuing an HMS checkpoint, or when the user explicitly requests the HMS Superpowers workflow for implementation, debugging, review, integration, or release work.
---

# HMS Superpowers

Use this skill as the HMS orchestration entry point.

## Precedence

Always preserve this order:

1. owner instruction;
2. latest valid HMS checkpoint or frozen authority;
3. HMS fail-closed and safety rules;
4. HMS adaptive model-routing policy;
5. HMS project-specific skills;
6. upstream Superpowers;
7. Codex defaults.

A lower layer cannot silently override a higher one.

## Start procedure

1. Invoke `$hms-authority-loader` when the task depends on prior HMS state.
2. Establish current repository/runtime identity before a material mutation.
3. Invoke `$hms-authority-gate` before changing production state.
4. Invoke `$hms-scope-lock` for implementation or remediation work.
5. Invoke `$hms-model-router` for non-trivial work and obey the strongest available routing mechanism. If the runtime cannot switch model/effort itself, report the required route instead of pretending it switched.
6. Use upstream Superpowers process skills when applicable.
7. Use `$hms-evidence-gate` before any PASS/completion claim.
8. Add `$hms-independent-review` for architecture, security, trust-boundary, critical blocker, release, or final-stage gates.
9. Use `$hms-release-gate` before merge/push/release when those actions are in scope.
10. Use `$hms-handoff` after every material checkpoint.

## Superpowers adaptation

Do not rerun brainstorming merely because upstream prefers it when an approved/frozen HMS product definition already resolves the design question. Brainstorm only genuinely unresolved choices.

Use upstream systematic debugging when root cause is unknown. Use upstream worktree discipline for material mutations. Use TDD for deterministic production logic. For OS/kernel/UAC/service/native-I/O/hardware-dependent behavior, require the strongest appropriate deterministic harness plus real runtime evidence rather than inventing artificial unit tests.

## Parallelism

Parallel read-only analysis is allowed when concerns are independent. Do not allow concurrent agents to mutate the same files, authority artifact, or trust boundary.

## Completion rule

Evidence over claims. Authority over improvisation. Fail closed over assumption.
