# HMS Superpowers v0.2.0 candidate

Candidate scope:

- Windows **HMS Unified Skill Manager** with four internal module switches: HMS Core, Superpowers, GPT Taste, and Impeccable.
- Enabled modules are compiled into exactly one public Codex skill: `$hms-superpowers`.
- Source skill entry points are copied as `MODULE.md`, preventing recursive Codex discovery from exposing child skills.
- One-primary-owner routing prevents authority/method/design conflicts:
  - HMS Core owns governance, scope, evidence, review/release, and handoff;
  - Superpowers owns engineering method;
  - GPT Taste owns unresolved visual direction;
  - Impeccable owns UI audit and polish.
- UI collaboration is sequential: authoritative project/HMS design → Taste direction → Impeccable audit/polish → Superpowers implementation → HMS evidence/release.
- Module state is stored in the generated composite `manifest.json`; update preserves existing ON/OFF choices.
- All modules OFF removes only the public composite discovery Junction while retaining managed state/source data.
- Legacy direct discovery Junctions are migrated only after exact Junction-type/target proof; conflict paths fail closed.
- Destructive Junction removal uses quarantine, destructive-boundary revalidation, and rollback.
- Double-click `.cmd` launcher uses process-local ExecutionPolicy Bypass; Manager self-test is qualified on Windows PowerShell 5.1.
- `hms-ui-design-authority` remains an internal HMS authority module preserving Penpot/DESIGN.md/design-token/component-mapping precedence.
- GPT Taste and Impeccable remain exact-pinned advisor sources below owner/HMS/Penpot authority and are intentionally not directly discovered.
- CodeGraph v1.6.0 remains a pinned MCP/tool layer, not another public skill.
- Three-Level Delivery v0.1.4 remains pinned canonical source with an internal explicit-only HMS adapter; it is requested through `$hms-superpowers`, not invoked as a second public skill.
- Real Codex 0.151.0 `skills/list` qualification must show exactly one HMS entry point and reject leakage of HMS child modules, `superpowers:*`, Taste, or Impeccable.
- Existing independent review evidence from earlier multi-skill heads is stale and cannot authorize merge of the unified candidate.

Acceptance evidence must bind the exact final HEAD and include structural validation, Windows lifecycle/PowerShell 5.1 qualification, real Codex discovery, module-state update preservation, safe uninstall, and fresh independent review.
