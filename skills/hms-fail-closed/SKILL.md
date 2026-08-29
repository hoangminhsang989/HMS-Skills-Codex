---
name: hms-fail-closed
description: Use whenever HMS evidence is missing, contradictory, stale, timed out, canceled, partial, or otherwise insufficient to prove the requested success state.
---

# HMS Fail Closed

Preserve uncertainty instead of converting it into success.

## Non-PASS states

Treat these as distinct from PASS unless fresh authority explicitly resolves them:

`UNKNOWN`, `UNVERIFIED`, `PARTIAL`, `TIMEOUT`, `CANCELED`, `INCONCLUSIVE`, `BLOCKED`, `STOP`, `DEFERRED`, `REJECTED`.

## Required behavior

- State what is proven.
- State what is not proven.
- Identify the exact missing evidence or authority.
- Stop before the first unauthorized or unproven consequential action.
- Define the narrowest next remediation/reconciliation action when authority allows planning it.

Do not retry destructive, privileged, production, or one-shot operations merely because a previous attempt was inconclusive unless retry authority is explicit.
