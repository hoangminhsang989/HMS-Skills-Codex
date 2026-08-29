---
name: hms-ui-design-authority
description: Use when an HMS task creates, changes, reviews, or verifies UI/UX, design-system rules, Penpot designs, DESIGN.md, design tokens, component mappings, screenshots, or visual-regression evidence.
---

# HMS UI Design Authority

Use this skill for material HMS UI/UX work before implementation claims become design authority.

## UI authority order

Preserve the global HMS authority order first. Within an authorized UI scope, use this order:

1. explicit owner instruction;
2. latest approved/frozen HMS product or UI definition;
3. canonical Penpot design when the project declares Penpot authority;
4. project `DESIGN.md`;
5. approved design tokens and component mapping;
6. current production UI as implementation evidence;
7. optional design-advisor skills such as `gpt-taste` and `impeccable`;
8. upstream brainstorming, framework defaults, or agent visual preference.

A lower source may fill a genuinely unspecified detail, but it must not silently override a higher source.

## Optional design-advisor skills

`gpt-taste` and `impeccable` may be used to improve composition, typography, hierarchy, interaction quality, motion, anti-pattern detection, accessibility, and polish when their advice fits the authorized product.

They are **advisors, not authority**. Their generic style preferences, mandatory-looking defaults, layout recipes, motion rules, font preferences, page structures, or redesign instincts must be ignored whenever they conflict with owner instruction, the frozen HMS product definition, Penpot, `DESIGN.md`, approved tokens/component mapping, platform constraints, or existing behavior outside scope.

For desktop engineering/productivity UI, do not import marketing-site conventions merely because a design-advisor skill recommends them. For web surfaces, do not apply animation, AIDA, oversized spacing, randomized layout, or dependency additions unless those choices are compatible with the authorized design and implementation scope.

## Discovery-first procedure

Before asking the owner for configuration, inspect the authorized project for:

- repository/app stack and UI entry points;
- `DESIGN.md` or equivalent design-law file;
- design-token sources;
- Penpot/MCP configuration or project references;
- component-mapping files that bind design components to production components;
- current screenshots, visual baselines, or visual-regression harnesses;
- theme, locale, DPI, viewport, platform, and accessibility constraints that are already authoritative.

Prefer zero-manual-configuration discovery. Do not invent missing authority merely to avoid asking for a genuinely required input.

## Penpot rule

When Penpot is the declared canonical visual authority:

- read the relevant Penpot file/page/frame/component before material visual implementation;
- preserve approved component structure, tokens, spacing, typography, assets, and interaction states;
- treat exported images or screenshots as evidence of the Penpot state, not as a replacement for the canonical editable design;
- do not redesign an approved Penpot screen merely because an upstream or optional advisor skill prefers another style;
- if Penpot access is required but unavailable, mark the UI authority as unavailable and stop the dependent mutation unless a higher authority explicitly permits a fallback.

If no approved design exists and the owner asks for a new design, upstream brainstorming or optional design-advisor skills may be used for unresolved choices. Once approved, record the result in the project's canonical design authority before treating it as frozen implementation input.

## DESIGN.md, tokens, and component mapping

`DESIGN.md` defines project-wide UI laws that are not conveniently represented by a single canvas, including density, platform behavior, accessibility, themes, layout rules, and prohibited patterns.

Design tokens are the canonical source for repeatable values such as color, spacing, typography, radius, stroke, elevation, and motion where the project defines them.

Component mapping binds a canonical design component to its production implementation. Do not create a visually similar parallel component when an authoritative mapped component already exists unless the scope explicitly requires a new variant.

When these sources conflict and the conflict is not already resolved by a higher authority, fail closed and report the conflict instead of choosing one silently.

## Implementation gate

Before changing production UI:

1. invoke `$hms-authority-gate` for the requested mutation;
2. invoke `$hms-scope-lock` and enumerate the allowed screens/components/files;
3. identify the exact design source for each material visual change;
4. preserve existing production behavior that is outside the UI scope;
5. avoid unrelated restyling, framework migration, dependency changes, or component rewrites;
6. use the project's existing UI stack unless a higher authority explicitly authorizes a migration.

For generated or translated UI code, visual similarity alone is not proof of semantic equivalence. Preserve events, state, accessibility semantics, focus behavior, keyboard interaction, localization, and platform-specific behavior that are part of the approved contract.

## Visual evidence gate

Before claiming UI PASS, render the production UI in the relevant target conditions and collect fresh evidence. Use the strongest available project mechanism, such as:

- screenshot comparison against the approved design or baseline;
- visual-regression tests;
- component/state coverage across required variants;
- theme/locale/DPI/viewport checks when applicable;
- accessibility or keyboard/focus checks when required by project authority.

A screenshot of the design tool is not evidence that production matches it. A screenshot of production is not proof that hidden interaction/state behavior is correct.

Material unexplained visual drift is non-PASS. If the design intentionally changes, update the canonical design authority first or obtain explicit authority for the divergence.

## Handoff

At a material UI checkpoint, include:

- canonical design source used;
- `DESIGN.md`/token/component-mapping identities when relevant;
- production files/components changed;
- visual/runtime evidence collected;
- known visual or interaction drift;
- exact next UI action and any unresolved authority dependency.

Use `$hms-evidence-gate` before PASS and `$hms-handoff` for the durable checkpoint.
