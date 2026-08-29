---
name: three-level-delivery
description: Use only when the owner explicitly requests Three-Level Delivery for a long-running or multi-agent HMS project; do not auto-activate it for ordinary work, small tasks, or implicit requests.
---

# Three-Level Delivery — Internal HMS Adapter

Inside the unified `$hms-superpowers` bundle this adapter is loaded as an internal module, not invoked as a separate public skill. It preserves compatibility with the canonical `nguyenduytamgithub/three-level-delivery` workflow without silently rewriting it.

## Explicit activation only

Activate only when the owner explicitly requests Three-Level Delivery through the unified HMS workflow. Do not infer activation from project size, duration, agent count, or a generic request to continue work.

## Pin and canonical-source gate

Before any target-repository write, visible Lead creation, or internal delivery role:

1. Read `delivery-tools.lock.json` from the installed HMS Skills Codex source.
2. Require the canonical source clone at `%USERPROFILE%\.codex\three-level-delivery`.
3. Require canonical origin, clean source state, and exact detached HEAD equal to the locked commit.
4. Read `three-level-delivery/SKILL.md` from that exact source and require frontmatter identity, repository, and version to match the lock.
5. Follow the canonical skill's own freshness gate exactly. Any non-PASS state stops execution. Never auto-update the pin; a newer upstream version must first be reviewed and adopted by HMS Skills Codex.

## HMS precedence adaptation

Three-Level Delivery is the delivery controller only inside an already-authorized HMS slice. It cannot supersede owner instruction, the latest valid HMS checkpoint/frozen authority, HMS fail-closed/safety rules, model-routing policy, or project-specific exact scope.

Within those boundaries, preserve the canonical one-slice Owner → read-only Lead → one Writer + one independent read-only Reviewer topology, approval language, durable-state rules, stop gate, and no-automatic-next-slice rule.

When CodeGraph is required, load the internal `references/hms/codegraph-context/MODULE.md`; CodeGraph remains context/evidence only. When Superpowers is enabled, load the relevant engineering-method module under `references/superpowers/` rather than creating a second delivery controller.

## Review reconciliation

Do not create a second reviewer merely because HMS also requires independent review. The single canonical Three-Level Delivery Reviewer must perform the applicable HMS independent-review criteria using the required HMS model/effort. If higher authority truly requires a distinct additional reviewer, the topology conflicts and the slice remains BLOCKED until the owner resolves it.

## Release boundary

Three-Level Delivery approval to implement a slice does not authorize merge, protected-main integration, push, deployment, UAC, service changes, physical-machine execution, or other HMS release-boundary actions. Load the internal HMS release-gate module whenever those actions are separately in scope.

Stop after the canonical slice report and wait for owner acceptance. Never infer or open the next slice.
