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
5. HMS project-specific authority and skills, including `$hms-ui-design-authority`;
6. explicitly invoked `$three-level-delivery` governance inside the already-authorized HMS slice;
7. upstream Superpowers as the technical method layer;
8. derived/advisory helpers such as `$codegraph-context`, `$taste-skill:gpt-taste`, and `$impeccable:impeccable`;
9. Codex defaults.

A lower layer cannot silently override a higher one. CodeGraph output is derived repository context, never mutation authority or a replacement for committed bytes and fresh runtime evidence.

## Start procedure

1. Invoke `$hms-authority-loader` when the task depends on prior HMS state.
2. Establish current repository/runtime identity before a material mutation.
3. Invoke `$hms-authority-gate` before changing production state.
4. Invoke `$hms-scope-lock` for implementation or remediation work.
5. Invoke `$hms-model-router` for non-trivial work and obey the strongest available routing mechanism. If the runtime cannot switch model/effort itself, report the required route instead of pretending it switched.
6. Invoke `$hms-ui-design-authority` before material UI/UX, design-system, Penpot, DESIGN.md, token, component-mapping, or visual-regression work.
7. If and only if the owner explicitly invoked `$three-level-delivery`, invoke the HMS Three-Level Delivery adapter and preserve its one-slice Owner/Lead/Writer/Reviewer topology. Do not auto-activate it based on task size or duration.
8. Use `$codegraph-context` when the governing workflow requires CodeGraph or when focused structural repository context materially reduces blind file-by-file discovery. Under Three-Level Delivery, obey its exact CodeGraph gate and no-fallback rule.
9. When useful and enabled, use `$taste-skill:gpt-taste` and/or `$impeccable:impeccable` only as design advisors inside the UI authority and scope already established by step 6.
10. Use upstream Superpowers process skills when applicable. When Three-Level Delivery is active, Superpowers remains the technical method layer inside the approved slice rather than becoming a second delivery controller.
11. Use `$hms-evidence-gate` before any PASS/completion claim.
12. Add `$hms-independent-review` for architecture, security, trust-boundary, critical blocker, release, or final-stage gates. When Three-Level Delivery is active, its single independent Reviewer must perform these HMS review criteria; do not spawn a second reviewer unless higher authority explicitly resolves that topology change.
13. Use `$hms-release-gate` before merge/push/release when those actions are in scope.
14. Use `$hms-handoff` after every material checkpoint.

## Three-Level Delivery adaptation

Three-Level Delivery is explicit opt-in governance, not a replacement for HMS authority. Its canonical source is pinned in `delivery-tools.lock.json` and loaded through the `$three-level-delivery` adapter. The adapter must verify the exact source pin and run the canonical freshness gate before target mutation. A newer upstream version is `UPDATE_REQUIRED`, not permission to self-update.

Inside a valid slice, keep the canonical order: Three-Level Delivery locks the approved slice, CodeGraph supplies bounded structural context, Superpowers supplies technical method, and Three-Level Delivery records evidence/state and stops at the Owner gate. The HMS release gate remains separately authoritative for merge, push, deployment, privilege, machine-state, or physical execution boundaries.

## CodeGraph adaptation

The HMS-managed CodeGraph release is pinned by exact tag/commit and Windows asset SHA-256 in `delivery-tools.lock.json`. Codex MCP registration must point to the exact HMS-managed binary path. A pre-existing `codegraph` MCP registration with a different command is a conflict; never overwrite it silently.

Require exact-checkout/worktree graph identity. Reject a graph borrowed from another worktree. When CodeGraph is unavailable under a workflow that explicitly requires it, preserve the non-PASS state rather than silently replacing it with grep or guesswork.

## UI advisor adaptation

Taste and Impeccable can raise visual quality, but their generic prescriptions are not product authority. Ignore or narrow any advisor rule that conflicts with owner instruction, a frozen HMS definition, Penpot, `DESIGN.md`, design tokens/component mapping, platform constraints, or behavior outside the authorized scope.

Do not import marketing-site conventions such as mandatory AIDA structure, GSAP motion, randomized layouts, oversized cinematic spacing, or font bans into a desktop engineering/productivity UI unless the higher UI authority explicitly supports those choices.

The external advisor repositories are intentionally namespace-qualified by Codex. Use the discovery identities recorded in `ui-skills.lock.json`; do not assume the raw frontmatter name is the invocation name.

## Superpowers adaptation

Do not rerun brainstorming merely because upstream prefers it when an approved/frozen HMS product definition already resolves the design question. Brainstorm only genuinely unresolved choices.

For UI work, an approved canonical design cannot be silently replaced by upstream brainstorming, Taste, Impeccable, or agent visual preference. Route material UI work through `$hms-ui-design-authority` and preserve Penpot, `DESIGN.md`, design tokens, component mapping, and visual evidence according to the project authority.

Use upstream systematic debugging when root cause is unknown. Use upstream worktree discipline for material mutations. Use TDD for deterministic production logic. For OS/kernel/UAC/service/native-I/O/hardware-dependent behavior, require the strongest appropriate deterministic harness plus real runtime evidence rather than inventing artificial unit tests.

## Parallelism

Parallel read-only analysis is allowed when concerns are independent. Do not allow concurrent agents to mutate the same files, authority artifact, or trust boundary. When Three-Level Delivery is active, its stricter single-writable-checkout and one-Writer topology wins.

## Completion rule

Evidence over claims. Authority over improvisation. Fail closed over assumption.
