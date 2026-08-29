# HMS Skills Codex repository instructions

This repository defines reusable process skills. Treat changes as workflow changes that may affect every HMS project using Codex.

## Rules

- Preserve the authority order documented in `docs/AUTHORITY_MODEL.md`.
- Do not weaken fail-closed behavior to make a validation scenario pass.
- Do not copy project-specific checkpoints into reusable skills.
- Keep `SKILL.md` frontmatter limited to valid skill metadata; `name` must equal the containing folder name.
- Descriptions should state triggering conditions, preferably beginning with `Use when...`.
- Prefer references or scripts when a skill would otherwise become excessively long.
- Run `pwsh ./scripts/Test-HmsSkills.ps1` before claiming a skill-set change is valid.
- For material workflow changes, use an isolated branch and independent review before merge.
- Do not silently change the owner-selected adaptive model-routing policy.

## Upstream relationship

HMS Skills Codex is an overlay on upstream Superpowers. Do not vendor or rewrite upstream Superpowers unless a future authority explicitly requires a fork. HMS rules may narrow or gate an upstream workflow when HMS authority requires it.
