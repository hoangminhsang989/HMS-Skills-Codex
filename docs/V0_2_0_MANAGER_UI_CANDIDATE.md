# HMS Superpowers v0.2.0 candidate

Candidate scope:

- Windows HMS Superpowers Manager GUI with independent HMS/Superpowers/GPT Taste/Impeccable ON/OFF controls and a combined toggle.
- OFF removes only a validated managed discovery junction; repositories and skill data remain intact.
- CONFLICT state blocks mutation when a path is not the expected managed junction.
- Double-click `.cmd` launcher uses process-local ExecutionPolicy Bypass.
- Manager `-SelfTest` validates junction enable/disable, target preservation, transactional preflight, and conflict fail-closed behavior on Windows PowerShell 5.1.
- `hms-ui-design-authority` adds the generic Penpot/DESIGN.md/design-token/component-mapping visual-authority workflow.
- GPT Taste and Impeccable remain pinned optional design advisors below HMS/Penpot authority.
- CodeGraph v1.6.0 is pinned by exact release commit and Windows asset SHA-256, installed as an HMS-managed local bundle, and registered with Codex MCP through the official `codex mcp add` command using the absolute pinned launcher path.
- `$codegraph-context` binds CodeGraph to the exact checkout/worktree and keeps graph output subordinate to committed source and HMS evidence gates.
- Three-Level Delivery v0.1.4 is pinned to its canonical release commit and exposed through an explicit-only `$three-level-delivery` HMS compatibility adapter.
- Three-Level Delivery remains one-slice governance inside an already-authorized HMS scope; Superpowers remains its technical method layer and CodeGraph remains context/evidence only.
- Existing independent review evidence predating CodeGraph/Three-Level Delivery scope is stale and cannot authorize merge of this expanded candidate.

This document is candidate navigation only. Exact-head CI, delivery-tool runtime qualification, real Codex discovery, and fresh independent review remain the acceptance evidence.
