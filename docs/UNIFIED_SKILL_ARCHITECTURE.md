# HMS Unified Skill Architecture

## Goal

Codex should see one public HMS skill entry point: `$hms-superpowers`.

The selected capabilities remain separate source modules for supply-chain pinning, update control, and auditability, but they are compiled into one generated skill bundle. Internal module source files are renamed to `MODULE.md` inside the bundle so Codex does not discover them as independent skills.

## Selectable modules

| Module | Exclusive primary responsibility | Must not own |
| --- | --- | --- |
| HMS Core | authority, checkpoint, scope, model routing, evidence, independent review criteria, release gate, handoff | visual taste, implementation method details |
| Superpowers | engineering method: planning, worktree discipline, debugging, TDD, implementation workflow, review method | HMS authority, scope expansion, release permission, canonical visual direction |
| GPT Taste | visual direction, aesthetic options, taste critique | production mutation authority, release, final UI audit |
| Impeccable | UI quality audit and polish: consistency, typography, spacing, accessibility, interaction refinement | redefining frozen product/design authority or independent visual direction |

The dispatcher kernel is always present in the generated bundle when at least one module is enabled. It is not a selectable module. Its only job is arbitration and task routing.

## One-primary-owner rule

Every task slice must have exactly one primary module owner.

Other enabled modules can be consulted only in their assigned supporting role. Two modules must not independently redesign or mutate the same artifact in parallel.

Examples:

- product authority decision -> HMS Core;
- root-cause debugging -> Superpowers, bounded by HMS Core when HMS is enabled;
- choose a visual direction -> GPT Taste;
- audit an accepted UI direction -> Impeccable;
- implement an accepted UI -> Superpowers; Taste and Impeccable are advisory; HMS Core owns scope/evidence/release if enabled.

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
- Impeccable source skill.

Instead they build a managed composite bundle under:

`%USERPROFILE%\.codex\hms-composite\hms-superpowers`

and expose only:

`%USERPROFILE%\.agents\skills\hms-superpowers`

Internal copied skill entry files are renamed from `SKILL.md` to `MODULE.md` before activation so recursive skill discovery cannot turn them back into separate public skills.

## State contract

The active module state is stored in the generated bundle's `manifest.json`. The manifest is replaced together with the bundle, so the displayed Manager state and the actual compiled skill share one authority.

When all modules are OFF, the managed bundle may remain for state/audit purposes, but the `.agents\skills\hms-superpowers` discovery junction must be absent.

## Conflict handling

Existing unrelated files, directories, symbolic links, or reparse points at managed discovery paths are conflicts. They must never be silently overwritten or removed.

Legacy HMS-managed direct junctions may be migrated only after exact Junction type and exact target verification. Removal must revalidate identity at the destructive boundary.

## Update contract

Updating source repositories does not automatically alter module ON/OFF choices. After exact pinned sources are reconciled, the composite is rebuilt from the current manifest state.

A source update and a module-state update are separate concepts:

- source update changes reviewed bytes available to a module;
- Manager toggle changes whether that module is compiled into the single public skill.
