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
5. HMS project-specific skills, including `$hms-ui-design-authority`;
6. optional design-advisor skills such as `$taste-skill:gpt-taste` and `$impeccable:impeccable`;
7. upstream Superpowers;
8. Codex defaults.

A lower layer cannot silently override a higher one.

## Start procedure

1. Invoke `$hms-authority-loader` when the task depends on prior HMS state.
2. Establish current repository/runtime identity before a material mutation.
3. Invoke `$hms-authority-gate` before changing production state.
4. Invoke `$hms-scope-lock` for implementation or remediation work.
5. Invoke `$hms-model-router` for non-trivial work and obey the strongest available routing mechanism. If the runtime cannot switch model/effort itself, report the required route instead of pretending it switched.
6. Invoke `$hms-ui-design-authority` before material UI/UX, design-system, Penpot, DESIGN.md, token, component-mapping, or visual-regression work.
7. When useful and enabled, use `$taste-skill:gpt-taste` and/or `$impeccable:impeccable` only as design advisors inside the UI authority and scope already established by step 6.
8. Use upstream Superpowers process skills when applicable.
9. Use `$hms-evidence-gate` before any PASS/completion claim.
10. Add `$hms-independent-review` for architecture, security, trust-boundary, critical blocker, release, or final-stage gates.
11. Use `$hms-release-gate` before merge/push/release when those actions are in scope.
12. Use `$hms-handoff` after every material checkpoint.

## UI advisor adaptation

Taste and Impeccable can raise visual quality, but their generic prescriptions are not product authority. Ignore or narrow any advisor rule that conflicts with owner instruction, a frozen HMS definition, Penpot, `DESIGN.md`, design tokens/component mapping, platform constraints, or behavior outside the authorized scope.

Do not import marketing-site conventions such as mandatory AIDA structure, GSAP motion, randomized layouts, oversized cinematic spacing, or font bans into a desktop engineering/productivity UI unless the higher UI authority explicitly supports those choices.

The external advisor repositories are intentionally namespace-qualified by Codex. Use the discovery identities recorded in `ui-skills.lock.json`; do not assume the raw frontmatter name is the invocation name.

## Superpowers adaptation

Do not rerun brainstorming merely because upstream prefers it when an approved/frozen HMS product definition already resolves the design question. Brainstorm only genuinely unresolved choices.

For UI work, an approved canonical design cannot be silently replaced by upstream brainstorming, Taste, Impeccable, or agent visual preference. Route material UI work through `$hms-ui-design-authority` and preserve Penpot, `DESIGN.md`, design tokens, component mapping, and visual evidence according to the project authority.

Use upstream systematic debugging when root cause is unknown. Use upstream worktree discipline for material mutations. Use TDD for deterministic production logic. For OS/kernel/UAC/service/native-I/O/hardware-dependent behavior, require the strongest appropriate deterministic harness plus real runtime evidence rather than inventing artificial unit tests.

## Parallelism

Parallel read-only analysis is allowed when concerns are independent. Do not allow concurrent agents to mutate the same files, authority artifact, or trust boundary.

## Completion rule

Evidence over claims. Authority over improvisation. Fail closed over assumption.
