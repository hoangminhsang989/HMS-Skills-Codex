# HMS Skills Codex

Reusable HMS workflow skills for OpenAI Codex.

HMS Skills Codex is an **overlay**, not a fork of Superpowers. It keeps upstream Superpowers available for planning, debugging, worktrees, TDD, review, and verification while adding HMS authority control, fail-closed gates, scope locking, evidence requirements, model routing, and checkpoint handoff.

## Authority order

1. Owner instruction
2. Latest valid HMS checkpoint / frozen authority
3. HMS fail-closed and safety rules
4. HMS adaptive model routing
5. HMS project-specific skills
6. Upstream Superpowers skills
7. Codex defaults

A lower layer must never silently override a higher layer.

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

## Use

Explicit invocation:

```text
$hms-superpowers
Continue the current project from the latest valid authority.
```

Codex may also activate the skill automatically when the task matches its description.

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

## Update

```powershell
& "$env:USERPROFILE\.codex\hms-skills-codex\update.ps1"
```

This fast-forwards the HMS Skills Codex repository, validates it, and reconciles the local Superpowers checkout back to the commit currently recorded in `superpowers.lock.json`.

## Validate

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
```

The validator checks required `SKILL.md` frontmatter, folder/name identity, duplicate names, Codex orchestrator metadata, and the pinned Superpowers authority. GitHub Actions runs structural validation on pushes and pull requests; branch pushes also run an isolated Windows installation smoke that verifies the junction layout and exact Superpowers HEAD.

## Status

Current bootstrap version: **0.1.0**.

See `docs/AUTHORITY_MODEL.md` for the design contract.
