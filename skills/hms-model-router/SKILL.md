---
name: hms-model-router
description: Use for non-trivial HMS work to assign each task slice to one primary module owner, select the required GPT-5.6 model and reasoning effort from task risk, define supporting modules, and bind the slice to its evidence or review gate.
---

# HMS Task / Module / Model Dispatcher

Classify every material task slice before substantial reasoning or mutation.

A task slice is one bounded decision or mutation unit with one primary owner, one model route, and one completion gate. A larger workflow may contain multiple slices with different model routes.

## Dispatch record

For non-trivial work, establish this record before execution and whenever the route materially changes:

```text
TASK_SLICE=<bounded work>
PRIMARY_MODULE=<hms|superpowers|taste|impeccable>
MODEL=<gpt-5.6-luna|gpt-5.6-terra|gpt-5.6-sol>
EFFORT=<maximum-available-for-luna|medium|high|xhigh|max>
SUPPORTING_MODULES=<enabled advisory/method modules or none>
COMPLETION_GATE=<evidence/review/release gate>
```

The record is an execution requirement, not proof that the runtime actually changed model.

## Model risk ladder

| Risk class | Preferred route | Vietnamese responsibility |
| --- | --- | --- |
| `FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL` | `gpt-5.6-luna`, maximum reasoning effort available for Luna | Việc cơ học, lặp lại, deterministic, read-only/housekeeping hoặc chỉnh sửa rất hẹp có blast radius thấp. |
| `NORMAL_WORK` | `gpt-5.6-terra`, effort `medium` | Công việc phát triển bình thường, phạm vi rõ và không có trust-boundary đặc biệt. |
| `MODERATE_DEBUG_OR_IMPLEMENTATION` | `gpt-5.6-terra`, effort `high` | Debug hoặc implementation không tầm thường nhưng vẫn trong kiến trúc đã hiểu rõ. |
| `COMPLEX_WORK` | `gpt-5.6-sol`, effort `high` | Công việc phức tạp, nhiều subsystem, reasoning sâu hoặc root cause khó. |
| `ARCHITECTURE_SECURITY_MIGRATION` | `gpt-5.6-sol`, effort `xhigh` | Kiến trúc, security, migration, privilege/destructive boundary hoặc trust-boundary material. |
| `CRITICAL_BLOCKER_RELEASE_GATE` | `gpt-5.6-sol`, effort `max` | Blocker nghiêm trọng, release/integration gate có blast radius cao. |
| `FINAL_STAGE_REVIEW` | `gpt-5.6-sol`, effort `max` | Review độc lập cuối stage/release; model mạnh không thay thế yêu cầu reviewer độc lập. |

Use Luna only at the maximum reasoning level the runtime exposes for Luna. Never intentionally route Luna to a lower effort.

## Primary module ownership

Model choice and module ownership are independent axes. A module does not automatically imply a model.

| Task slice | Primary module | Typical supporting modules |
| --- | --- | --- |
| Authority selection, checkpoint, scope, mutation permission, evidence criteria, release/handoff | HMS Core | Other enabled modules subordinate to HMS boundaries |
| Engineering plan, debugging method, TDD, worktree discipline, production implementation | Superpowers | HMS governance; UI advisors only when relevant |
| Unresolved visual direction, composition, hierarchy, aesthetic critique | GPT Taste | HMS/project UI authority supplies constraints |
| UI audit, typography, spacing, accessibility, consistency, final polish | Impeccable | Taste supplies accepted direction; HMS supplies authority |
| Production UI implementation | Superpowers | Taste direction, Impeccable audit/polish, HMS gates |

Exactly one primary module owns each slice. Supporting modules may advise or provide method but may not independently redefine the same decision or concurrently mutate the same artifact.

## Default task-to-model matrix

Use this matrix as the preferred minimum route unless a higher authority or risk rule requires escalation.

| Work | Primary module | Model / effort | Completion gate |
| --- | --- | --- | --- |
| Read-only scan, log inventory, deterministic mechanical cleanup | HMS or Superpowers by purpose | Luna / maximum available | Evidence proportional to task |
| Routine bounded implementation | Superpowers | Terra / medium | Fresh tests + HMS evidence when HMS enabled |
| Non-trivial implementation or ordinary root-cause debugging | Superpowers | Terra / high | Targeted tests + regression evidence |
| Complex multi-subsystem debugging or design reasoning | Superpowers or HMS by decision owner | Sol / high | Strong deterministic evidence |
| Architecture, security, privilege, migration, destructive or trust-boundary design | HMS for authority; Superpowers for implementation slice | Sol / xhigh | Independent architecture/security review as applicable |
| UI direction with unresolved design discretion | GPT Taste | Terra / high by default; Sol / high if complex | Accepted direction against canonical UI authority |
| UI audit/polish | Impeccable | Terra / high by default; Sol / high if complex | Visual/runtime verification |
| Critical blocker, release/integration authorization | HMS Core | Sol / max | Critical blocker/release gate |
| Final independent stage/release review | HMS review gate | Sol / max | Fresh independent review; no self-approval |

A workflow can and should change route between slices. Example: Terra/high implementation -> Sol/xhigh security assessment -> Sol/max independent release review.

## Mandatory escalation floors

Escalate to at least `Sol / xhigh` when any material slice introduces or changes:

- architecture or cross-subsystem invariants;
- authentication, authorization, secrets, privilege, sandbox or trust boundaries;
- destructive filesystem/database behavior or irreversible migration;
- process/service/UAC/kernel/native-I/O lifecycle with material safety implications;
- supply-chain identity or executable provenance that can authorize production state.

Escalate to `Sol / max` for:

- a critical blocker gate;
- merge/release authorization where the governing authority requires critical review;
- final-stage or final-release independent review.

If uncertainty or blast radius grows during execution, reclassify the current slice before continuing. Cost savings never override the required floor.

## Module availability gate

Do not impersonate a disabled module.

If the matrix requires a primary module that is OFF in the composite:

1. stop that slice before material mutation;
2. report `MODULE_REQUIRED=<module>`;
3. either ask the owner to enable it or use an explicitly authorized fallback defined by higher HMS/project authority.

Absence of a module is not permission to silently transfer its exclusive responsibility to another advisor.

## Runtime model-switch gate

A skill cannot prove that Codex actually changed model or effort.

- If the runtime exposes supported model/effort control, request the preferred route.
- If the current runtime already satisfies or exceeds the required capability floor and authority permits it, continuing on the stronger route is acceptable.
- If the runtime cannot satisfy a mandatory route, report the exact required model/effort and stop the affected material slice.
- Never claim a switch occurred without observable runtime evidence.

When explicit user action is required, report the exact `/model` route or equivalent control supported by the current Codex runtime.

## Review independence

`Sol / max` is a capability requirement for final review, not evidence of reviewer independence. Architecture/security/critical/final review gates must also satisfy the independent-review module's identity and freshness requirements.

The agent that authored a material candidate must not self-approve merely because it is now using a stronger model.

## Dispatcher algorithm

For each material slice:

1. establish authority and scope;
2. classify the slice by exclusive primary module ownership;
3. classify risk and choose the model/effort floor;
4. apply mandatory escalation rules;
5. verify the primary module is enabled;
6. verify the runtime can satisfy the required model route;
7. list only necessary supporting modules in sequential order;
8. execute without same-artifact concurrent mutation;
9. run the bound evidence/review gate;
10. re-dispatch the next slice instead of assuming the previous route remains valid.

## Fail-closed rule

Unknown task ownership, unknown runtime model identity, unavailable mandatory module, unresolved model-floor conflict, or missing mandatory review evidence is not PASS. Preserve the non-PASS state and report the exact next action.
