---
name: hms-authority-gate
description: Use before a material HMS mutation, remediation, integration, push, release, privilege boundary action, or any step whose permission depends on the current checkpoint or frozen authority.
---

# HMS Authority Gate

Prove that the requested action is authorized before performing it.

## Gate

For the proposed action, identify:

1. the authority that permits it;
2. the exact files/components/trust boundary in scope;
3. prerequisites that must already be PASS;
4. prohibited adjacent actions;
5. required post-action verification.

If authority only permits preparation, do not execute the prepared action. If authority permits review but not mutation, stay read-only. If authority permits a candidate but not integration, do not merge or push it as production authority.

## Stop conditions

Return a fail-closed STOP/BLOCKED state when:

- the required authority is missing or ambiguous;
- current identity differs materially from the authority baseline;
- an unresolved blocker invalidates the requested action;
- the action would expand scope;
- a required privilege/UAC/physical-machine step has not been explicitly authorized.

Do not turn convenience, apparent intent, or a previous similar action into permission.
