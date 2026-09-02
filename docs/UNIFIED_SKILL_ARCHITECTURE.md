# HMS Unified Skill Architecture

## Goal

Codex should see one public HMS skill entry point: `$hms-superpowers`.

The selected capabilities remain separate source modules for supply-chain pinning, update control, and auditability, but they are compiled into one generated skill bundle. Internal module source files are renamed to `MODULE.md` inside the bundle so Codex does not discover them as independent skills.

## Selectable work modules

| Module | Exclusive primary responsibility | Must not own |
| --- | --- | --- |
| HMS Core | authority, checkpoint, scope, model-floor escalation, evidence, independent-review criteria, release gate, handoff | final enabled-model assignment, visual taste, implementation-method details |
| Superpowers | engineering method: planning, worktree discipline, debugging, TDD, implementation workflow, review method | HMS authority, scope expansion, release permission, canonical visual direction |
| GPT Taste | visual direction, aesthetic options, taste critique | production mutation authority, release, final UI audit |
| Impeccable | UI quality audit and polish: consistency, typography, spacing, accessibility, interaction refinement | redefining frozen product/design authority or independent visual direction |

These four are selectable work modules. Every task slice has exactly one primary work-module owner.

## Always-internal model dispatcher

`hms-model-dispatcher` is a separate source skill, but it is not a selectable work module and is never exposed as a second public skill.

When at least one work module is enabled, the compiler always embeds:

- `references/model-dispatcher/MODULE.md`
- `references/model-dispatcher/Resolve-HmsModelRoute.ps1`

The responsibility split is explicit:

1. `hms-model-router` classifies task risk and required model capability floor.
2. `hms-model-dispatcher` reads the enabled model pool and chooses the actual permitted model.
3. The primary work module owns the task itself.

The model dispatcher never becomes product authority and never owns engineering/UI decisions.

## Model pool and popup

Model availability is configured separately from work-module ON/OFF state.

The Windows popup is launched with:

`HMS-Model-Settings.cmd`

It controls:

- GPT-5.6 Luna ON/OFF
- GPT-5.6 Terra ON/OFF
- GPT-5.6 Sol ON/OFF

Canonical local state:

`%USERPROFILE%\.codex\hms-composite\model-settings.json`

The model state is intentionally outside the generated work-module manifest so model availability can change without recompiling public skill discovery.

### Safe fallback contract

Fallback is upward-only by required capability:

- Luna OFF -> Luna-class work may move to Terra, then Sol.
- Terra OFF -> Terra-class work may move to Sol.
- Sol OFF -> Sol-required work is `NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR`.
- all models OFF -> all material model-routed work is blocked.

A weaker model never inherits a stronger mandatory floor merely because the stronger model is disabled.

Model availability policy is also not proof that Codex actually switched model. The runtime must expose/confirm the assigned route; otherwise the affected material slice stays non-PASS.

## One-primary-owner rule

Every task slice must have exactly one primary work-module owner.

Other enabled modules can be consulted only in their assigned supporting role. Two modules must not independently redesign or mutate the same artifact in parallel.

Examples:

- product authority decision -> HMS Core;
- root-cause debugging -> Superpowers, bounded by HMS Core when HMS is enabled;
- choose a visual direction -> GPT Taste;
- audit an accepted UI direction -> Impeccable;
- implement an accepted UI -> Superpowers; Taste and Impeccable are advisory; HMS Core owns scope/evidence/release if enabled.

The Model Dispatcher participates in none of those ownership decisions; it only assigns an enabled model after the required floor is known.

## UI pipeline

When all relevant modules are enabled, use this order:

1. owner/project authority and HMS UI authority establish constraints;
2. GPT Taste proposes or critiques visual direction only where discretion remains;
3. Impeccable audits and polishes the accepted direction;
4. Superpowers owns implementation method;
5. HMS Core owns evidence, review, and release gates.

This is sequential collaboration, not merged authority.

## Discovery contract

The manager and installer must not expose these source trees directly under `.agents/skills`:

- HMS source skill collection;
- upstream Superpowers source skill collection;
- GPT Taste source skill;
- Impeccable source skill;
- HMS model-dispatcher source skill.

Instead they build a managed composite bundle under:

`%USERPROFILE%\.codex\hms-composite\hms-superpowers`

and expose only:

`%USERPROFILE%\.agents\skills\hms-superpowers`

Internal copied skill entry files are renamed from `SKILL.md` to `MODULE.md` before activation so recursive skill discovery cannot turn them back into separate public skills.

## State contract

Work-module state is stored in the generated bundle's `manifest.json`. The manifest is replaced together with the bundle, so the displayed Manager state and the actual compiled work modules share one authority.

Model-pool state is stored separately in `model-settings.json` and is consumed by the dedicated model dispatcher before each model-routed task slice.

When all work modules are OFF, the managed bundle may remain for state/audit purposes, but the `.agents\skills\hms-superpowers` discovery junction must be absent. Model settings remain preserved for the next activation.

## Conflict handling

Existing unrelated files, directories, symbolic links, or reparse points at managed discovery paths are conflicts. They must never be silently overwritten or removed.

Legacy HMS-managed direct junctions may be migrated only after exact Junction type and exact target verification. Removal must revalidate identity at the destructive boundary.

Invalid or foreign-owned model-settings JSON is also a conflict; the dispatcher must not silently replace its meaning with guessed defaults.

## Update contract

Updating source repositories does not automatically alter work-module ON/OFF choices or model ON/OFF choices.

After exact pinned sources are reconciled, the composite is rebuilt from the current work-module manifest state. The independent `model-settings.json` file is preserved.

Three concepts remain separate:

- source update changes reviewed bytes available to a module;
- work-module toggle changes whether that module is compiled into the single public skill;
- model toggle changes which GPT-5.6 models may receive future task slices.
