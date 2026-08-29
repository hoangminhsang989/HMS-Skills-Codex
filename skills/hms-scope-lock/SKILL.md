---
name: hms-scope-lock
description: Use during HMS implementation, remediation, refactoring, or review when the task has a bounded checkpoint scope and unrelated cleanup or adjacent improvements could cause scope creep.
---

# HMS Scope Lock

Keep mutations inside the authorized change surface.

## Before editing

Write a compact scope map:

- required outcome;
- allowed files/modules/components;
- explicitly forbidden or deferred areas;
- required tests/evidence;
- dependencies that may be read but not modified.

## During work

When an adjacent defect is discovered:

- fix it only if the current authority necessarily includes it;
- otherwise record it as a finding/blocker/follow-up and leave production state unchanged there.

Do not bundle aesthetic cleanup, dependency upgrades, broad formatting, unrelated refactors, or test weakening into a checkpoint merely because the files are already open.

## Review

Before completion, compare the actual diff/change set against the scope map. Any unexplained file or semantic change is a blocker until reconciled.
