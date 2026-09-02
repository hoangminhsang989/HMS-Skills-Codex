---
name: hms-ui-design-authority
description: Use when an HMS task creates, changes, reviews, or verifies UI/UX, design-system rules, Penpot designs, DESIGN.md, design tokens, component mappings, screenshots, or visual-regression evidence.
---

# HMS UI Design Authority Module

Inside the unified `$hms-superpowers` bundle this file is an internal HMS module. It owns UI authority resolution; GPT Taste and Impeccable remain separate advisory modules with non-overlapping responsibilities.

## UI authority order

Preserve the global HMS authority order first. Within an authorized UI scope, use this order:

1. explicit owner instruction;
2. latest approved/frozen HMS product or UI definition;
3. canonical Penpot design when the project declares Penpot authority;
4. project `DESIGN.md`;
5. approved design tokens and component mapping;
6. current production UI as implementation evidence;
7. enabled advisor modules in their assigned roles;
8. upstream brainstorming, framework defaults, or agent visual preference.

A lower source may fill a genuinely unspecified detail, but it must not silently override a higher source.

## Advisor role separation

When enabled, load the advisors internally rather than invoking them as public skills:

- `references/taste/MODULE.md` — **visual direction owner** for unresolved aesthetic choices, composition, hierarchy, and taste critique;
- `references/impeccable/MODULE.md` — **UI audit/polish owner** for consistency, typography, spacing, accessibility, interaction refinement, and final craft review.

Do not ask both advisors to independently redesign the same artifact. Taste establishes or critiques direction; Impeccable audits and polishes inside the accepted direction. Neither advisor owns production mutation, product authority, scope, or release.

Their generic style preferences, layout recipes, motion rules, font preferences, page structures, or redesign instincts must be ignored whenever they conflict with owner instruction, a frozen HMS definition, Penpot, `DESIGN.md`, approved tokens/component mapping, platform constraints, or behavior outside scope.

For desktop engineering/productivity UI, do not import marketing-site conventions merely because an advisor recommends them. For web surfaces, do not add animation, AIDA structure, oversized spacing, randomized layout, or dependencies unless compatible with the authorized design and implementation scope.

## Discovery-first procedure

Before asking the owner for configuration, inspect the authorized project for:

- repository/app stack and UI entry points;
- `DESIGN.md` or equivalent design-law file;
- design-token sources;
- Penpot/MCP configuration or project references;
- component-mapping files that bind design components to production components;
- current screenshots, visual baselines, or visual-regression harnesses;
- theme, locale, DPI, viewport, platform, and accessibility constraints already authoritative.

Prefer zero-manual-configuration discovery. Do not invent missing authority merely to avoid asking for a genuinely required input.

## Penpot rule

When Penpot is declared canonical visual authority:

- read the relevant Penpot file/page/frame/component before material visual implementation;
- preserve approved component structure, tokens, spacing, typography, assets, and interaction states;
- treat exported images or screenshots as evidence of Penpot state, not a replacement for the canonical editable design;
- do not redesign an approved Penpot screen because an advisor or engineering-method module prefers another style;
- if Penpot access is required but unavailable, mark UI authority unavailable and stop the dependent mutation unless a higher authority explicitly permits a fallback.

If no approved design exists and the owner requests a new design, unresolved visual choices may be routed to Taste and technical feasibility may be routed to Superpowers. Once approved, record the result in canonical project design authority before treating it as frozen implementation input.

## DESIGN.md, tokens, and component mapping

`DESIGN.md` defines project-wide UI laws that are not conveniently represented by a single canvas, including density, platform behavior, accessibility, themes, layout rules, and prohibited patterns.

Design tokens are canonical for repeatable values such as color, spacing, typography, radius, stroke, elevation, and motion where defined.

Component mapping binds a canonical design component to production implementation. Do not create a visually similar parallel component when an authoritative mapped component already exists unless scope explicitly requires a new variant.

When these sources conflict and higher authority does not resolve the conflict, fail closed instead of choosing silently.

## Production implementation handoff

This module does not own engineering implementation method. Once the visual/design decision is authorized:

1. HMS Core establishes mutation permission and exact scope;
2. Taste contributes direction only if unresolved visual discretion remains;
3. Impeccable audits/polishes the accepted direction when useful;
4. Superpowers owns implementation method when enabled;
5. preserve existing behavior outside UI scope;
6. use the project's existing UI stack unless higher authority explicitly authorizes migration.

For generated or translated UI code, visual similarity alone is not proof of semantic equivalence. Preserve events, state, accessibility semantics, focus behavior, keyboard interaction, localization, and platform-specific behavior that are part of the approved contract.

## Visual evidence gate

Before claiming UI PASS, render production UI in relevant target conditions and collect fresh evidence using the strongest available project mechanism, such as screenshot comparison, visual-regression tests, component/state coverage, theme/locale/DPI/viewport checks, and accessibility or keyboard/focus checks when required.

A screenshot of the design tool is not evidence that production matches it. A screenshot of production is not proof that hidden interaction/state behavior is correct.

Material unexplained visual drift is non-PASS. If the design intentionally changes, update canonical design authority first or obtain explicit authority for divergence.

## Handoff

At a material UI checkpoint, include the canonical design source, relevant DESIGN.md/token/component-mapping identities, production files/components changed, visual/runtime evidence, known drift, and exact next UI action.

Route PASS through the internal HMS evidence-gate module and durable checkpoint output through the internal HMS handoff module. Do not invoke child HMS skills independently.
