---
name: hms-independent-review
description: Use after material HMS implementation when architecture, security, trust boundaries, critical blockers, release gates, or final-stage acceptance require a fresh reviewer independent from the implementation claims.
---

# HMS Independent Review

Review the actual candidate and evidence, not the implementer's confidence.

## Independence

The reviewer should receive the governing authority, candidate identity, relevant committed bytes/diff, tests/receipts, and known blockers. Treat the implementation summary as a navigation aid, not proof.

For high-risk gates, route the review through the owner-authorized strongest review model/effort using `hms-model-router`.

## Review questions

- Does the candidate satisfy every mandatory authority clause?
- Is evidence bound to the exact candidate and real producer/runtime?
- Are trust boundaries, mutable inputs, identity chains, races, and failure paths closed?
- Did the change weaken a test/assertion/contract to manufacture PASS?
- Did scope expand?
- Are UNKNOWN or unexercised paths being mislabeled as success?

A new material trust-boundary defect blocks acceptance even if all existing tests pass.

## Output

Return explicit findings with severity, evidence location, and exact blocking rationale. PASS only when mandatory findings are closed and the required evidence is present.
