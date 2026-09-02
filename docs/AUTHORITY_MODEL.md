# HMS authority model

## Purpose

HMS Skills Codex separates **what is authorized** from **how an agent prefers to work**. Process convenience, graph-derived context, design-advisor preferences, model availability, and upstream workflow defaults must never become authority.

The runtime exposes one public HMS skill, `$hms-superpowers`. All HMS gates, Superpowers methods, UI advisors, delivery/context adapters, and the dedicated model dispatcher used by that workflow are internal modules selected and arbitrated by the composite dispatcher.

## Precedence

```text
OWNER INSTRUCTION
      ↓
LATEST VALID HMS CHECKPOINT / FROZEN AUTHORITY
      ↓
HMS FAIL-CLOSED + SAFETY RULES
      ↓
HMS MODEL RISK FLOOR + DEDICATED MODEL DISPATCHER
      ↓
HMS PROJECT-SPECIFIC PRODUCT / UI AUTHORITY
      ↓
EXPLICIT THREE-LEVEL DELIVERY GOVERNANCE
(only when owner requests it for an already-authorized HMS slice)
      ↓
ENABLED SUPERPOWERS ENGINEERING METHOD
      ↓
CODEGRAPH CONTEXT/EVIDENCE + ENABLED UI ADVISORS
      ↓
CODEX DEFAULTS
```

When two sources conflict, the higher layer wins. At the same layer, use the newest valid authority that actually supersedes the older one; do not assume a newer filename automatically supersedes an older checkpoint.

Three-Level Delivery is never active implicitly. The owner requests that mode through `$hms-superpowers`, and the dispatcher loads the internal adapter. CodeGraph, GPT Taste, and Impeccable are derived/advisory helpers and do not create mutation authority.

## One-primary-owner rule

A task slice has exactly one primary **work-module** owner:

- HMS Core — governance, scope, risk-floor/escalation requirements, evidence/review/release, handoff;
- Superpowers — engineering method and implementation workflow;
- GPT Taste — unresolved visual direction and aesthetic critique;
- Impeccable — UI audit and polish inside an accepted direction.

The dedicated HMS Model Dispatcher is not a work owner. It receives the required model floor and selects an enabled GPT-5.6 model that safely satisfies that floor.

Supporting modules can advise but cannot compete for ownership. Two work modules must not independently redesign or mutate the same artifact in parallel.

## Model-dispatch boundary

Model routing is deliberately split into two responsibilities:

1. `hms-model-router` classifies risk and emits the required model capability floor.
2. `hms-model-dispatcher` maps that floor onto the locally enabled model pool.

Local model availability is configured by `HMS-Model-Settings.cmd` and stored in `%USERPROFILE%\.codex\hms-composite\model-settings.json`.

Fallback is capability-preserving only:

- Luna-class work may move Luna -> Terra -> Sol;
- Terra-class work may move Terra -> Sol;
- Sol-required work cannot move down to Terra/Luna and becomes `NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR` when Sol is disabled;
- all-models-OFF blocks every material model-routed task slice.

Model selection policy never proves that Codex actually switched model or effort. A material slice cannot claim the assigned route unless the runtime supports and observably satisfies it. Final independent review still requires reviewer independence; Sol/max capability alone is not self-approval authority.

## Authority is evidence-bearing

A durable authority should identify enough of the following to make continuation deterministic:

- project/repository identity;
- branch, commit, tree, artifact hash, or other relevant immutable identity;
- explicit verdict;
- completed scope;
- unresolved blockers;
- allowed next action;
- integration/push/UAC state when relevant;
- required verification or review gates.

## Fail-closed states

`UNKNOWN`, `UNVERIFIED`, `PARTIAL`, `TIMEOUT`, `CANCELED`, `INCONCLUSIVE`, `BLOCKED`, `STOP`, `DEFERRED`, and `REJECTED` are not synonyms for PASS.

A module may refine the reason for one of these states but must not promote it to PASS without fresh evidence satisfying the required gate.

## Three-Level Delivery boundary

The canonical Three-Level Delivery source is pinned in `delivery-tools.lock.json`. Its HMS compatibility adapter is compiled internally and may be loaded only after the owner explicitly requests Three-Level Delivery through the unified workflow.

On activation the adapter must qualify the exact canonical source and execute the upstream freshness gate before target-repository mutation. A newer canonical version produces an update-required stop until the HMS pin itself is reviewed and changed.

Inside an authorized slice, preserve the canonical topology: one Owner-approved slice, one read-only Lead, one Writer, one independent read-only Reviewer, one writable checkout, durable state, and a hard stop at the Owner gate. Do not silently open the next slice.

The single Three-Level Delivery Reviewer should satisfy applicable HMS independent-review requirements as well. Do not add a second reviewer merely because both systems mention review; if higher HMS authority explicitly requires a distinct second reviewer, that topology conflict must be resolved before execution.

Three-Level Delivery approval does not imply HMS release authority. Merge, protected-main integration, push, deploy, UAC, service changes, production adoption, physical-machine actions, or other privileged/release boundaries remain subject to the internal HMS release-gate criteria and current authority.

## CodeGraph boundary

CodeGraph is structural repository intelligence, not authority. HMS pins CodeGraph release identity and Windows release-asset SHA-256 in `delivery-tools.lock.json`, installs it locally, and registers the MCP server through the official Codex CLI using the absolute HMS-managed binary path.

The internal CodeGraph context adapter binds CodeGraph to the exact checkout/worktree, ensures/synchronizes its local graph, rejects cross-worktree index reuse, and makes bounded queries. Graph results may accelerate discovery and blast-radius analysis but cannot supersede committed source, Git identity, an HMS checkpoint, test output, runtime receipts, or physical qualification.

Under Three-Level Delivery, the canonical CodeGraph gate is fail-closed and does not permit silent grep/manual fallback. Outside that explicit workflow, CodeGraph is optional unless higher HMS authority requires it.

Project `.codegraph/` data is local tooling state. Do not mutate tracked `.gitignore` merely to hide it; prefer repository-local Git exclude state unless the tracked ignore file is explicitly in scope.

## UI design authority

Material HMS UI work is routed through the internal HMS UI-design-authority module inside the already-authorized project scope. It does not create new mutation authority.

When the project declares Penpot canonical visual authority, the default UI evidence chain is:

```text
APPROVED/FROZEN HMS UI DEFINITION
      ↓
PENPOT CANONICAL VISUAL DESIGN
      ↓
DESIGN.md PROJECT UI LAW
      ↓
DESIGN TOKENS + COMPONENT MAPPING
      ↓
PRODUCTION UI IMPLEMENTATION
      ↓
SCREENSHOT / VISUAL-REGRESSION / RUNTIME EVIDENCE
```

A production screenshot cannot silently supersede editable canonical design, and agent preference cannot silently supersede Penpot or `DESIGN.md`. If required design authority is unavailable or conflicting, dependent UI mutation remains non-PASS until higher authority resolves the gap.

### Optional design advisors

GPT Taste and Impeccable may be enabled as internal UI-quality modules. Their responsibilities are deliberately separated:

- Taste owns unresolved visual direction, composition, hierarchy, and aesthetic critique;
- Impeccable owns consistency, typography, spacing, accessibility, interaction refinement, and final polish inside the accepted direction.

They are not product authority. Generic directives from those sources — including AIDA structure, GSAP motion, font bans/preferences, randomized layout choices, dramatic spacing, redesign defaults, or framework/dependency suggestions — apply only when compatible with higher HMS/UI authority and exact task scope.

Their upstream source identities are pinned in `ui-skills.lock.json`. Those namespace-qualified identities are retained for source qualification and leak-detection tests, not as the normal user-facing invocation contract.

## Superpowers adaptation

Superpowers is compiled as an internal engineering-method module when enabled. HMS may adapt it as follows:

- Skip redundant brainstorming when a frozen/approved HMS specification already resolves the design question.
- When Three-Level Delivery is active, use Superpowers as its technical method layer rather than as a competing delivery controller.
- For UI work, do not let brainstorming, Taste, Impeccable, or agent style preference replace an approved canonical design.
- Use TDD directly for deterministic production logic.
- For OS/kernel/UAC/service/native-I/O/hardware-dependent behavior, use the strongest appropriate deterministic harness plus real runtime evidence rather than artificial unit tests.
- Keep upstream worktree, systematic-debugging, code-review, and verification disciplines unless a higher HMS authority or active Three-Level Delivery topology requires stricter process.

## Mutation rule

Before a material mutation, HMS Core must establish:

1. current authority;
2. exact permitted scope;
3. current Git/runtime identity;
4. required verification;
5. required review/release gate;
6. primary work-module owner for the task slice;
7. required model capability floor.

Then the dedicated model dispatcher must assign an enabled model satisfying that floor. If any mandatory prerequisite, model assignment, or runtime model identity is unknown, stop at the appropriate internal HMS gate instead of improvising.
