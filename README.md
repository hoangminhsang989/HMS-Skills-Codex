# HMS Skills Codex

Reusable HMS workflow modules compiled into **one public OpenAI Codex skill**.

The user-facing contract is intentionally simple:

```text
$hms-superpowers
```

HMS Core, upstream Superpowers, GPT Taste, and Impeccable remain separate reviewed/pinned source modules, but the Manager compiles whichever work modules are ON into one generated `$hms-superpowers` bundle. The dedicated `hms-model-dispatcher` is a separate internal source skill that is always embedded when the public skill is exposed. Codex does not discover these sources as separate public skills.

## Why one skill

Multiple independently discovered workflow/design skills can compete for triggers, authority, or implementation ownership. HMS avoids that by enforcing **one public entry point + one primary work owner per task slice + one dedicated model dispatcher**.

| Module | Primary responsibility | Must not own |
| --- | --- | --- |
| HMS Core | authority, checkpoint, scope, model-floor escalation, evidence, independent-review criteria, release, handoff | final enabled-model assignment, engineering-method details, visual taste |
| Superpowers | planning, worktrees, debugging, TDD, implementation/review method | HMS authority, scope expansion, release permission, visual authority |
| GPT Taste | visual direction, composition, hierarchy, aesthetic critique | production mutation, release, final UI audit |
| Impeccable | UI audit/polish, consistency, typography, spacing, accessibility, interaction refinement | frozen product/design authority or independent competing redesign |
| HMS Model Dispatcher | choose an enabled GPT-5.6 model that satisfies the required capability floor | product authority, engineering ownership, UI design ownership, lowering a mandatory model floor |

### Mô tả tiếng Việt

- **HMS Core** — Quản lý quyền hạn, phạm vi, bằng chứng, review/release và bàn giao; là lớp quản trị và phân xử cuối cùng.
- **Superpowers** — Phương pháp kỹ thuật để lập kế hoạch, debug, TDD, worktree và triển khai; không tự mở rộng authority hoặc scope.
- **GPT Taste** — Định hướng thẩm mỹ, bố cục và phê bình hình ảnh khi design authority còn phần chưa chốt.
- **Impeccable** — Kiểm tra và hoàn thiện UI về tính nhất quán, kiểu chữ, khoảng cách, khả năng truy cập và polish cuối.
- **HMS Model Dispatcher** — Nhận mức năng lực model bắt buộc rồi chọn model đang bật phù hợp; chỉ fallback sang model mạnh hơn, không hạ chuẩn để chạy tiếp.

For UI work with all relevant modules enabled, the sequence is:

**owner/project/HMS UI authority → GPT Taste direction → Impeccable audit/polish → Superpowers implementation → HMS evidence/release gates**.

Taste and Impeccable are not asked to independently redesign the same artifact. Taste owns direction; Impeccable owns audit/polish inside the accepted direction.

See `docs/UNIFIED_SKILL_ARCHITECTURE.md` for the full routing contract.

## Authority order

1. Owner instruction
2. Latest valid HMS checkpoint / frozen authority
3. HMS fail-closed and safety rules
4. HMS model-risk floor + dedicated model-dispatcher contract
5. HMS project-specific product/UI authority
6. Explicit Three-Level Delivery governance when the owner requests that mode for the current HMS slice
7. Enabled Superpowers engineering method
8. Enabled derived/advisory modules such as CodeGraph context, GPT Taste, and Impeccable
9. Codex defaults

A lower layer never silently overrides a higher one. CodeGraph is context/evidence, not authority.

For material UI work, when Penpot is declared canonical visual authority, the expected chain is approved HMS UI definition → Penpot → `DESIGN.md` → design tokens/component mapping → production UI → fresh visual/runtime evidence. Taste and Impeccable operate only where that chain leaves discretion.

## Install on Windows

```powershell
git clone https://github.com/hoangminhsang989/HMS-Skills-Codex.git "$env:USERPROFILE\.codex\hms-skills-codex"
cd "$env:USERPROFILE\.codex\hms-skills-codex"
.\install.ps1
```

The installer keeps reviewed source dependencies separately:

- HMS source → `%USERPROFILE%\.codex\hms-skills-codex`
- pinned Superpowers source → `%USERPROFILE%\.codex\superpowers`
- pinned GPT Taste source → `%USERPROFILE%\.codex\taste-skill`
- pinned Impeccable source → `%USERPROFILE%\.codex\impeccable`
- pinned Three-Level Delivery canonical source → `%USERPROFILE%\.codex\three-level-delivery`
- pinned CodeGraph bundle → `%USERPROFILE%\.codex\codegraph\current`

It then generates:

```text
%USERPROFILE%\.codex\hms-composite\hms-superpowers
```

and exposes only:

```text
%USERPROFILE%\.agents\skills\hms-superpowers
```

All copied internal `SKILL.md` entry files are renamed to `MODULE.md`, leaving exactly one public `SKILL.md` at the composite root. The compiler separately embeds the dedicated model dispatcher plus its deterministic resolver under `references/model-dispatcher/`.

HMS does **not** track mutable upstream `main`. Superpowers is locked by `superpowers.lock.json`; GPT Taste and Impeccable are locked by `ui-skills.lock.json`; CodeGraph and Three-Level Delivery are locked by `delivery-tools.lock.json`. CodeGraph additionally locks exact Windows release-asset SHA-256 before extraction.

Use `-SkipSuperpowers`, `-SkipTaste`, `-SkipImpeccable`, `-SkipCodeGraph`, or `-SkipThreeLevelDelivery` only when intentionally omitting/managing that source elsewhere. Restart Codex after first installation.

## HMS Unified Skill Manager

Double-click either compatible launcher:

```text
HMS-Skills-Manager.cmd
HMS-Superpowers-Manager.cmd
```

The Manager controls four **internal work-module switches**:

- HMS Core
- Superpowers
- GPT Taste
- Impeccable

Each Manager row keeps the technical role in English and shows the corresponding **Vietnamese description** directly underneath it.

`Apply + Rebuild` recompiles the single public `$hms-superpowers` skill from the current selection. `Enable All` and `Disable All` apply the complete work-module selection atomically through the composite compiler.

Turning a work module OFF does not delete its source repository. It removes that module from the generated bundle. When all four work modules are OFF, the managed bundle/manifest remains for state and audit, while `%USERPROFILE%\.agents\skills\hms-superpowers` is absent, so no HMS public skill is exposed.

Work-module state is stored in the generated `manifest.json`, making the Manager display and actual compiled bundle share one source of truth. `update.ps1` preserves these ON/OFF choices.

Legacy direct discovery paths (`hms`, `superpowers`, `gpt-taste`, `impeccable`) are migrated only after exact Junction type and target verification. Unexpected files, directories, symlinks, or reparse points are conflicts and are never overwritten or removed silently. Destructive Junction removal uses quarantine + boundary revalidation + rollback.

The launcher uses process-local `ExecutionPolicy Bypass`; it does not permanently weaken the machine execution policy.

Manager runtime self-test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manager\HmsSuperpowersManager.ps1 -SelfTest
```

The self-test validates all-ON, one-module-OFF, all-OFF, exactly-one-public-SKILL, no legacy discovery leakage, required Vietnamese module descriptions, and Windows PowerShell 5.1 compatibility.

## HMS Model Settings

Model availability is configured separately from work-module availability.

Double-click:

```text
HMS-Model-Settings.cmd
```

The popup controls:

- **GPT-5.6 Luna** — ON/OFF
- **GPT-5.6 Terra** — ON/OFF
- **GPT-5.6 Sol** — ON/OFF

It stores the local model pool at:

```text
%USERPROFILE%\.codex\hms-composite\model-settings.json
```

Model settings do not require rebuilding public skill discovery. The dedicated dispatcher reads them before each material model-routed task slice.

### Phân công model

| Model | Nhiệm vụ chính |
| --- | --- |
| **Luna** | Việc cơ học, lặp lại, deterministic, read-only/housekeeping hoặc chỉnh sửa rất hẹp; luôn dùng mức reasoning cao nhất Luna mà runtime hỗ trợ. |
| **Terra** | Công việc bình thường, implementation và debug; medium cho normal work, high cho non-trivial implementation/debug. |
| **Sol** | Công việc phức tạp, architecture/security/migration, blocker/release và final review; dùng high/xhigh/max theo risk floor. |

Safe reassignment is **upward-only**:

```text
Luna OFF  -> Terra -> Sol
Terra OFF -> Sol
Sol OFF + Sol-required task -> BLOCKED
All models OFF -> BLOCKED
```

So a disabled preferred model does not automatically stop low-risk work when a stronger enabled model can inherit it. But the system never moves Sol-required architecture/security/release work down to Terra merely to continue.

The deterministic resolver is:

```powershell
.\scripts\Resolve-HmsModelRoute.ps1 -RiskClass 'NORMAL_WORK'
```

Model Settings self-test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manager\HmsModelSettings.ps1 -SelfTest
```

This verifies Luna→Terra fallback, Terra→Sol fallback, Sol-required fail-closed behavior, all-OFF blocking, settings persistence, Vietnamese descriptions, and Windows PowerShell 5.1 compatibility.

Model ON/OFF policy is not proof that Codex actually switched models. When the assigned route is not already active, HMS must use a supported runtime model/effort control or report the exact required `/model` action. Never claim a switch without observable runtime evidence.

## Delivery intelligence

### CodeGraph

CodeGraph is an MCP/tool layer, **not another public skill**. The HMS-managed binary is pinned and its MCP registration is created through the official Codex CLI. The internal CodeGraph adapter binds graph context to the exact checkout/worktree and keeps graph output subordinate to committed source and HMS evidence gates.

The installer refuses to overwrite a pre-existing MCP server named `codegraph` when it points to a different command.

### Three-Level Delivery

Three-Level Delivery is an internal explicit-only HMS adapter in the composite. To use it, ask through the one public entry point, for example:

```text
$hms-superpowers
Use Three-Level Delivery for this owner-approved slice.
```

The adapter verifies the pinned canonical source and follows its freshness gate. It never auto-updates the pin. Three-Level Delivery remains one-slice governance inside already-authorized HMS scope; Superpowers remains engineering method and CodeGraph remains context/evidence.

## UI advisors

GPT Taste and Impeccable source repositories have namespace-qualified Codex identities recorded in `ui-skills.lock.json`. Those identities are retained for source qualification and for tests that ensure **direct discovery does not leak**. They are not the normal runtime invocation contract.

Use only:

```text
$hms-superpowers
```

The dispatcher routes unresolved visual direction to Taste and UI audit/polish to Impeccable according to the role matrix. Neither can override owner instruction, frozen product/UI definitions, Penpot, `DESIGN.md`, tokens/component mapping, platform requirements, or behavior outside scope.

## Use

Normal continuation:

```text
$hms-superpowers
Continue the current project from the latest valid authority.
```

UI work:

```text
$hms-superpowers
Implement the authorized UI change from the canonical project design and verify it visually before PASS.
```

Three-Level Delivery:

```text
$hms-superpowers
Use Three-Level Delivery for one owner-approved slice under the current authority.
```

You do not invoke HMS child gates, Superpowers source skills, Taste, Impeccable, the Model Dispatcher, CodeGraph adapter, or Three-Level adapter as separate public skills. The unified dispatcher loads only the internal modules needed for the current task.

## Update

```powershell
& "$env:USERPROFILE\.codex\hms-skills-codex\update.ps1"
```

Update reconciles exact pinned sources and rebuilds the composite from the current work-module manifest state. It does not silently turn an OFF work module back ON and it preserves `model-settings.json` model choices.

## Uninstall

Normal uninstall removes the verified composite discovery Junction and preserves source repositories, composite state, and model settings. Add `-IncludeSuperpowers`, `-IncludeUiSkills`, or `-IncludeDeliveryTools` for those managed source/tool layers. Add `-RemoveClones` only when verified managed source/bundle directories should also be deleted.

## Validate

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
pwsh ./scripts/Test-DeliveryTools.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manager\HmsModelSettings.ps1 -SelfTest
```

GitHub Actions additionally installs the exact candidate on Windows, qualifies both Manager UIs on Windows PowerShell 5.1, proves model fallback/reassignment and update persistence, exercises work-module rebuild/update/uninstall behavior, starts real Codex app-server `skills/list`, and fails if any HMS child module, `superpowers:*`, GPT Taste, Impeccable, or model-dispatcher source leaks into public discovery.

## Current candidate

Version: **0.2.0**.

The current v0.2.0 branch is still a release candidate until exact-head CI and a fresh independent review are both satisfied. See `docs/AUTHORITY_MODEL.md` and `docs/UNIFIED_SKILL_ARCHITECTURE.md`.
