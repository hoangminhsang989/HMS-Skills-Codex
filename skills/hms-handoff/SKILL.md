---
name: hms-handoff
description: Use after a material HMS checkpoint, verdict, blocker discovery, integration event, or when context must be transferred so another Codex session can continue without losing authority fidelity.
---

# HMS Handoff

Create a durable continuation record after material work.

## Required output

Use the heading:

`TIẾN ĐỘ PHẦN MỀM`

Include, as applicable:

- exact verdict literal;
- completed scope;
- branch/commit/tree/artifact identity;
- tests and runtime evidence;
- blockers and unresolved uncertainty;
- current authority status;
- integration/push/UAC status;
- exact `NEXT_ACTION`;
- actions explicitly not authorized yet.

Then include:

`KHUYẾN NGHỊ CHAT`

State whether the current context is safe to continue or whether a fresh chat/handoff is preferable to preserve authority fidelity.

## Continuation quality

A new session should be able to determine what is proven, what is blocked, and the first allowed action without reconstructing hidden assumptions. Never let an older checkpoint overwrite a newer valid authority during handoff.
