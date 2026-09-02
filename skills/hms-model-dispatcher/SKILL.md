---
name: hms-model-dispatcher
description: Use internally in the unified HMS skill to select an enabled GPT-5.6 model for each task slice after the required model floor is known, automatically reassigning work to an equal-or-stronger enabled model and failing closed when no enabled model satisfies the floor.
---

# HMS Model Dispatcher

This is the dedicated model-assignment skill for HMS. It is an internal module of the single public `$hms-superpowers` entry point and must not be exposed as a second public skill.

`hms-model-router` classifies task risk and emits a required model capability floor. This dispatcher owns the separate responsibility of consuming that floor directly and mapping it onto the currently enabled model pool.

## Canonical model settings

The Windows model-settings popup manages:

`%USERPROFILE%\.codex\hms-composite\model-settings.json`

Expected schema:

```json
{
  "schema_version": 1,
  "managed_by": "HMS-Skills-Codex",
  "artifact": "hms-model-settings",
  "models": {
    "luna": true,
    "terra": true,
    "sol": true
  }
}
```

Missing settings default to all three models enabled. Existing settings must be a regular file with exact HMS ownership, exact integer schema version `1`, and real JSON booleans for all model toggles. Invalid or foreign settings are conflicts, not permission to guess or overwrite them.

## Model responsibilities

| Model | Primary responsibility | Vietnamese description |
| --- | --- | --- |
| GPT-5.6 Luna | low-risk deterministic and high-volume mechanical work | Việc cơ học, lặp lại, read-only/housekeeping hoặc chỉnh sửa rất hẹp; chỉ dùng Luna ở mức reasoning cao nhất runtime cho phép. |
| GPT-5.6 Terra | normal work, implementation and ordinary debugging | Công việc phát triển bình thường; Terra medium cho việc thường, Terra high cho implementation/debug không tầm thường. |
| GPT-5.6 Sol | complex reasoning, architecture/security/migration, critical/final gates | Công việc phức tạp; Sol high cho complex work, xhigh cho architecture/security/migration, max cho blocker/release/final review. |

## Safe reassignment ladder

Disabling a preferred model does not orphan work when an enabled stronger model can safely inherit it.

- Luna OFF: Luna-class work may move to Terra, then Sol.
- Terra OFF: Terra-class work may move to Sol.
- Sol OFF: Sol-required work has no lower safe substitute and becomes `NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR`.
- All models OFF: every material model-routed slice is blocked until at least one suitable model is enabled.

Never downgrade a mandatory capability floor merely to keep the workflow moving.

## Required-floor contract

The dispatcher receives both:

```text
RISK_CLASS=<classification>
REQUIRED_MODEL_FLOOR=<authoritative floor>
```

`REQUIRED_MODEL_FLOOR` is the assignment input. The dispatcher must not recompute or lower it from `RISK_CLASS`. The risk class is retained so the resolver can reject a floor below the class minimum while still allowing higher HMS/project authority to raise the floor.

Supported floors:

| Required floor | Safe candidates in order |
| --- | --- |
| `LUNA_LOW_RISK` | Luna/max-available -> Terra/medium -> Sol/high |
| `TERRA_MEDIUM_OR_STRONGER` | Terra/medium -> Sol/high |
| `TERRA_HIGH_OR_STRONGER` | Terra/high -> Sol/high |
| `SOL_HIGH` | Sol/high only |
| `SOL_XHIGH` | Sol/xhigh only |
| `SOL_MAX` | Sol/max only |
| `SOL_MAX_AND_INDEPENDENT_REVIEW` | Sol/max only, plus HMS reviewer-independence gate |

`FINAL_STAGE_REVIEW` must preserve `SOL_MAX_AND_INDEPENDENT_REVIEW`; model capability cannot erase the separate reviewer-independence requirement.

Inside the generated composite, use the bundled deterministic resolver at `references/model-dispatcher/Resolve-HmsModelRoute.ps1`. In the source repository, the reviewed canonical script is `scripts/Resolve-HmsModelRoute.ps1`. Pass the router/higher-authority floor explicitly and use the resolver result instead of inventing a fallback.

## Dispatch output

For each material slice, produce or internally establish:

```text
MODEL_ROUTE_STATUS=<ASSIGNED|BLOCKED>
RISK_CLASS=<class>
REQUIRED_MODEL_FLOOR=<floor>
PREFERRED_MODEL=<model>
ASSIGNED_MODEL=<model-or-none>
EFFORT=<effort-or-none>
REASSIGNED=<true|false>
```

If blocked, report `NO_ENABLED_MODEL_SATISFIES_REQUIRED_FLOOR` and the exact required floor.

## Settings-write boundary

When settings already exist, the popup replaces the canonical file atomically on the same volume so a concurrent resolver sees either the old complete policy or the new complete policy, never an absent-path gap that would temporarily default to all models ON. Existing foreign/invalid settings are not overwritten.

## Runtime-switch boundary

Model pool selection is policy, not proof that Codex actually switched model.

If runtime model/effort controls are available, request the assigned route. If they are unavailable or the current runtime cannot satisfy the route, report the exact required `/model` or equivalent user action and stop the affected material slice. Never claim a switch without observable runtime evidence.

A stronger enabled/current model may satisfy a lower floor when authority permits. A weaker model may not satisfy a stronger floor.

## Independent review boundary

Sol/max is only the capability floor for final review. It does not create reviewer independence. The candidate author cannot self-approve merely by switching to Sol/max; HMS independent-review identity/freshness requirements still apply.

## Fail-closed rule

Unknown settings ownership, invalid settings JSON/schema/types, a floor below the risk-class minimum, no enabled model satisfying the required floor, or unverifiable runtime model identity is not PASS.
