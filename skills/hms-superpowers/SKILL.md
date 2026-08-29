---
name: hms-superpowers
description: Use when working on an HMS project, continuing an HMS checkpoint, or when the user requests the unified HMS workflow for implementation, debugging, review, integration, UI work, or release work.
---

# HMS Core Orchestration Module

This source is compiled into the single public `$hms-superpowers` skill. Inside the generated bundle it becomes `references/hms/hms-superpowers/MODULE.md`; it is not a separately invoked child skill.

## Primary ownership

HMS Core exclusively owns:

- authority and checkpoint selection;
- mutation permission and fail-closed decisions;
- scope locking;
- model-routing requirements;
- evidence requirements;
- independent-review criteria;
- integration/release authorization;
- durable checkpoint and handoff state.

HMS Core does not replace the engineering-method owner or the UI advisors. When those modules are enabled, route work to them only inside the boundaries established here.

## Precedence

Always preserve this order:

1. owner instruction;
2. latest valid HMS checkpoint or frozen authority;
3. HMS fail-closed and safety rules;
4. HMS adaptive model-routing policy;
5. HMS project-specific product/UI authority;
6. explicit Three-Level Delivery governance when the owner specifically requests that mode for the current slice;
7. enabled Superpowers engineering method;
8. enabled derived/advisory modules such as CodeGraph context, GPT Taste, and Impeccable;
9. Codex defaults.

A lower layer cannot silently override a higher one. CodeGraph output is derived repository context, never mutation authority or a replacement for committed bytes and fresh runtime evidence.

## Internal module routing

Do not invoke child skills by `$name`. Load only the needed internal `MODULE.md` reference from the generated composite.

For ordinary HMS work:

1. Load `references/hms/hms-authority-loader/MODULE.md` when prior HMS state matters.
2. Establish current repository/runtime identity before material mutation.
3. Load `references/hms/hms-authority-gate/MODULE.md` before changing production state.
4. Load `references/hms/hms-scope-lock/MODULE.md` for implementation or remediation.
5. Load `references/hms/hms-model-router/MODULE.md` for non-trivial work and report the required route if runtime switching is unavailable.
6. For material UI work, load `references/hms/hms-ui-design-authority/MODULE.md` before any design or production UI decision.
7. When structural repository context is materially useful, load `references/hms/codegraph-context/MODULE.md`; CodeGraph remains an MCP/tool layer, not a public skill.
8. When the owner explicitly requests Three-Level Delivery, load `references/hms/three-level-delivery/MODULE.md`; never infer that mode merely from task size or duration.
9. If Superpowers is enabled, load only the relevant engineering-method reference under `references/superpowers/`.
10. If UI advisors are enabled and UI authority leaves discretion, use `references/taste/MODULE.md` for visual direction and `references/impeccable/MODULE.md` for UI audit/polish. They are sequential advisors, not parallel owners.
11. Load `references/hms/hms-evidence-gate/MODULE.md` before a PASS/completion claim.
12. Load `references/hms/hms-independent-review/MODULE.md` for architecture, security, trust-boundary, critical-blocker, release, or final-stage gates.
13. Load `references/hms/hms-release-gate/MODULE.md` before merge/push/release when those actions are in scope.
14. Load `references/hms/hms-handoff/MODULE.md` after each material checkpoint.

## One-primary-owner rule

Every task slice has exactly one primary owner:

- HMS Core: governance and final arbitration;
- Superpowers: engineering method and implementation workflow;
- GPT Taste: visual direction and aesthetic critique;
- Impeccable: UI quality audit and polish.

Supporting modules may advise, but they cannot independently redefine the same decision. Never allow Taste and Impeccable to run competing redesigns, and never allow two modules to mutate the same files or authority artifact concurrently.

## UI sequence

When all relevant modules are enabled, use this sequence:

1. owner/project/HMS UI authority fixes the constraints;
2. GPT Taste proposes or critiques visual direction only where discretion remains;
3. Impeccable audits and polishes the accepted direction;
4. Superpowers owns implementation method;
5. HMS Core owns evidence, independent-review criteria, and release gates.

A frozen Penpot/DESIGN.md/tokens/component mapping contract cannot be silently replaced by Taste, Impeccable, upstream brainstorming, or agent preference.

## Three-Level Delivery adaptation

Three-Level Delivery is explicit opt-in governance inside an already-authorized HMS slice. Its canonical source is pinned in `delivery-tools.lock.json`. The internal HMS adapter must verify the exact source pin and canonical freshness gate before target mutation. A newer upstream version is `UPDATE_REQUIRED`, not permission to self-update.

Inside a valid slice, Three-Level Delivery locks the approved slice, CodeGraph supplies bounded structural context, Superpowers supplies technical method, and Three-Level Delivery records evidence/state and stops at the Owner gate. The HMS release gate remains separately authoritative for merge, push, deployment, privilege, machine-state, or physical execution boundaries.

## CodeGraph adaptation

The HMS-managed CodeGraph release is pinned by exact tag/commit and Windows asset SHA-256 in `delivery-tools.lock.json`. Codex MCP registration must point to the exact HMS-managed binary path. A pre-existing `codegraph` MCP registration with a different command is a conflict and must never be overwritten silently.

Require exact-checkout/worktree graph identity. Reject graph state borrowed from another worktree. If a governing workflow requires CodeGraph and it is unavailable, preserve the non-PASS state rather than silently substituting grep or guesswork.

## Superpowers adaptation

Do not rerun brainstorming merely because upstream prefers it when an approved/frozen HMS definition already resolves the design question. Brainstorm only genuinely unresolved choices.

Use systematic debugging when root cause is unknown, worktree discipline for material mutations, and TDD for deterministic production logic. For OS/kernel/UAC/service/native-I/O/hardware-dependent behavior, require the strongest appropriate deterministic harness plus real runtime evidence rather than artificial unit evidence.

## Parallelism

Parallel read-only analysis is allowed for independent concerns. No two modules or agents may concurrently mutate the same files, authority artifact, or trust boundary. When Three-Level Delivery is active, its stricter single-writable-checkout and one-Writer topology wins.

## Completion rule

One public skill. One primary owner per task slice. Evidence over claims. Authority over improvisation. Fail closed over assumption.
