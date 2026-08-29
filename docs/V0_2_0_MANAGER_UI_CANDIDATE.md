# HMS Superpowers v0.2.0 candidate

Candidate scope:

- Windows HMS Superpowers Manager GUI with independent HMS/Superpowers ON/OFF controls and a combined toggle.
- OFF removes only a validated managed discovery junction; repositories and skill data remain intact.
- CONFLICT state blocks mutation when a path is not the expected managed junction.
- Double-click `.cmd` launcher uses process-local ExecutionPolicy Bypass.
- Manager `-SelfTest` validates junction enable/disable, target preservation, and conflict fail-closed behavior on Windows.
- `hms-ui-design-authority` adds the generic Penpot/DESIGN.md/design-token/component-mapping visual-authority workflow.

This document is candidate navigation only. CI and independent review remain the acceptance evidence.
