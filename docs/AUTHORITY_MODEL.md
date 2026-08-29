# HMS authority model

## Purpose

HMS Skills Codex separates **what is authorized** from **how an agent prefers to work**. Process convenience, graph-derived context, and upstream workflow defaults must never become authority.

## Precedence

```text
OWNER INSTRUCTION
      ↓
LATEST VALID HMS CHECKPOINT / FROZEN AUTHORITY
      ↓
HMS FAIL-CLOSED + SAFETY RULES
      ↓
HMS ADAPTIVE MODEL ROUTING
      ↓
HMS PROJECT-SPECIFIC AUTHORITY / SKILLS
      ↓
EXPLICIT THREE-LEVEL DELIVERY GOVERNANCE
(only inside an already-authorized HMS slice)
      ↓
UPSTREAM SUPERPOWERS TECHNICAL METHOD
      ↓
CODEGRAPH CONTEXT/EVIDENCE + OPTIONAL DESIGN ADVISORS
      ↓
CODEX DEFAULTS
```

When two sources conflict, the higher layer wins. At the same layer, use the newest valid authority that actually supersedes the older one; do not assume a newer filename automatically supersedes an older checkpoint.

Three-Level Delivery is not active implicitly. Its layer exists only after the owner explicitly invokes `$three-level-delivery`. CodeGraph, GPT Taste, and Impeccable are derived/advisory helpers and do not create mutation authority.

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

A skill may refine the reason for one of these states but must not promote it to PASS without fresh evidence satisfying the required gate.

## Three-Level Delivery boundary

The canonical Three-Level Delivery source is pinned in `delivery-tools.lock.json` and loaded through the HMS `$three-level-delivery` compatibility adapter. On explicit activation it must qualify that exact source and execute the upstream freshness gate before target-repository mutation. A newer canonical version produces an update-required stop until the HMS pin itself is reviewed and changed.

Inside an authorized slice, preserve the canonical topology: one Owner-approved slice, one read-only Lead, one Writer, one independent read-only Reviewer, one writable checkout, durable state, and a hard stop at the Owner gate. Do not silently open the next slice.

The single Three-Level Delivery Reviewer should satisfy applicable HMS independent-review requirements as well. Do not add a second reviewer merely because both systems mention review; if a higher HMS authority explicitly requires a distinct second reviewer, that is a topology conflict that must be resolved before execution.

Three-Level Delivery approval does not imply HMS release authority. Merge, protected-main integration, push, deploy, UAC, service changes, production adoption, physical-machine actions, or other privileged/release boundaries remain subject to `$hms-release-gate` and the current HMS authority.

## CodeGraph boundary

CodeGraph is structural repository intelligence, not authority. HMS pins the CodeGraph release identity and Windows release-asset SHA-256 in `delivery-tools.lock.json`, installs it locally, and registers the MCP server through the official Codex CLI using the absolute HMS-managed binary path.

Use `$codegraph-context` to bind CodeGraph to the exact checkout/worktree, ensure/synchronize its local graph, reject cross-worktree index reuse, and make a bounded query. Graph results may accelerate discovery and blast-radius analysis but cannot supersede committed source, Git identity, an HMS checkpoint, test output, runtime receipts, or physical qualification.

Under Three-Level Delivery, the canonical CodeGraph gate is fail-closed and does not permit a silent grep/manual fallback. Outside that explicit workflow, CodeGraph is optional unless a higher HMS authority requires it.

Project `.codegraph/` data is local tooling state. Do not mutate tracked `.gitignore` merely to hide it; prefer repository-local Git exclude state unless the tracked ignore file is explicitly in scope.

## UI design authority

Material HMS UI work uses `$hms-ui-design-authority` inside the already-authorized project scope. It does not create new mutation authority.

When the project declares Penpot as canonical visual authority, the default UI evidence chain is:

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

A production screenshot cannot silently supersede the editable canonical design, and an agent preference cannot silently supersede Penpot or `DESIGN.md`. If required design authority is unavailable or conflicting, the dependent UI mutation remains non-PASS until a higher authority resolves the gap.

### Optional design advisors

`gpt-taste` and `impeccable` may be enabled as reusable UI-quality advisors. They can propose or inspect typography, composition, interaction, motion, accessibility, responsive behavior, anti-patterns, and visual polish.

They are not product authority. Generic directives from those skills — including AIDA structure, GSAP motion, font bans/preferences, randomized layout choices, dramatic spacing, redesign defaults, or framework/dependency suggestions — apply only when they are compatible with the higher HMS/UI authority and exact task scope. A frozen desktop engineering UI must not be converted into a marketing-web aesthetic merely because an advisor skill recommends one.

Their upstream source identities are pinned in `ui-skills.lock.json`; changing a pin is a material workflow change requiring the normal HMS review/evidence gates.

## Superpowers adaptation

Use upstream Superpowers where it improves execution discipline. HMS may adapt it as follows:

- Skip redundant brainstorming when a frozen/approved HMS specification already resolves the design question.
- When Three-Level Delivery is explicitly active, use Superpowers as its technical method layer rather than as a competing delivery controller.
- For UI work, do not let brainstorming, Taste, Impeccable, or agent style preference replace an approved canonical design; route material UI work through `$hms-ui-design-authority`.
- Use TDD directly for deterministic production logic.
- For OS/kernel/UAC/service/native-I/O/hardware-dependent behavior, use the strongest appropriate deterministic harness plus real runtime evidence rather than artificial unit tests.
- Keep upstream worktree, systematic-debugging, code-review, and verification disciplines unless a higher HMS authority or the active Three-Level Delivery topology requires a stricter process.

## Mutation rule

Before a material mutation, identify:

1. current authority;
2. exact permitted scope;
3. current Git/runtime identity;
4. required verification;
5. required review/release gate.

If any mandatory prerequisite is unknown, stop at the appropriate HMS gate instead of improvising.
