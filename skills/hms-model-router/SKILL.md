---
name: hms-model-router
description: Use internally to classify HMS task risk and produce the required model capability floor and reasoning effort before the dedicated hms-model-dispatcher selects an enabled model.
---

# HMS Model Risk Classifier

This skill classifies risk. It does **not** inspect model ON/OFF settings and does **not** choose the final assigned model.

The dedicated `hms-model-dispatcher` consumes the required floor from this classifier and maps it onto the enabled model pool.

## Risk classes and required floors

| Risk class | Required floor | Vietnamese description |
| --- | --- | --- |
| `FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL` | Luna at maximum reasoning available for Luna | Việc cơ học, lặp lại, deterministic, read-only/housekeeping hoặc chỉnh sửa rất hẹp có blast radius thấp. |
| `NORMAL_WORK` | Terra / medium | Công việc phát triển bình thường, phạm vi rõ, không có trust-boundary đặc biệt. |
| `MODERATE_DEBUG_OR_IMPLEMENTATION` | Terra / high | Debug hoặc implementation không tầm thường nhưng kiến trúc đã hiểu rõ. |
| `COMPLEX_WORK` | Sol / high | Công việc phức tạp, nhiều subsystem, reasoning sâu hoặc root cause khó. |
| `ARCHITECTURE_SECURITY_MIGRATION` | Sol / xhigh | Architecture, security, migration, privilege/destructive boundary hoặc trust-boundary material. |
| `CRITICAL_BLOCKER_RELEASE_GATE` | Sol / max | Blocker nghiêm trọng hoặc release/integration gate có blast radius cao. |
| `FINAL_STAGE_REVIEW` | Sol / max + independent review | Review độc lập cuối stage/release; model mạnh không thay thế reviewer independence. |

## Escalation

Escalate to at least `Sol / xhigh` for material changes to architecture, authentication/authorization, privilege, sandbox/trust boundaries, destructive state, irreversible migration, service/UAC/kernel/native-I/O lifecycle, or production executable provenance.

Escalate to `Sol / max` for critical blocker gates and final release/stage review where HMS authority requires it.

If uncertainty or blast radius grows during execution, reclassify before continuing.

## Output contract

Produce:

```text
RISK_CLASS=<class>
REQUIRED_MODEL_FLOOR=<floor>
```

Then hand off assignment to `hms-model-dispatcher`.

## Fail-closed rule

Unknown risk classification or unresolved escalation is not permission to choose a cheaper model. Preserve a non-PASS state and request stronger classification/review.
