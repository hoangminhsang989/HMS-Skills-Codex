# HMS Skills Codex

Reusable HMS workflow skills for OpenAI Codex.

HMS Skills Codex is an **overlay**, not a fork of Superpowers. It keeps upstream Superpowers available for planning, debugging, worktrees, TDD, review, and verification while adding HMS authority control, fail-closed gates, scope locking, evidence requirements, model routing, UI design authority, and checkpoint handoff.

## Authority order

1. Owner instruction
2. Latest valid HMS checkpoint / frozen authority
3. HMS fail-closed and safety rules
4. HMS adaptive model routing
5. HMS project-specific skills
6. Upstream Superpowers skills
7. Codex defaults

A lower layer must never silently override a higher layer.

For material UI work, `$hms-ui-design-authority` applies inside the already-authorized project scope. When Penpot is the declared visual authority, the expected chain is approved HMS UI definition → Penpot → `DESIGN.md` → design tokens/component mapping → production UI → fresh visual/runtime evidence.

## Install on Windows

```powershell
git clone https://github.com/hoangminhsang989/HMS-Skills-Codex.git "$env:USERPROFILE\.codex\hms-skills-codex"
cd "$env:USERPROFILE\.codex\hms-skills-codex"
.\install.ps1
```

The installer creates a junction:

```text
%USERPROFILE%\.agents\skills\hms
  -> %USERPROFILE%\.codex\hms-skills-codex\skills
```

By default it also installs upstream `obra/superpowers` and exposes it at `%USERPROFILE%\.agents\skills\superpowers`. HMS does **not** track mutable upstream `main`: the reviewed upstream identity is locked in `superpowers.lock.json`, and install/update always checks out that exact commit in detached-HEAD state. Use `-SkipSuperpowers` when Superpowers is managed separately, such as through the Codex plugin marketplace.

Changing the Superpowers pin is a material workflow change and should go through a reviewed HMS Skills Codex commit/PR rather than an unreviewed `git pull` of upstream.

Restart Codex after the first installation so skill discovery refreshes.

## HMS Superpowers Manager

Windows users can enable or disable Codex discovery through the GUI instead of editing junctions manually.

Double-click:

```text
HMS-Superpowers-Manager.cmd
```

The manager exposes independent ON/OFF controls for:

- HMS Superpowers;
- pinned upstream Superpowers;
- both together.

OFF removes only the validated discovery junction. It does **not** delete the HMS repository, Superpowers checkout, or skill data. If the expected discovery path is occupied by an unrelated folder, file, or different reparse target, the manager reports `CONFLICT` and refuses to replace or remove it.

The launcher uses process-local `ExecutionPolicy Bypass`, so it does not permanently weaken the machine execution policy. Restart or refresh Codex after changing discovery state.

Manager runtime self-test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\manager\HmsSuperpowersManager.ps1 -SelfTest
```

## Use

Explicit invocation:

```text
$hms-superpowers
Continue the current project from the latest valid authority.
```

For UI-specific work:

```text
$hms-ui-design-authority
Implement the authorized UI change from the canonical project design and verify it visually before PASS.
```

Codex may also activate skills automatically when the task matches their descriptions.

## Core skills

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

This fast-forwards the HMS Skills Codex repository, validates it, and reconciles the local Superpowers checkout back to the commit currently recorded in `superpowers.lock.json`.

## Validate

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
```

The validator checks required `SKILL.md` frontmatter, folder/name identity, duplicate names, required Codex metadata, PowerShell syntax including the Manager UI, and the pinned Superpowers authority. GitHub Actions runs structural validation and the Windows install/update/manager-self-test/real-Codex-discovery/uninstall contract on both pushes and pull requests.

## Status

Current candidate version: **0.2.0**.

See `docs/AUTHORITY_MODEL.md` for the design contract.
