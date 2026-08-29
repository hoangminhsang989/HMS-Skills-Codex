# HMS Skills Codex

Reusable HMS workflow skills for OpenAI Codex.

HMS Skills Codex exposes exactly **one public Codex skill**:

```text
$hms-superpowers
```

The Manager selects which internal modules are compiled into that one skill. Source repositories remain separate and exact-pinned for review, update, and supply-chain control, but Codex does not discover them as competing public skills.

## Unified module model

| Module | Primary responsibility | Mô tả tiếng Việt |
| --- | --- | --- |
| HMS Core | Authority, scope, model routing, evidence, review/release, handoff | Quản lý quyền hạn, phạm vi, bằng chứng, review/release và bàn giao; là lớp quản trị và phân xử cuối cùng. |
| Superpowers | Engineering method: planning, worktrees, debugging, TDD, implementation | Phương pháp kỹ thuật để lập kế hoạch, debug, TDD, worktree và triển khai; không tự mở rộng authority hoặc scope. |
| GPT Taste | Visual direction and aesthetic critique | Định hướng thẩm mỹ, bố cục và phê bình hình ảnh khi design authority còn phần chưa chốt. |
| Impeccable | UI audit, consistency, accessibility, final polish | Kiểm tra và hoàn thiện UI về tính nhất quán, kiểu chữ, khoảng cách, khả năng truy cập và polish cuối. |

Every task slice has exactly one primary owner. Supporting modules may advise, but they must not independently redefine the same decision or mutate the same artifact concurrently.

For UI work with all relevant modules enabled:

```text
project/HMS UI authority
        ↓
GPT Taste direction
        ↓
Impeccable audit/polish
        ↓
Superpowers implementation
        ↓
HMS evidence/release
```

Taste owns direction; Impeccable owns audit/polish inside the accepted direction. Neither can override owner instruction, frozen HMS authority, Penpot, `DESIGN.md`, design tokens, or component mapping.

## Install on Windows

```powershell
git clone https://github.com/hoangminhsang989/HMS-Skills-Codex.git "$env:USERPROFILE\.codex\hms-skills-codex"
cd "$env:USERPROFILE\.codex\hms-skills-codex"
.\install.ps1
```

The installer reconciles pinned sources and compiles the generated bundle at:

```text
%USERPROFILE%\.codex\hms-composite\hms-superpowers
```

Codex discovery is exposed only at:

```text
%USERPROFILE%\.agents\skills\hms-superpowers
```

Enabled source skills are copied into the composite as internal references. Every copied `SKILL.md` becomes `MODULE.md`, so the generated bundle contains exactly one public `SKILL.md`.

The installer also provisions the delivery-intelligence layer:

- pinned Superpowers source → `%USERPROFILE%\.codex\superpowers`
- pinned GPT Taste source → `%USERPROFILE%\.codex\taste-skill`
- pinned Impeccable source → `%USERPROFILE%\.codex\impeccable`
- pinned CodeGraph bundle → `%USERPROFILE%\.codex\codegraph\current`
- Codex MCP server `codegraph` → registered through the official Codex CLI and bound to the HMS-managed binary
- pinned canonical Three-Level Delivery source → `%USERPROFILE%\.codex\three-level-delivery`

CodeGraph remains an MCP/tool layer, not another public skill. Three-Level Delivery remains an internal HMS adapter/module path rather than a competing public entry point.

HMS does **not** track mutable upstream `main`. Superpowers is locked by `superpowers.lock.json`; GPT Taste and Impeccable are locked by `ui-skills.lock.json`; CodeGraph and Three-Level Delivery are locked by `delivery-tools.lock.json`. Changing any pin is a material workflow change and should go through a reviewed HMS Skills Codex commit/PR.

Use `-SkipSuperpowers`, `-SkipTaste`, `-SkipImpeccable`, `-SkipCodeGraph`, or `-SkipThreeLevelDelivery` only when that dependency is intentionally managed elsewhere.

Restart Codex after the first installation so skill and MCP discovery refresh.

## HMS Unified Skill Manager

Double-click either launcher:

```text
HMS-Skills-Manager.cmd
HMS-Superpowers-Manager.cmd
```

The Manager exposes four module switches:

- HMS Core
- Superpowers
- GPT Taste
- Impeccable

Each row shows the technical role in English plus a **Vietnamese description** explaining what the module does.

The switches do not expose four separate Codex skills. They select which modules are compiled into `$hms-superpowers`.

The Manager also provides **Enable All / Disable All**, Apply + Rebuild, Validate, and conflict-safe lifecycle behavior. OFF removes a module from the next composite build; it does not delete the pinned source repository. With every module OFF, the manifest/state is preserved but the public `$hms-superpowers` discovery junction is removed.

Unexpected folders, files, symlinks, reparse points, or junction targets fail closed. The Manager will not silently replace or remove an unowned path.

The launcher uses process-local `ExecutionPolicy Bypass`, so it does not permanently weaken the machine execution policy.

Manager runtime self-test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manager\HmsSuperpowersManager.ps1 -SelfTest
```

The self-test validates all-ON, one-module-OFF, all-OFF, the one-public-SKILL invariant, exclusive role routing, and presence of Vietnamese module descriptions under Windows PowerShell 5.1.

## Delivery intelligence

### CodeGraph

CodeGraph is structural repository intelligence, not authority. HMS binds it to the exact checkout/worktree, rejects cross-worktree index reuse, and keeps graph results subordinate to source/Git/runtime evidence.

The installer refuses to overwrite a pre-existing Codex MCP server named `codegraph` when it points to a different command.

Per-project `.codegraph/` data is local tooling state. Prefer `.git/info/exclude` for local ignore state; do not modify a tracked `.gitignore` merely to hide CodeGraph unless that file is explicitly in scope.

### Three-Level Delivery

Three-Level Delivery remains explicit governance inside an already-authorized HMS slice. Its exact upstream source is pinned, and the HMS adapter preserves its one-slice Owner → read-only Lead → one Writer + one independent Reviewer topology.

It does not replace HMS authority or release authorization. Merge, push, deployment, UAC, service changes, physical-machine execution, and other HMS release boundaries remain subject to the current HMS authority and release gate.

## UI advisor rule

GPT Taste and Impeccable are optional internal design-advisor modules, not HMS authority.

Their generic rules about fonts, AIDA, motion, spacing, layout, redesign, or framework choices do not override owner instruction, frozen product/UI definitions, Penpot, `DESIGN.md`, tokens/component mapping, platform requirements, or behavior outside the authorized scope.

This matters especially for engineering desktop software: web/marketing conventions from a generic design skill must not be imported into a desktop CAD/CAM or operations UI merely because the advisor prefers them.

## Use

Normal use requires only one invocation:

```text
$hms-superpowers
Continue the current project from the latest valid authority.
```

Examples of internal routing through the same entry point:

```text
$hms-superpowers
Use Three-Level Delivery for this owner-approved slice.
```

```text
$hms-superpowers
Use CodeGraph for focused structural context before implementing this change.
```

```text
$hms-superpowers
Implement the authorized UI change, use the enabled design advisors where appropriate, and verify it visually before PASS.
```

Users do not need to remember or directly invoke HMS child skills, Superpowers namespace skills, GPT Taste, or Impeccable. The composite dispatcher assigns one primary module owner for each task slice and loads only the required internal `MODULE.md` references.

## Update

```powershell
& "$env:USERPROFILE\.codex\hms-skills-codex\update.ps1"
```

Update reconciles pinned sources and rebuilds the composite while preserving existing Manager ON/OFF choices.

## Uninstall

Normal uninstall removes the verified composite discovery junction while preserving pinned sources and composite state. Optional flags can remove verified managed dependencies or clones, but destructive operations fail closed if ownership cannot be proven.

## Validate

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
pwsh ./scripts/Test-DeliveryTools.ps1
```

GitHub Actions runs source validation plus the Windows exact-SHA install/update/Manager/real-Codex-discovery/uninstall lifecycle. Real discovery must expose `hms-superpowers` as the only HMS public entry point.

## Status

Current candidate version: **0.2.0**.

See `docs/AUTHORITY_MODEL.md` and `docs/UNIFIED_SKILL_ARCHITECTURE.md` for the authority and unified-dispatch contracts.
