---
name: hms-release-gate
description: Use before HMS merge, protected-main integration, remote push, deployment, production adoption, release tagging, or any checkpoint that promotes a candidate into authoritative delivered state.
---

# HMS Release Gate

Promotion is a separate gate from implementation.

## Required checks

Apply the checks required by current authority, commonly:

1. candidate identity is frozen/known;
2. working tree and diff are reconciled;
3. targeted verification PASS;
4. required broad regression PASS;
5. required runtime/physical-machine evidence PASS;
6. independent review PASS;
7. no unresolved blocking findings;
8. integration target identity is current;
9. protected/owner-dirty state will not be overwritten;
10. post-integration identity and remote state are verified.

Never infer push/deployment permission from implementation permission.

## Privilege and one-shot actions

UAC, ACL, service installation, machine-state mutation, or one-shot production actions require their own explicit authority. Cancellation or timeout remains non-PASS.

## Result

Produce an exact PASS/BLOCKED/STOP verdict tied to candidate and destination identity. If promotion is not authorized, keep the verified candidate staged without promoting it.
