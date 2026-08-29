# HMS Skills Codex

Reusable HMS workflow skills for OpenAI Codex.

HMS Skills Codex is an **overlay**, not a fork of Superpowers. It keeps upstream Superpowers available for planning, debugging, worktrees, TDD, review, and verification while adding HMS authority control, fail-closed gates, scope locking, evidence requirements, model routing, UI design authority, and checkpoint handoff.

## Authority order

1. Owner instruction
2. Latest valid HMS checkpoint / frozen authority
3. HMS fail-closed and safety rules
4. HMS adaptive model routing
5. HMS project-specific skills, including `$hms-ui-design-authority`
6. Optional design-advisor skills such as GPT Taste and Impeccable
7. Upstream Superpowers skills
8. Codex defaults

A lower layer must never silently override a higher layer.

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

HMS does **not** track mutable upstream `main`. Superpowers is locked by `superpowers.lock.json`; GPT Taste and Impeccable are locked by `ui-skills.lock.json`. Install/update checks out exact commits in detached-HEAD state. Changing any pin is a material workflow change and should go through a reviewed HMS Skills Codex commit/PR.

Use `-SkipSuperpowers`, `-SkipTaste`, or `-SkipImpeccable` only when that dependency is intentionally managed elsewhere.

Restart Codex after the first installation so skill discovery refreshes.

## HMS Skills Manager

Windows users can enable or disable Codex discovery through the GUI instead of editing junctions manually.

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

The launcher uses process-local `ExecutionPolicy Bypass`, so it does not permanently weaken the machine execution policy. Restart or refresh Codex after changing discovery state.

Manager runtime self-test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manager\HmsSuperpowersManager.ps1 -SelfTest
```

## UI advisor rule

`gpt-taste` and `impeccable` are optional design advisors, not HMS authority. Their generic rules about fonts, AIDA, motion, spacing, layout, redesign, or framework choices do not override owner instruction, frozen product/UI definitions, Penpot, `DESIGN.md`, tokens/component mapping, platform requirements, or behavior outside the authorized scope.

This matters especially for engineering desktop software: web/marketing conventions from a generic design skill must not be imported into a desktop CAD/CAM or operations UI merely because the advisor prefers them.

## Use

```text
$hms-superpowers
Continue the current project from the latest valid authority.
```

For UI-specific work:

```text
$hms-ui-design-authority
Implement the authorized UI change from the canonical project design and verify it visually before PASS.
```

Optional advisor invocation:

```text
$gpt-taste
$impeccable
```

Codex may also activate skills automatically when the task matches their descriptions; HMS precedence still applies.

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

## Update

```powershell
& "$env:USERPROFILE\.codex\hms-skills-codex\update.ps1"
```

This fast-forwards HMS Skills Codex and reconciles pinned dependencies. When GPT Taste or Impeccable already exists locally, update preserves the Manager's current ON/OFF discovery choice; a newly introduced source is exposed once so it is immediately usable.

## Validate

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
```

The validator checks HMS skill metadata, PowerShell syntax, and all pinned dependency contracts. GitHub Actions runs structural validation plus the Windows install/update/Manager-self-test/real-Codex-discovery/uninstall contract on pushes and pull requests.

## Status

Current candidate version: **0.2.0**.

See `docs/AUTHORITY_MODEL.md` for the design contract.
