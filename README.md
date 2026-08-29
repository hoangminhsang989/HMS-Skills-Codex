# HMS Skills Codex

Reusable HMS workflow skills for OpenAI Codex.

HMS Skills Codex is an **overlay**, not a fork of Superpowers. It keeps upstream Superpowers available for planning, debugging, worktrees, TDD, review, and verification while adding HMS authority control, fail-closed gates, scope locking, evidence requirements, model routing, UI design authority, CodeGraph repository intelligence, optional Three-Level Delivery governance, and checkpoint handoff.

## Authority order

1. Owner instruction
2. Latest valid HMS checkpoint / frozen authority
3. HMS fail-closed and safety rules
4. HMS adaptive model routing
5. HMS project-specific authority/skills, including `$hms-ui-design-authority`
6. Explicitly invoked `$three-level-delivery` governance inside the already-authorized HMS slice
7. Upstream Superpowers as technical method
8. Derived/advisory helpers: `$codegraph-context`, GPT Taste, and Impeccable
9. Codex defaults

A lower layer must never silently override a higher layer. CodeGraph is context/evidence, not authority. Three-Level Delivery activates only when the owner explicitly invokes it.

For material UI work, `$hms-ui-design-authority` applies inside the already-authorized project scope. When Penpot is the declared visual authority, the expected chain is approved HMS UI definition → Penpot → `DESIGN.md` → design tokens/component mapping → production UI → fresh visual/runtime evidence. GPT Taste and Impeccable may improve craft only where that chain leaves a choice unresolved.

## Install on Windows

```powershell
git clone https://github.com/hoangminhsang989/HMS-Skills-Codex.git "$env:USERPROFILE\.codex\hms-skills-codex"
cd "$env:USERPROFILE\.codex\hms-skills-codex"
.\install.ps1
```

The installer exposes these user-level Codex skills through `%USERPROFILE%\.agents\skills`:

- HMS skills → `%USERPROFILE%\.codex\hms-skills-codex\skills`
- pinned Superpowers → `%USERPROFILE%\.codex\superpowers\skills`
- pinned GPT Taste → `%USERPROFILE%\.codex\taste-skill\skills\gpt-tasteskill`
- pinned Impeccable → `%USERPROFILE%\.codex\impeccable\.agents\skills\impeccable`

It also provisions the delivery-intelligence layer:

- pinned CodeGraph v1.6.0 bundle → `%USERPROFILE%\.codex\codegraph\current`
- Codex MCP server `codegraph` → registered through the official `codex mcp add` command and bound to the absolute HMS-managed launcher path
- pinned canonical Three-Level Delivery v0.1.4 source → `%USERPROFILE%\.codex\three-level-delivery`
- `$codegraph-context` and `$three-level-delivery` → HMS adapter skills discovered with the normal HMS skill junction

HMS does **not** track mutable upstream `main`. Superpowers is locked by `superpowers.lock.json`; GPT Taste and Impeccable are locked by `ui-skills.lock.json`; CodeGraph and Three-Level Delivery are locked by `delivery-tools.lock.json`. CodeGraph additionally locks the exact Windows release-asset SHA-256 before extraction. Changing any pin is a material workflow change and should go through a reviewed HMS Skills Codex commit/PR.

Use `-SkipSuperpowers`, `-SkipTaste`, `-SkipImpeccable`, `-SkipCodeGraph`, or `-SkipThreeLevelDelivery` only when that dependency is intentionally managed elsewhere. CodeGraph integration requires the `codex` CLI command because HMS registers its MCP server through the official Codex MCP command surface.

Restart Codex after the first installation so skill and MCP discovery refresh.

## HMS Skills Manager

Windows users can enable or disable skill discovery through the GUI instead of editing junctions manually.

Double-click either launcher:

```text
HMS-Skills-Manager.cmd
HMS-Superpowers-Manager.cmd
```

The Manager exposes four independent ON/OFF controls:

- HMS Superpowers
- Upstream Superpowers
- GPT Taste
- Impeccable

It also provides **BẬT TẤT CẢ / TẮT TẤT CẢ**, Refresh, Validate, and conflict status.

OFF removes only the validated discovery junction. It does **not** delete repositories or skill data. If a discovery path is occupied by an unrelated folder, file, or different reparse target, the Manager reports `CONFLICT` and refuses to replace or remove it.

CodeGraph is deliberately **not** represented as a junction toggle: it is a Codex MCP registration, not a skill folder. The Three-Level Delivery adapter is part of the HMS skill set and therefore follows the HMS ON/OFF state. This keeps the Manager from pretending unlike mechanisms have identical lifecycle semantics.

The launcher uses process-local `ExecutionPolicy Bypass`, so it does not permanently weaken the machine execution policy. Restart or refresh Codex after changing discovery state.

Manager runtime self-test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manager\HmsSuperpowersManager.ps1 -SelfTest
```

## Delivery intelligence

### CodeGraph

`$codegraph-context` is the HMS compatibility layer for `colbymchenry/codegraph`. It ensures/synchronizes the graph for the **exact writable checkout**, rejects cross-worktree index reuse, and keeps graph results subordinate to source/Git/runtime evidence.

The installer refuses to overwrite a pre-existing Codex MCP server named `codegraph` when it points to a different command. HMS does not silently seize an existing user configuration.

Per-project `.codegraph/` data is local tooling state. Prefer `.git/info/exclude` for local ignore state; do not modify a tracked `.gitignore` merely to hide CodeGraph unless that file is explicitly in scope.

### Three-Level Delivery

Invoke explicitly:

```text
$three-level-delivery
```

The HMS adapter first verifies the pinned canonical source and then follows the upstream skill's own freshness gate. It never auto-updates the pin. If upstream has moved to a newer canonical version, execution stops as update-required until that new version is reviewed and adopted by HMS Skills Codex.

Inside an approved HMS slice, preserve the canonical one-slice Owner → read-only Lead → one Writer + one independent Reviewer model. CodeGraph provides context/evidence, Superpowers provides technical method, and Three-Level Delivery stops at the Owner gate. HMS release authorization remains separate.

## UI advisor rule

`gpt-taste` and `impeccable` are the upstream skill names, but Codex namespace-qualifies these external repositories. The qualified discovery/invocation identities are pinned in `ui-skills.lock.json` and currently are:

```text
$taste-skill:gpt-taste
$impeccable:impeccable
```

They are optional design advisors, not HMS authority. Their generic rules about fonts, AIDA, motion, spacing, layout, redesign, or framework choices do not override owner instruction, frozen product/UI definitions, Penpot, `DESIGN.md`, tokens/component mapping, platform requirements, or behavior outside the authorized scope.

This matters especially for engineering desktop software: web/marketing conventions from a generic design skill must not be imported into a desktop CAD/CAM or operations UI merely because the advisor prefers them.

## Use

```text
$hms-superpowers
Continue the current project from the latest valid authority.
```

For explicit Three-Level Delivery:

```text
$three-level-delivery
Continue one owner-approved slice under the current HMS authority.
```

For CodeGraph-bound structural discovery:

```text
$codegraph-context
Synchronize the exact checkout and give me focused structural context for this change.
```

For UI-specific work:

```text
$hms-ui-design-authority
Implement the authorized UI change from the canonical project design and verify it visually before PASS.
```

Optional advisor invocation:

```text
$taste-skill:gpt-taste
$impeccable:impeccable
```

Codex may activate ordinary HMS skills automatically when the task matches their descriptions. `$three-level-delivery` is the exception: its adapter explicitly forbids implicit activation.

## Core HMS skills

- `hms-superpowers` — orchestration entry point
- `hms-authority-loader` — recover the newest valid project authority
- `hms-authority-gate` — prove a requested mutation is authorized
- `hms-scope-lock` — prevent unauthorized scope expansion
- `hms-model-router` — classify work and request the appropriate HMS model tier
- `hms-isolated-execution` — isolate material mutations in Git
- `hms-evidence-gate` — require fresh verification evidence
- `hms-independent-review` — separate implementation claims from review
- `hms-fail-closed` — preserve UNKNOWN/BLOCKED states instead of guessing PASS
- `hms-release-gate` — gate integration, push, and release
- `hms-handoff` — produce durable HMS checkpoint output
- `hms-ui-design-authority` — preserve Penpot/DESIGN.md/tokens/component mapping and require production visual evidence
- `codegraph-context` — bind pinned CodeGraph context to the exact checkout
- `three-level-delivery` — explicit-only adapter to the pinned canonical Three-Level Delivery workflow

## Update

```powershell
& "$env:USERPROFILE\.codex\hms-skills-codex\update.ps1"
```

This fast-forwards HMS Skills Codex and reconciles pinned dependencies. When GPT Taste or Impeccable already exists locally, update preserves the Manager's current ON/OFF discovery choice. When CodeGraph is already installed but its MCP registration has been explicitly removed, update preserves that OFF state; a newly introduced managed CodeGraph installation is registered once so it is immediately usable.

## Uninstall

Normal uninstall removes only the HMS discovery junction. Add `-IncludeSuperpowers`, `-IncludeUiSkills`, or `-IncludeDeliveryTools` only for the corresponding managed layers. `-IncludeDeliveryTools` removes only an exactly verified HMS-managed CodeGraph MCP entry; it refuses to remove a conflicting entry. Add `-RemoveClones` only when you also want verified managed source/bundle directories removed. Project `.codegraph/` indexes are deliberately left alone.

## Validate

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
pwsh ./scripts/Test-DeliveryTools.ps1
```

The validators check HMS skill metadata, PowerShell syntax, exact dependency pins, CodeGraph release digests, Three-Level Delivery source identity, and namespace-qualified external discovery contracts. GitHub Actions runs structural validation plus Windows install/update/Manager-self-test/real-Codex-discovery contracts. The expanded CodeGraph/Three-Level Delivery candidate must also pass its exact-head delivery-tool runtime job before merge.

## Status

Current candidate version: **0.2.0**.

See `docs/AUTHORITY_MODEL.md` for the authority/design contract.
