# HMS Skills Codex repository instructions

This repository defines reusable process modules that are compiled into a single public Codex skill. Treat changes as workflow changes that may affect every HMS project using Codex.

## Rules

- Preserve the authority order documented in `docs/AUTHORITY_MODEL.md`.
- Preserve the unified runtime contract documented in `docs/UNIFIED_SKILL_ARCHITECTURE.md`: Codex must expose only one HMS public skill, `$hms-superpowers`.
- Source `skills/*/SKILL.md` files are authoring inputs. When compiled, child entry points become `MODULE.md`; do not add runtime instructions that require invoking child HMS, Superpowers, Taste, Impeccable, CodeGraph-adapter, or Three-Level-adapter skills independently.
- Keep one primary owner per task slice. HMS Core owns governance; Superpowers owns engineering method; GPT Taste owns visual direction; Impeccable owns UI audit/polish.
- Do not weaken fail-closed behavior to make validation pass.
- Do not copy project-specific checkpoints into reusable modules.
- Keep source `SKILL.md` frontmatter limited to valid skill metadata; `name` must equal the containing folder name.
- Descriptions should state triggering conditions, preferably beginning with `Use when...`.
- Prefer references or scripts when a module would otherwise become excessively long.
- Run `pwsh ./scripts/Test-HmsSkills.ps1` before claiming a source/module change is valid.
- Material workflow changes require an isolated branch, exact-head verification, and independent review before merge.
- Do not silently change the owner-selected adaptive model-routing policy.
- Never expose pinned external source repositories directly through `.agents/skills`; source reconciliation and public discovery are separate operations.

## Upstream relationship

HMS Skills Codex is an overlay on upstream Superpowers. Do not fork or rewrite upstream Superpowers unless future authority explicitly requires it. HMS compiles the reviewed/pinned upstream skills as internal engineering-method references, and HMS rules may narrow or gate those methods when higher authority requires it.
