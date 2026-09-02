# HMS Superpowers v0.3.0 — Windows Setup + Menu Application Design

Status: **DESIGN APPROVED BY OWNER; IMPLEMENTATION NOT YET AUTHORIZED**

Date: 2026-09-02

Baseline release: `v0.2.0`

Baseline authority commit: `9054d07743297fdaa414068ef58b4ab60892f49e`

Baseline authority tree: `f088073a4a0153e9de2bb4c7497162f6c7815185`

Target successor: `v0.3.0`

## 1. Purpose

HMS Skills Codex currently provides a qualified PowerShell installation lifecycle plus separate Windows launchers for the Skills Manager and Model Settings. v0.3.0 adds a user-facing Windows installation package and a single graphical menu application without replacing the existing HMS authority, trust, model-routing, or composite-skill logic.

The new user experience is:

1. Download one `HMS-Superpowers-Setup-v0.3.0.exe`.
2. Run Setup.
3. Setup automatically supplies HMS-owned support tooling when the machine lacks what HMS needs.
4. Setup installs/reconciles HMS at `%USERPROFILE%\.codex\hms-skills-codex` and executes the existing qualified installation lifecycle.
5. Setup creates Start Menu shortcuts and, by default, a Desktop shortcut named **HMS Superpowers**.
6. The shortcut opens `HMS-Superpowers.exe`, a compact Windows GUI that exposes the existing HMS management functions from one place.

`v0.2.0` remains immutable. All implementation work occurs on an isolated successor branch and must satisfy exact-head CI plus fresh independent review before merge/release.

## 2. Goals

The v0.3.0 deliverable SHALL:

- provide a single Windows Setup EXE;
- provide a self-contained x64 Windows menu EXE;
- require no separately installed .NET runtime on the target machine;
- create a Desktop shortcut by default, with an explicit Setup task to disable it;
- create a Start Menu folder and uninstall entry;
- detect and automatically supply required support tooling when missing;
- avoid requiring Node.js/npm merely to supply Codex CLI;
- preserve the one-public-skill contract: only `$hms-superpowers` may be exposed by HMS;
- delegate HMS work-module/model/lifecycle behavior to the existing qualified backend rather than reimplementing it in C#;
- preserve fail-closed behavior for dirty repositories, unexpected origins, identity mismatch, hash mismatch, unsafe reparse state, and unsupported runtime state;
- make Repair able to restore missing setup-owned support tooling and rebuild the HMS composite;
- integrate normal uninstall with Windows Apps & Features / Programs and Features;
- produce release hashes for every executable release artifact.

## 3. Non-goals

v0.3.0 SHALL NOT:

- rewrite `install.ps1`, `update.ps1`, `uninstall.ps1`, Manager, Model Settings, the composite compiler, or model dispatcher in C# merely to make an EXE;
- convert trusted PowerShell source directly with PS2EXE;
- expose HMS child skills, Superpowers source skills, GPT Taste, Impeccable, CodeGraph adapter, Three-Level adapter, or the model dispatcher as additional public Codex skills;
- install or modify a machine-wide .NET runtime;
- require a machine-wide Git installation;
- silently replace a user-managed Git or Codex installation;
- silently delete user state, source clones, model settings, or unrelated Codex configuration;
- track unpinned `latest` dependency URLs at runtime.

## 4. Architecture

The implementation has four layers with strict ownership boundaries.

### 4.1 Windows Setup

`HMS-Superpowers-Setup-v0.3.0.exe` is produced with Inno Setup on a pinned Windows CI toolchain. Inno Setup is a build-time dependency only; the end-user machine does not need it installed.

Setup owns:

- installation of the menu executable and setup-owned files;
- Desktop/Start Menu shortcuts;
- Windows uninstall registration;
- invocation of the setup bootstrap;
- presentation of installation progress and terminal errors.

Setup does not implement HMS composite/model authority itself.

### 4.2 Setup bootstrap

A committed bootstrap script, packaged inside Setup, owns pre-HMS prerequisites and acquisition of the exact HMS release source. It runs under Windows PowerShell 5.1 after Setup verifies that Windows PowerShell is available.

The bootstrap owns:

- OS/architecture checks;
- download, SHA-256 verification, staging, and atomic activation of setup-owned support tools;
- exact HMS repository origin/ref/commit reconciliation;
- preparation of a process-local PATH that prefers the HMS-owned MinGit toolchain for HMS lifecycle commands;
- selection of a usable Codex CLI, with a pinned HMS-owned fallback when no usable Codex CLI exists;
- launching the existing `install.ps1` only after source identity is proven.

### 4.3 `HMS-Superpowers.exe`

The menu application is a .NET WinForms x64 executable published self-contained. The source tree must pin the exact .NET SDK through `global.json`; CI must build only with that pinned SDK. The resulting EXE must not require a separately installed .NET runtime.

The menu application owns presentation, status collection, confirmation dialogs, process launching, and readable success/failure reporting. It does not own the substantive HMS lifecycle logic.

### 4.4 Existing HMS backend

The existing PowerShell/CMD backend remains authoritative for:

- Skills Manager;
- Model Settings;
- install/rebuild;
- update;
- uninstall;
- composite compilation;
- pinned source/tool reconciliation;
- model dispatch policy;
- exact-head/lifecycle trust gates.

Where a lifecycle action does not already have an outer committed-byte launcher suitable for the GUI, v0.3.0 shall add one narrow authenticated launcher rather than executing mutable live PowerShell bytes directly from the menu.

## 5. Installed layout

The canonical HMS source location remains:

```text
%USERPROFILE%\.codex\hms-skills-codex
```

Setup-owned application/support files live outside the Git checkout so updating HMS source cannot overwrite the installed launcher while it is running:

```text
%LOCALAPPDATA%\Programs\HMS Superpowers\
  HMS-Superpowers.exe
  support\
    git\...
    codex\...          # only when HMS-owned Codex fallback is required
  setup-authority.json
  setup-tools.lock.json
```

The existing generated/state locations remain unchanged:

```text
%USERPROFILE%\.codex\hms-composite\...
%USERPROFILE%\.agents\skills\hms-superpowers
```

No new public skill-discovery root is introduced.

## 6. Menu UX

The primary window is a compact engineering-style Windows utility, not a large SaaS dashboard. It displays:

- HMS installation state;
- installed HMS source version/HEAD;
- Git support-tool state;
- Codex CLI state/version;
- composite/public-skill state;
- last action result.

Primary actions:

1. **Quản lý Skills** — launch the existing qualified HMS Skills/Superpowers Manager outer launcher.
2. **Cài đặt Model** — launch the existing qualified Model Settings outer launcher.
3. **Update HMS** — invoke the authenticated HMS update lifecycle.
4. **Repair / Rebuild** — re-qualify setup-owned support tools, prove the HMS checkout is safe, then invoke the authenticated install/rebuild lifecycle.
5. **Kiểm tra hệ thống** — perform read-only diagnostics for Windows, PowerShell, support Git, Codex, HMS origin/HEAD/clean state, composite manifest, and public discovery.
6. **Mở thư mục HMS** — open `%USERPROFILE%\.codex\hms-skills-codex` only after verifying that the expected path exists.
7. **Uninstall** — require explicit user confirmation, then launch the registered uninstaller / qualified HMS uninstall flow.

Long-running actions run asynchronously from the WinForms UI and stream bounded progress/status back to the window. Buttons that could conflict with an active lifecycle mutation are disabled until that operation reaches a terminal state.

## 7. Desktop and Start Menu shortcuts

Setup defines a task named **Create Desktop Shortcut**, enabled by default.

When enabled:

```text
Desktop\HMS Superpowers.lnk -> HMS-Superpowers.exe
```

Start Menu always receives:

```text
HMS Superpowers\
  HMS Superpowers.lnk
  Uninstall HMS Superpowers.lnk
```

Upgrade/repair must update the existing shortcut identities rather than create duplicates. Normal Setup uninstall removes Setup-owned Desktop and Start Menu shortcuts.

A repo-owned HMS `.ico` is embedded in the menu executable and used for Setup/shortcuts. The icon is presentation-only and cannot participate in authority decisions.

## 8. Prerequisite bootstrap and support-tool locking

All runtime-downloadable support tooling is declared in committed `installer/setup-tools.lock.json`. The bootstrap must parse the lock fail-closed and may download only the exact repository/tag/asset identities and hashes recorded there.

### 8.1 Windows PowerShell

Supported target for v0.3.0 is Windows 10/11 x64 with Windows PowerShell 5.1 available at the trusted Windows system location. Setup validates it before continuing. An unsupported/missing PowerShell installation is a terminal compatibility error; Setup must not download an arbitrary PowerShell replacement and continue under different semantics.

### 8.2 Git

HMS will not require or mutate a machine-wide Git installation. It will carry an HMS-managed portable MinGit support layer.

Initial v0.3.0 lock authority:

```text
Repository: git-for-windows/git
Tag:        v2.55.0.windows.5
Asset:      MinGit-2.55.0.5-64-bit.zip
SHA-256:    56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e
```

The bootstrap downloads the ZIP from the official Git for Windows GitHub release, verifies the ZIP SHA-256 before extraction, extracts into a staging directory, verifies the expected `git.exe` exists, and atomically activates the support directory. HMS lifecycle child processes receive a process-local PATH with this support Git first. No global PATH modification is required.

An existing machine Git installation is left untouched.

### 8.3 Codex CLI

The menu and Setup first detect whether a usable `codex` CLI is already available to the user. A usable existing CLI must start successfully and report a syntactically valid version. Setup does not overwrite that installation.

If Codex is missing or cannot start, HMS installs a private native Windows x64 fallback from the official OpenAI Codex GitHub release. Node.js/npm is therefore not a prerequisite.

Initial v0.3.0 fallback lock authority:

```text
Repository: openai/codex
Tag:        rust-v0.152.1
Asset:      codex-x86_64-pc-windows-msvc.exe.zip
ZIP SHA-256: 11634c7da0aadf53dff3ec0bad9fd3715371afff189becac433270b21cf299c9
Extracted EXE SHA-256: 01b0fd4167393e004b9174c77ae5f8570486118e19dc4216cfc62a62a74b6ee6
```

The bootstrap verifies both the downloaded archive and extracted executable before activation. The fallback is supplied to HMS child processes through process-local environment selection and is not allowed to silently replace the user's normal Codex command globally.

Authentication remains in Codex's normal user state; Setup must not request, copy, export, or rewrite user authentication secrets.

### 8.4 Existing HMS dependencies

Superpowers, GPT Taste, Impeccable, CodeGraph, and Three-Level Delivery remain governed by the existing HMS lock files and lifecycle scripts. Setup must not create a second pin set or second reconciliation implementation for them.

## 9. HMS source acquisition and release authority binding

The Setup build embeds a generated `setup-authority.json` containing:

- product version;
- exact candidate/release commit SHA;
- exact candidate/release tree SHA;
- expected repository URL;
- expected release tag for release builds.

CI generates this file from the exact checkout being built; it is not hand-edited with a guessed future commit.

For a fresh release installation, the bootstrap uses HMS-owned MinGit to:

1. create/fetch the canonical HMS repository;
2. fetch the exact release tag;
3. prove the tag resolves to the embedded authority commit;
4. prove that commit resolves to the embedded authority tree;
5. place the local `main` branch at that exact release commit and configure `origin/main` tracking without advancing to newer bytes during installation;
6. prove origin, HEAD, tree, clean state, and hidden-index state before running `install.ps1`.

This lets a historical Setup remain reproducible even if remote `main` advances later, while preserving the existing `update.ps1` fast-forward model for subsequent user-requested updates.

For an existing HMS checkout:

- unexpected origin, dirty tracked/untracked state that affects authority, hidden index flags, or unsafe repository shape is a terminal error;
- an older clean canonical main may be advanced only by fast-forward to the Setup authority commit;
- a checkout already at a verified descendant/newer HMS version is never downgraded silently; Setup reports that a newer HMS source is present and limits itself to compatible Setup-owned repair only;
- divergent history is rejected.

## 10. Installation flow

The visible Setup sequence is:

```text
Checking system
  -> Preparing verified support Git
  -> Checking / preparing Codex CLI
  -> Acquiring exact HMS release source
  -> Installing HMS dependencies
  -> Building HMS composite
  -> Verifying public discovery and launcher state
  -> Creating shortcuts
  -> Complete
```

Each phase has a terminal success/failure result. A failure must preserve enough diagnostic information for the menu/installer log while avoiding secrets.

Downloaded files are staged under a unique temporary directory. A downloaded executable/archive is never executed or activated before its pinned digest matches. Temporary files are removed after terminal success/failure where safe.

## 11. Repair behavior

Repair is idempotent and fail-closed. It SHALL:

- re-read the committed Setup support-tool lock;
- restore missing/corrupt setup-owned MinGit or Codex fallback only from pinned assets;
- reject a dirty/divergent/unexpected HMS source checkout rather than erase it;
- invoke the existing authenticated install/rebuild lifecycle to reconcile pinned HMS dependencies and regenerate the composite;
- verify exactly one HMS public `SKILL.md` remains discoverable when work modules are enabled;
- preserve model settings and work-module selections according to the existing lifecycle contract.

Repair does not perform pathname-based recursive cleanup of unknown data.

## 12. Update behavior

**Update HMS** delegates to the existing authenticated `update.ps1` lifecycle under the setup-selected support Git environment. It preserves existing work-module/model-state behavior.

The menu reports the resulting HMS source HEAD/version after update. It does not claim that the Setup/menu binary itself has upgraded unless a newer Setup package is actually installed.

Future Setup versions may add a separately qualified self-update mechanism; v0.3.0 does not silently download and execute a newer Setup.

## 13. Uninstall behavior

The Windows uninstaller requires user confirmation and performs two ownership-separated steps:

1. invoke the existing qualified HMS uninstall lifecycle to remove verified public discovery as defined by current HMS authority;
2. remove Setup-owned application/support files, Desktop shortcut, Start Menu entries, and Windows uninstall registration.

By default, uninstall preserves HMS source repositories, composite state, and model settings, matching the current non-destructive HMS uninstall semantics.

An explicit advanced uninstall option may request verified managed clone/tool removal through the existing uninstall flags. It is OFF by default and must never broaden deletion beyond objects proven to be HMS-owned.

## 14. Trust and fail-closed requirements

The new layers must preserve or strengthen the existing trust model:

- no downloaded support archive/executable before exact SHA-256 verification;
- no runtime `latest` dependency resolution;
- no execution of HMS lifecycle source until canonical repository origin/commit/tree/clean state are proven;
- no menu direct-execution of mutable PowerShell implementation bytes when an authenticated outer launcher is required;
- no silent fallback from trusted support Git to an arbitrary PATH `git.exe` for HMS lifecycle mutations;
- no destructive cleanup of unknown paths/reparse points;
- no hidden-index state accepted on HMS authority inputs;
- no claim of Codex model switching or installation success without observable process evidence;
- no secrets in logs;
- no administrator elevation unless an unavoidable Windows action is explicitly introduced and separately reviewed. The baseline design requires none because support Git/Codex and the application are per-user.

## 15. Source layout

Implementation should use the following bounded component layout:

```text
desktop/HmsSuperpowers/
  HmsSuperpowers.csproj
  Program.cs
  MainForm.cs
  HmsStatusReader.cs
  HmsProcessRunner.cs
  HmsPaths.cs

installer/
  HMS-Superpowers.iss
  Invoke-HmsSetupBootstrap.ps1
  setup-tools.lock.json

assets/
  hms-superpowers.ico

scripts/
  Test-HmsWindowsSetup.ps1

.github/workflows/
  validate-windows-setup-menu.yml
```

Additional narrowly scoped files are permitted when tests or trust-boundary isolation require them, but substantive HMS logic must not migrate into the GUI project.

## 16. Build and release

Windows CI builds from an exact candidate SHA and verifies checkout identity before any packaging step.

Required release artifacts for v0.3.0:

```text
HMS-Superpowers-Setup-v0.3.0.exe
HMS-Superpowers-Setup-v0.3.0.exe.sha256
HMS-Superpowers-v0.3.0-menu.exe
HMS-Superpowers-v0.3.0-menu.exe.sha256
```

The standalone menu EXE is provided for diagnostics/portable evaluation; normal users install with Setup.

The release workflow must bind artifact metadata to the exact release commit/tree and must never reuse the v0.2.0 tag or release namespace.

## 17. Qualification matrix

Before merge/release, v0.3.0 must demonstrate on Windows x64:

- exact-head checkout and build identity;
- self-contained menu launch on a machine without separately installed .NET runtime;
- fresh Setup install with no global Git installed;
- MinGit ZIP hash mismatch rejection;
- Codex fallback ZIP hash mismatch rejection;
- Codex fallback extracted EXE hash mismatch rejection;
- fresh install with existing usable Codex CLI;
- fresh install with Codex missing and pinned native fallback installed;
- fresh install/repair with support MinGit missing or corrupted;
- exact HMS tag/commit/tree binding during Setup;
- rejection of dirty, divergent, unexpected-origin, and hidden-index HMS checkouts;
- Desktop shortcut default ON and opt-out behavior;
- Start Menu launcher and uninstall shortcut;
- Skills Manager launch through qualified trust boundary;
- Model Settings launch through qualified trust boundary;
- Update HMS action;
- Repair/Rebuild action;
- read-only system diagnostics;
- normal uninstall preserving source/state;
- optional destructive uninstall scope guarded by explicit consent and exact ownership proof;
- full existing `pwsh ./scripts/Test-HmsSkills.ps1` regression PASS;
- existing delivery/model/Windows lifecycle regressions PASS;
- real Codex `skills/list` still exposes only the intended `$hms-superpowers` public skill;
- fresh independent review of all new setup/EXE trust boundaries after CI is green.

## 18. Acceptance criteria

v0.3.0 is releasable only when all of the following are true:

1. A Windows user can start from the Setup EXE and reach a qualified HMS installation without manually installing Git, .NET, Node.js, npm, or other HMS-specific libraries.
2. The Desktop shortcut is created by default and opens the menu EXE.
3. The menu exposes the agreed HMS actions and delegates them to qualified backend boundaries.
4. Missing support tools are automatically restored from pinned official assets; hash mismatch stops execution.
5. Existing user-managed Git/Codex installations are not silently overwritten.
6. No new public Codex skill namespace leaks.
7. Setup, repair, update, and uninstall preserve current fail-closed ownership and state rules.
8. Exact candidate CI is green.
9. Fresh independent review approves the candidate.
10. Only after those gates may the successor merge to `main` and publish `v0.3.0` artifacts.
