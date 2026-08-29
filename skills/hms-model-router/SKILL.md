---
name: hms-model-router
description: Use for non-trivial HMS work when model capability or reasoning effort should be selected according to task risk, including implementation, debugging, architecture, security, release gates, and high-volume mechanical work.
---

# HMS Adaptive Model Router

Classify the task before substantial reasoning or mutation.

## Current HMS routing policy

- `FAST_LOW_RISK / HIGH_VOLUME_MECHANICAL` → `gpt-5.6-luna` at the maximum reasoning effort the runtime exposes for Luna.
- `NORMAL_WORK` → `gpt-5.6-terra`, effort `medium`.
- `MODERATE_DEBUG_OR_IMPLEMENTATION` → `gpt-5.6-terra`, effort `high`.
- `COMPLEX_WORK` → `gpt-5.6-sol`, effort `high`.
- `ARCHITECTURE_SECURITY_MIGRATION` → `gpt-5.6-sol`, effort `xhigh`.
- `CRITICAL_BLOCKER_RELEASE_GATE` → `gpt-5.6-sol`, effort `max`.
- `FINAL_STAGE_REVIEW` → `gpt-5.6-sol`, effort `max`.

Use Luna only at its maximum available reasoning level under the current owner policy; do not intentionally route Luna to a lower effort.

## Runtime limitation

A skill is not proof that the runtime actually changed model or effort. If Codex exposes a supported model/effort control, use it. If not, state the required route and continue only when the current runtime satisfies authority requirements. Never claim a model switch that did not occur.

## Escalation

Escalate when uncertainty, blast radius, trust-boundary impact, release significance, or reviewer independence increases. Cost savings never override a mandatory higher-risk route.
