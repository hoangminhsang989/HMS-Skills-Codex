# HMS Superpowers v0.3.0 Windows Setup + Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a qualified per-user Windows installer and self-contained WinForms menu for HMS Superpowers without weakening the existing HMS authority, lifecycle, one-public-skill, or fail-closed contracts.

**Architecture:** The new Windows layer is presentation/bootstrap only. A pinned Inno Setup package installs a self-contained .NET 10 WinForms menu plus a PowerShell setup bootstrap; all substantive HMS lifecycle operations continue through committed-byte-authenticated PowerShell entry points. Runtime-downloadable Git/Codex support tools are private, per-user, pinned by exact asset identity and SHA-256, and selected only through process-local environment changes.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7 CI, .NET 10 SDK 10.0.400 / WinForms / C# 14, Inno Setup 7.1.0 x64, GitHub Actions Windows runners, MinGit 2.55.0.5 x64, OpenAI Codex rust-v0.152.1 native Windows x64 fallback.

**Spec:** `docs/superpowers/specs/2026-09-02-windows-setup-menu-design.md`

## Global Constraints

- Baseline `v0.2.0` authority remains immutable: commit `9054d07743297fdaa414068ef58b4ab60892f49e`, tree `f088073a4a0153e9de2bb4c7497162f6c7815185`.
- Work only on `stage/hms-superpowers-v0.3.0-windows-setup-menu` until exact-head CI and fresh independent review are complete.
- Preserve exactly one HMS public Codex skill: `$hms-superpowers`.
- Do not rewrite HMS composite/model/lifecycle authority in C#.
- Do not execute mutable lifecycle PowerShell files directly from the GUI.
- Do not require Node.js/npm to provide the HMS-owned Codex fallback.
- Do not install or mutate machine-wide Git, .NET, PATH, or Codex state.
- Supported target is Windows 10/11 x64 with trusted Windows PowerShell 5.1.
- Pin .NET SDK to `10.0.400` in `global.json`.
- Pin Inno Setup build tool to `7.1.0` x64 in CI.
- Pin MinGit asset `MinGit-2.55.0.5-64-bit.zip` SHA-256 `56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e`.
- Pin Codex fallback asset `codex-x86_64-pc-windows-msvc.exe.zip` archive SHA-256 `11634c7da0aadf53dff3ec0bad9fd3715371afff189becac433270b21cf299c9` and extracted EXE SHA-256 `01b0fd4167393e004b9174c77ae5f8570486118e19dc4216cfc62a62a74b6ee6`.
- Every material workflow change must run `pwsh ./scripts/Test-HmsSkills.ps1`, exact-head Windows setup qualification, and fresh independent review before merge.

---

### Task 1: Add the Windows setup contract test and wire it into the repository validator

**Files:**
- Create: `scripts/Test-HmsWindowsSetup.ps1`
- Modify: `scripts/Test-HmsSkills.ps1`

**Interfaces:**
- Consumes: repository root passed through `-RepoRoot`.
- Produces: a deterministic static validator that fails when required Windows setup/menu files, pins, or trust-boundary markers are absent or malformed.

- [ ] **Step 1: Write the failing contract test**

Create `scripts/Test-HmsWindowsSetup.ps1` with strict mode and assertions for these exact required paths:

```powershell
$required = @(
  'global.json',
  'HMS-Lifecycle.cmd',
  'scripts/Invoke-HmsLifecycleAction.ps1',
  'installer/setup-tools.lock.json',
  'installer/Invoke-HmsSetupBootstrap.ps1',
  'installer/HMS-Superpowers.iss',
  'desktop/HmsSuperpowers/HmsSuperpowers.csproj',
  'desktop/HmsSuperpowers/Program.cs',
  'desktop/HmsSuperpowers/HmsPaths.cs',
  'desktop/HmsSuperpowers/HmsStatusReader.cs',
  'desktop/HmsSuperpowers/HmsProcessRunner.cs',
  'desktop/HmsSuperpowers/MainForm.cs',
  '.github/workflows/validate-windows-setup-menu.yml'
)
```

The test must also parse `global.json` and require `sdk.version == '10.0.400'`; parse `installer/setup-tools.lock.json` and require the exact MinGit/Codex tag, asset, and digests in Global Constraints; inspect `HMS-Lifecycle.cmd` for committed-blob authentication before script execution; inspect the WinForms project for `net10.0-windows`, `UseWindowsForms=true`, `SelfContained=true`, `RuntimeIdentifier=win-x64`, and single-file publication; and inspect the Inno script for per-user install mode plus Desktop/Start Menu entries.

- [ ] **Step 2: Wire the test into `scripts/Test-HmsSkills.ps1`**

Append one support path and one invocation:

```powershell
$windowsSetupPath = Join-Path $PSScriptRoot 'Test-HmsWindowsSetup.ps1'
# include $windowsSetupPath in the support-file existence loop
& $windowsSetupPath -RepoRoot $RepoRoot
```

- [ ] **Step 3: Run RED**

Run:

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
```

Expected: FAIL because the v0.3.0 setup/menu files do not yet exist. The failure must identify the first missing required path, not a syntax error in the test.

- [ ] **Step 4: Commit the red test**

Commit message:

```text
test: define Windows setup and menu contract
```

---

### Task 2: Add the committed-byte authenticated lifecycle launcher

**Files:**
- Create: `HMS-Lifecycle.cmd`
- Create: `scripts/Invoke-HmsLifecycleAction.ps1`
- Test: `scripts/Test-HmsWindowsSetup.ps1`

**Interfaces:**
- Consumes: action token `update`, `repair`, or `uninstall`; optional `-InstallRoot` supplied internally from the trusted repo root.
- Produces: one outer CMD launcher that authenticates `scripts/Invoke-HmsLifecycleAction.ps1` against the current committed HMS HEAD before executing it in-memory.

- [ ] **Step 1: Extend the test with lifecycle action requirements**

Require that `Invoke-HmsLifecycleAction.ps1` accepts only these actions:

```powershell
[ValidateSet('update','repair','uninstall')][string]$Action
```

Require that the shim never invokes `powershell.exe -File` on `install.ps1`, `update.ps1`, or `uninstall.ps1`. Require committed object lookup with `git rev-parse "$TrustedHead`:<relative-path>"`, object type `blob`, live-byte Git blob hash comparison, UTF-8 strict decoding, and `[ScriptBlock]::Create()` execution.

- [ ] **Step 2: Run RED**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
```

Expected: FAIL because launcher files are absent.

- [ ] **Step 3: Implement the outer CMD launcher**

`HMS-Lifecycle.cmd` must follow the existing Manager launcher trust pattern: resolve canonical HEAD, resolve the committed shim blob, read live shim bytes with exclusive read semantics, compute the Git SHA-1 blob identity, reject mismatch, decode strict UTF-8, create a ScriptBlock, and invoke it with `-TrustedRepoRoot`, `-TrustedHead`, and `-TrustedBootstrapBlob` plus the requested action.

The CMD accepts only one positional action token. Unknown/empty action exits non-zero before PowerShell is invoked.

- [ ] **Step 4: Implement the trusted lifecycle shim**

`Invoke-HmsLifecycleAction.ps1` must:

```powershell
param(
  [ValidateSet('update','repair','uninstall')][string]$Action,
  [Parameter(Mandatory)][string]$TrustedRepoRoot,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$TrustedHead,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$TrustedBootstrapBlob
)
```

For each target script, resolve the committed blob at `$TrustedHead:<path>`, prove blob type, read the live file bytes, compute exact Git blob SHA-1, reject mismatch, then execute the authenticated bytes in-memory. Map actions exactly:

```text
update    -> update.ps1 -InstallRoot <TrustedRepoRoot>
repair    -> install.ps1 -InstallRoot <TrustedRepoRoot>
uninstall -> uninstall.ps1 -InstallRoot <TrustedRepoRoot>
```

No clone-removal flags are passed by the normal GUI uninstall action.

- [ ] **Step 5: Run GREEN**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
pwsh ./scripts/Test-HmsSkills.ps1
```

Expected: the lifecycle-launcher portion passes; the full Windows contract still fails only on later missing setup/menu files.

- [ ] **Step 6: Commit**

Commit message:

```text
feat: add authenticated lifecycle launcher
```

---

### Task 3: Add pinned support-tool lock and fail-closed setup bootstrap

**Files:**
- Create: `installer/setup-tools.lock.json`
- Create: `installer/Invoke-HmsSetupBootstrap.ps1`
- Test: `scripts/Test-HmsWindowsSetup.ps1`

**Interfaces:**
- Consumes: `-AuthorityPath`, `-ToolsLockPath`, optional `-InstallRoot`, optional `-AppRoot`, and optional `-Mode Install|Repair|Diagnose`.
- Produces: verified per-user support Git/Codex selection and an exact HMS checkout ready for authenticated `install.ps1` execution.

- [ ] **Step 1: Extend tests for exact lock schema**

Require schema version 1 and these exact records:

```json
{
  "schema_version": 1,
  "mingit": {
    "repository": "git-for-windows/git",
    "tag": "v2.55.0.windows.5",
    "asset": "MinGit-2.55.0.5-64-bit.zip",
    "sha256": "56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e"
  },
  "codex": {
    "repository": "openai/codex",
    "tag": "rust-v0.152.1",
    "asset": "codex-x86_64-pc-windows-msvc.exe.zip",
    "archive_sha256": "11634c7da0aadf53dff3ec0bad9fd3715371afff189becac433270b21cf299c9",
    "exe_sha256": "01b0fd4167393e004b9174c77ae5f8570486118e19dc4216cfc62a62a74b6ee6"
  }
}
```

Require the bootstrap to contain no `/latest/` release URL and no `npm install`.

- [ ] **Step 2: Run RED**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
```

Expected: FAIL on absent lock/bootstrap.

- [ ] **Step 3: Implement support-tool verification helpers**

Implement focused functions with these signatures:

```powershell
function Get-HmsSha256([string]$Path) { ... }
function Assert-HmsSha256([string]$Path,[string]$Expected) { ... }
function Assert-HmsSafeDirectory([string]$Path,[string]$Label) { ... }
function Invoke-HmsPinnedDownload([string]$Uri,[string]$Destination,[string]$Sha256) { ... }
function Ensure-HmsMinGit([pscustomobject]$Lock,[string]$SupportRoot) { ... }
function Resolve-HmsCodex([pscustomobject]$Lock,[string]$SupportRoot) { ... }
```

`Assert-HmsSafeDirectory` rejects an existing reparse point and refuses to recursively delete an unknown directory. Replacement is stage-to-new-name plus rename of a directory whose parent and staged contents were created by the current process.

- [ ] **Step 4: Implement exact source authority reconciliation**

Authority JSON fields:

```json
{
  "schema_version": 1,
  "product_version": "0.3.0",
  "mode": "candidate",
  "repository": "https://github.com/hoangminhsang989/HMS-Skills-Codex.git",
  "source_ref": "refs/heads/stage/hms-superpowers-v0.3.0-windows-setup-menu",
  "commit": "<40 hex candidate>",
  "tree": "<40 hex candidate tree>",
  "release_tag": null
}
```

Release builds switch `mode` to `release`, set `source_ref` to `refs/tags/v0.3.0`, and require `release_tag == 'v0.3.0'`.

For fresh installation, use HMS MinGit to fetch only the authority ref into a dedicated remote ref, prove fetched commit/tree match the embedded values, create/reset local `main` to that exact commit, set origin, and prove clean state + no hidden index flags. For an existing checkout, accept only expected origin and clean/non-hidden state; allow fast-forward to the authority commit; never silently downgrade a verified descendant; reject divergence.

- [ ] **Step 5: Implement Codex selection**

A PATH Codex is accepted only when its resolved executable path is a regular non-reparse file, its bytes can be hashed, and `codex --version` succeeds. It remains user-managed and is not modified. HMS still stores and uses the pinned private fallback when the user Codex is unavailable or cannot be safely qualified. The fallback ZIP and extracted EXE must both match the lock before activation.

- [ ] **Step 6: Run GREEN for bootstrap contract**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
```

Expected: bootstrap/lock assertions pass; later GUI/installer assertions may still fail.

- [ ] **Step 7: Commit**

Commit message:

```text
feat: add verified Windows setup bootstrap
```

---

### Task 4: Add the self-contained WinForms menu application

**Files:**
- Create: `global.json`
- Create: `desktop/HmsSuperpowers/HmsSuperpowers.csproj`
- Create: `desktop/HmsSuperpowers/Program.cs`
- Create: `desktop/HmsSuperpowers/HmsPaths.cs`
- Create: `desktop/HmsSuperpowers/HmsStatusReader.cs`
- Create: `desktop/HmsSuperpowers/HmsProcessRunner.cs`
- Create: `desktop/HmsSuperpowers/MainForm.cs`
- Test: `scripts/Test-HmsWindowsSetup.ps1`

**Interfaces:**
- `HmsPaths.ForCurrentUser()` returns canonical source/app/support paths.
- `HmsStatusReader.ReadAsync(CancellationToken)` returns immutable `HmsStatusSnapshot`.
- `HmsProcessRunner.RunLifecycleAsync(HmsLifecycleAction, IProgress<string>, CancellationToken)` launches the authenticated outer launcher.
- `MainForm` renders status and exposes the seven approved actions.

- [ ] **Step 1: Extend contract tests for project properties and action names**

Require `global.json`:

```json
{"sdk":{"version":"10.0.400","rollForward":"disable"}}
```

Require project properties:

```xml
<TargetFramework>net10.0-windows</TargetFramework>
<UseWindowsForms>true</UseWindowsForms>
<RuntimeIdentifier>win-x64</RuntimeIdentifier>
<SelfContained>true</SelfContained>
<PublishSingleFile>true</PublishSingleFile>
<PlatformTarget>x64</PlatformTarget>
```

Require the seven Vietnamese action labels from the approved spec to exist in `MainForm.cs`.

- [ ] **Step 2: Run RED**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
```

Expected: FAIL on absent .NET project files.

- [ ] **Step 3: Implement paths and status model**

Use records/enums:

```csharp
internal enum HmsLifecycleAction { Update, Repair, Uninstall }
internal sealed record HmsPaths(string RepoRoot, string AppRoot, string SupportGitRoot, string SupportCodexRoot, string LifecycleLauncher);
internal sealed record HmsStatusSnapshot(bool RepoPresent, bool RepoClean, string Head, string Version, string GitState, string CodexState, string CompositeState, string PublicSkillState);
```

Status collection is read-only. Git inspection uses the setup-owned MinGit when present and never mutates the repo.

- [ ] **Step 4: Implement bounded process runner**

`RunLifecycleAsync` uses `ProcessStartInfo` with `UseShellExecute=false`, redirected stdout/stderr, and asynchronous draining. It invokes only `HMS-Lifecycle.cmd <action>` from the verified HMS checkout. Manager/Model Settings actions invoke the existing authenticated CMD launchers. Mutation buttons are disabled while a lifecycle action is running.

- [ ] **Step 5: Implement the compact WinForms UI**

The window contains a status header, a compact two-column action area, a bounded multiline log/result box, and these buttons:

```text
Quản lý Skills
Cài đặt Model
Update HMS
Repair / Rebuild
Kiểm tra hệ thống
Mở thư mục HMS
Uninstall
```

Uninstall requires an explicit confirmation dialog. Folder opening verifies path existence first. No UI action edits model/composite state directly.

- [ ] **Step 6: Build locally/CI**

Run:

```powershell
dotnet --version
dotnet restore desktop/HmsSuperpowers/HmsSuperpowers.csproj --locked-mode
dotnet build desktop/HmsSuperpowers/HmsSuperpowers.csproj -c Release --no-restore
dotnet publish desktop/HmsSuperpowers/HmsSuperpowers.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true --no-restore
```

Expected: SDK `10.0.400`; build/publish exit 0; one `HMS-Superpowers.exe` exists in publish output.

- [ ] **Step 7: Run repository tests**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
pwsh ./scripts/Test-HmsSkills.ps1
```

- [ ] **Step 8: Commit**

Commit message:

```text
feat: add HMS Superpowers Windows menu
```

---

### Task 5: Add Inno Setup package and shortcut/uninstall ownership

**Files:**
- Create: `installer/HMS-Superpowers.iss`
- Test: `scripts/Test-HmsWindowsSetup.ps1`

**Interfaces:**
- Consumes: staged menu EXE, bootstrap script, tool lock, generated setup authority, icon.
- Produces: `HMS-Superpowers-Setup-v0.3.0.exe` installed per-user under `%LOCALAPPDATA%\Programs\HMS Superpowers`.

- [ ] **Step 1: Extend tests for installer semantics**

Require these semantics in the `.iss` source:

```text
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\HMS Superpowers
AppVersion=0.3.0
OutputBaseFilename=HMS-Superpowers-Setup-v0.3.0
```

Require a Desktop shortcut task enabled by default and Start Menu entries for `HMS Superpowers` and uninstall. Require Setup to call `powershell.exe` with the packaged bootstrap after files are staged.

- [ ] **Step 2: Run RED**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
```

Expected: FAIL until installer source is present and complete.

- [ ] **Step 3: Implement installer source**

Use per-user install mode only. Package `HMS-Superpowers.exe`, `Invoke-HmsSetupBootstrap.ps1`, `setup-tools.lock.json`, generated `setup-authority.json`, and icon. Setup must abort on bootstrap non-zero exit and must not create a success shortcut state before bootstrap succeeds.

- [ ] **Step 4: Compile installer**

Run with pinned Inno Setup 7.1.0 x64 compiler:

```powershell
& "$env:INNO_HOME\ISCC.exe" installer/HMS-Superpowers.iss
```

Expected: one Setup EXE with the exact output filename.

- [ ] **Step 5: Commit**

Commit message:

```text
feat: add per-user Windows installer
```

---

### Task 6: Add exact-head Windows build and runtime qualification workflow

**Files:**
- Create: `.github/workflows/validate-windows-setup-menu.yml`
- Test: GitHub Actions on exact candidate SHA.

**Interfaces:**
- Consumes: `CANDIDATE_SHA` from push/PR event.
- Produces: exact-head static test, .NET build/publish, Inno compilation, installer hash, and Windows install/menu/lifecycle smoke evidence.

- [ ] **Step 1: Extend the static test to require exact-head workflow guards**

Require workflow checkout to use pinned `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` and verify `git rev-parse HEAD == CANDIDATE_SHA` before build/test.

- [ ] **Step 2: Run RED**

Run:

```powershell
pwsh ./scripts/Test-HmsWindowsSetup.ps1
```

Expected: FAIL because workflow file is absent.

- [ ] **Step 3: Implement workflow**

The Windows job must:

1. checkout exact SHA;
2. run `./scripts/Test-HmsSkills.ps1`;
3. install exact .NET SDK 10.0.400 using pinned `actions/setup-dotnet` commit;
4. restore/build/publish WinForms;
5. download Inno Setup 7.1.0 x64 from its exact release URL and verify a committed CI SHA-256 constant before silent install/extraction;
6. generate `setup-authority.json` from exact candidate SHA/tree and branch ref;
7. compile Setup;
8. hash Setup and menu EXE;
9. run Setup silently into a fresh per-user runner state;
10. prove Desktop/Start Menu registration, installed menu EXE, HMS source origin/HEAD/tree, one public HMS skill, and composite manifest;
11. run `HMS-Lifecycle.cmd repair` then system diagnostics;
12. run registered uninstaller silently and prove setup-owned app/shortcuts are removed while HMS source/state remain by default.

- [ ] **Step 4: Run GREEN**

Push the workflow commit and inspect the workflow run for the exact head. Expected: all jobs conclude `success` with no skipped trust gate.

- [ ] **Step 5: Commit**

Commit message:

```text
ci: qualify Windows setup and menu
```

---

### Task 7: Add binary icon and release artifact provenance

**Files:**
- Create: `assets/hms-superpowers.ico`
- Modify: `desktop/HmsSuperpowers/HmsSuperpowers.csproj`
- Modify: `installer/HMS-Superpowers.iss`
- Modify: `.github/workflows/validate-windows-setup-menu.yml`

**Interfaces:**
- Consumes: repository-owned ICO.
- Produces: menu/setup/shortcut icon plus SHA-256 provenance artifact for Setup and menu EXE.

- [ ] **Step 1: Extend test**

Require ICO presence, project `ApplicationIcon`, Inno `SetupIconFile`, and CI generation of `SHA256SUMS.txt` containing exactly the Setup EXE and menu EXE hashes.

- [ ] **Step 2: Run RED**

Run `pwsh ./scripts/Test-HmsWindowsSetup.ps1`; expected failure on missing icon/provenance references.

- [ ] **Step 3: Add deterministic repository icon**

Add a small multi-resolution Windows ICO owned by HMS. It is presentation-only; no trust decision may depend on its content.

- [ ] **Step 4: Wire icon and hashes**

Set:

```xml
<ApplicationIcon>..\..\assets\hms-superpowers.ico</ApplicationIcon>
```

and Inno `SetupIconFile=..\assets\hms-superpowers.ico`. CI writes lowercase SHA-256 lines to `SHA256SUMS.txt` and uploads Setup, menu EXE, setup authority, and checksum file as one workflow artifact.

- [ ] **Step 5: Run GREEN and commit**

Run full static tests plus build; commit message:

```text
build: add Windows artifact identity metadata
```

---

### Task 8: Documentation, versioning boundary, and full candidate qualification

**Files:**
- Modify: `README.md`
- Modify: `VERSION` only after the candidate has passed all implementation tests and is intentionally frozen as the v0.3.0 release candidate.
- Optional create: `docs/V0_3_0_WINDOWS_SETUP_CANDIDATE.md` for final exact identity/evidence.

**Interfaces:**
- Produces: user-facing install/update/repair/uninstall instructions and a frozen release-candidate authority record.

- [ ] **Step 1: Add README usage**

Document the single Setup EXE path, default Desktop shortcut, menu actions, per-user support tooling, normal non-destructive uninstall, and the fact that the existing PowerShell lifecycle remains authoritative.

- [ ] **Step 2: Run full repository qualification**

Run on exact candidate:

```powershell
pwsh ./scripts/Test-HmsSkills.ps1
pwsh ./scripts/Test-HmsWindowsSetup.ps1
dotnet restore desktop/HmsSuperpowers/HmsSuperpowers.csproj --locked-mode
dotnet build desktop/HmsSuperpowers/HmsSuperpowers.csproj -c Release --no-restore
dotnet publish desktop/HmsSuperpowers/HmsSuperpowers.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true --no-restore
```

Then require every GitHub Actions workflow for the exact head to reach terminal `success`, including `Validate HMS skills` and `Validate HMS Windows setup and menu`.

- [ ] **Step 3: Freeze candidate identity**

Capture exact candidate HEAD/tree, Setup SHA-256, menu EXE SHA-256, workflow run IDs/conclusions, and changed-file scope in `docs/V0_3_0_WINDOWS_SETUP_CANDIDATE.md`.

- [ ] **Step 4: Fresh independent review**

Review committed bytes specifically for: downloaded-tool trust, source exactness, reparse/delete behavior, direct mutable PowerShell execution, command injection, downgrade/divergence behavior, user Codex isolation, uninstall ownership, one-public-skill invariant, and exact-head CI binding.

Expected verdict must explicitly contain no unresolved P0/P1 finding before merge.

- [ ] **Step 5: Version and release only after review**

Set `VERSION` to `0.3.0`, regenerate release-mode `setup-authority.json` from the exact release commit/tag during release CI, rerun exact-head qualification, then merge/publish only if the new release identity is fully green.

---

## Self-Review Results

- Spec coverage: every design section is mapped to Tasks 1-8; no Setup/menu behavior is implemented outside an explicit task.
- Placeholder scan: no implementation step relies on an unspecified future handler, pin, action, test, or path.
- Type consistency: GUI lifecycle actions map one-for-one to authenticated launcher actions; setup bootstrap and CI use the same authority/lock schema; release mode differs from candidate mode only by exact source ref/tag authority.
- Safety review: normal uninstall remains non-destructive for repositories/state; private support tooling is per-user; no global PATH/.NET/Git/Codex mutation is authorized.

## Execution Mode

This harness has GitHub repository access but no native subagent execution surface. Execute inline with `superpowers:executing-plans`, using GitHub Actions as the Windows RED/GREEN verifier and preserving one independently reviewable commit per task wherever practical.
