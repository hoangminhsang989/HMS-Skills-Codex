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

## Task / module / model dispatch

For every non-trivial task, treat the workflow as bounded task slices rather than assigning one model to the entire project.

Before each material slice:

1. load `references/hms/hms-model-router/MODULE.md`;
2. assign exactly one primary module owner;
3. assign the required model and reasoning-effort floor from task risk;
4. list only the supporting modules needed for that slice;
5. bind the slice to an evidence, review, or release gate;
6. re-dispatch whenever the task type, uncertainty, blast radius, trust boundary, or release significance changes.

Use this compact execution record when the route is material or changes:

```text
TASK_SLICE=<bounded work>
PRIMARY_MODULE=<hms|superpowers|taste|impeccable>
MODEL=<gpt-5.6-luna|gpt-5.6-terra|gpt-5.6-sol>
EFFORT=<maximum-available-for-luna|medium|high|xhigh|max>
SUPPORTING_MODULES=<enabled modules or none>
COMPLETION_GATE=<gate>
```

Baseline model responsibilities:

- Luna at maximum available Luna reasoning: deterministic low-risk/high-volume mechanical work;
- Terra/medium: normal bounded work;
- Terra/high: non-trivial implementation and ordinary debugging;
- Sol/high: complex multi-subsystem reasoning/debugging;
- Sol/xhigh: architecture, security, migration, privilege/destructive or material trust-boundary work;
- Sol/max: critical blocker/release gates and final independent review.

Model choice and module ownership are independent. GPT Taste does not automatically imply Sol, and Superpowers does not automatically imply Terra. Risk determines the model floor; responsibility determines the primary module.

A stronger available route may satisfy a lower floor when authority permits, but cost savings may never lower a mandatory route. A final review still requires fresh reviewer independence; switching the authoring agent to Sol/max is not self-approval.

If the required primary module is disabled, do not impersonate it: report `MODULE_REQUIRED=<module>` and stop that material slice unless higher authority explicitly defines a fallback. If the runtime cannot satisfy a mandatory model/effort route, report the exact route required and stop that slice. Never claim a model switch without observable runtime evidence.

## Internal module routing

Do not invoke child skills by `$name`. Load only the needed internal `MODULE.md` reference from the generated composite.

For ordinary HMS work:

1. Load `references/hms/hms-authority-loader/MODULE.md` when prior HMS state matters.
2. Establish current repository/runtime identity before material mutation.
3. Load `references/hms/hms-authority-gate/MODULE.md` before changing production state.
4. Load `references/hms/hms-scope-lock/MODULE.md` for implementation or remediation.
5. Load `references/hms/hms-model-router/MODULE.md` for every non-trivial task slice and report the required route if runtime switching is unavailable.
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

One public skill. One primary owner per task slice. One risk-qualified model route per material slice. Evidence over claims. Authority over improvisation. Fail closed over assumption.
