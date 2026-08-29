---
name: three-level-delivery
description: Use only when the owner explicitly invokes Three-Level Delivery for a long-running or multi-agent HMS project; do not auto-activate it for ordinary work, small tasks, or implicit requests.
---

# Three-Level Delivery — HMS Adapter

This skill is an HMS compatibility adapter for the canonical `nguyenduytamgithub/three-level-delivery` workflow. It does not fork or silently rewrite the upstream delivery method.

## Explicit activation only

Activate only when the owner explicitly invokes `$three-level-delivery`. Do not infer activation from project size, duration, agent count, or a generic request to continue work.

## Pin and canonical-source gate

Before any target-repository write, visible Lead creation, or internal delivery role:

1. Read `delivery-tools.lock.json` from the installed HMS Skills Codex source.
2. Require the canonical source clone at `%USERPROFILE%\.codex\three-level-delivery`.
3. Require origin `https://github.com/nguyenduytamgithub/three-level-delivery.git`, clean source state, and exact detached HEAD equal to the locked commit.
4. Read `three-level-delivery/SKILL.md` from that exact source and require its frontmatter identity, repository, and version to match the lock.
5. Follow the canonical skill's own freshness gate exactly. If it reports `UPDATE_REQUIRED`, `VERSION_CHECK_UNAVAILABLE`, `FAIL`, `UNKNOWN`, or another non-PASS state, stop. Never auto-update the pin; a newer upstream version must first be reviewed and adopted by an HMS Skills Codex change.

## HMS precedence adaptation

The canonical Three-Level Delivery method is the delivery controller **inside the already-authorized HMS slice**. It cannot supersede:

1. owner instruction;
2. latest valid HMS checkpoint/frozen authority;
3. HMS fail-closed and safety rules;
4. HMS model-routing policy; or
5. HMS project-specific authority and exact scope.

Within those boundaries, preserve the canonical one-slice Owner → read-only Lead → one Writer + one independent read-only Reviewer topology, its approval language, durable-state rules, stop gate, and no-automatic-next-slice rule.

Use `$codegraph-context` for the canonical CodeGraph writable-checkout gate. CodeGraph remains context/evidence only. Use upstream Superpowers as the technical method layer inside the approved slice.

## Review reconciliation

Do not create a second reviewer merely because HMS also requires independent review. The single canonical Three-Level Delivery Reviewer must perform the applicable HMS independent-review criteria and use the required HMS model/effort for that review. If a higher authority truly requires a distinct additional reviewer, the topology conflicts and the slice remains BLOCKED until the owner resolves it.

## Release boundary

Three-Level Delivery approval to implement a slice does not itself authorize merge, protected-main integration, push, deployment, UAC, service changes, physical-machine execution, or other HMS release-boundary actions. Apply `$hms-release-gate` whenever those actions are separately in scope.

Stop after the canonical slice report and wait for owner acceptance. Never infer or open the next slice.
