---
name: hms-model-router
description: Use internally to classify HMS task risk and produce the required model capability floor and reasoning effort before the dedicated hms-model-dispatcher selects an enabled model.
---

# HMS Model Risk Classifier

This skill classifies risk. It does **not** inspect model ON/OFF settings and does **not** choose the final assigned model.

The dedicated `hms-model-dispatcher` consumes the exact required floor emitted here and maps it onto the enabled model pool. Higher HMS/project authority may raise this floor; neither the router nor dispatcher may lower it.

## Risk classes and required floors

| Risk class | Exact required floor | Meaning | Vietnamese description |
| --- | --- | --- | --- |
| `FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL` | `LUNA_LOW_RISK` | Luna/max-available minimum; stronger fallback allowed | Việc cơ học, lặp lại, deterministic, read-only/housekeeping hoặc chỉnh sửa rất hẹp có blast radius thấp. |
| `NORMAL_WORK` | `TERRA_MEDIUM_OR_STRONGER` | Terra/medium minimum | Công việc phát triển bình thường, phạm vi rõ, không có trust-boundary đặc biệt. |
| `MODERATE_DEBUG_OR_IMPLEMENTATION` | `TERRA_HIGH_OR_STRONGER` | Terra/high minimum | Debug hoặc implementation không tầm thường nhưng kiến trúc đã hiểu rõ. |
| `COMPLEX_WORK` | `SOL_HIGH` | Sol/high required | Công việc phức tạp, nhiều subsystem, reasoning sâu hoặc root cause khó. |
| `ARCHITECTURE_SECURITY_MIGRATION` | `SOL_XHIGH` | Sol/xhigh required | Architecture, security, migration, privilege/destructive boundary hoặc trust-boundary material. |
| `CRITICAL_BLOCKER_RELEASE_GATE` | `SOL_MAX` | Sol/max required | Blocker nghiêm trọng hoặc release/integration gate có blast radius cao. |
| `FINAL_STAGE_REVIEW` | `SOL_MAX_AND_INDEPENDENT_REVIEW` | Sol/max plus separate reviewer-independence requirement | Review độc lập cuối stage/release; model mạnh không thay thế reviewer independence. |

## Escalation

Escalate to at least `SOL_XHIGH` for material changes to architecture, authentication/authorization, privilege, sandbox/trust boundaries, destructive state, irreversible migration, service/UAC/kernel/native-I/O lifecycle, or production executable provenance.

Escalate to `SOL_MAX` for critical blocker gates. Final stage/release independent review uses `SOL_MAX_AND_INDEPENDENT_REVIEW` so reviewer independence cannot be erased by model assignment.

If uncertainty or blast radius grows during execution, reclassify before continuing. Higher authority may explicitly raise `REQUIRED_MODEL_FLOOR` above the class default.

## Output contract

Produce exact machine-readable identifiers:

```text
RISK_CLASS=<class>
REQUIRED_MODEL_FLOOR=<LUNA_LOW_RISK|TERRA_MEDIUM_OR_STRONGER|TERRA_HIGH_OR_STRONGER|SOL_HIGH|SOL_XHIGH|SOL_MAX|SOL_MAX_AND_INDEPENDENT_REVIEW>
```

Then pass both values unchanged to `hms-model-dispatcher`. The dispatcher validates that the supplied floor is not below the risk-class minimum and performs enabled-model assignment from the floor itself.

## Fail-closed rule

Unknown risk classification, unknown floor, or unresolved escalation is not permission to choose a cheaper model. Preserve a non-PASS state and request stronger classification/review.
