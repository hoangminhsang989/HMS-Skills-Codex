from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "uninstall.ps1"

text = PATH.read_text(encoding="utf-8")

# This fixer runs only after the baseline-locked review34 patcher has produced
# the exact-object uninstall helper. Keep the transformation narrow and fail
# closed if that generated shape changes.
helper_pat = re.compile(
    r"(?ms)^function Invoke-HmsUninstallExactDirectoryRemoval \{.*?^\}\r?\n"
)
helper_match = helper_pat.search(text)
if helper_match is None:
    raise RuntimeError("generated exact uninstall helper not found")
helper = helper_match.group(0)
required_helper_literals = (
    "Open-HmsUninstallDirectoryGuard -Path $Path -Label $Label",
    "Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $q -Label $Label",
    "DeleteByHandle($guard.Handle",
)
for literal in required_helper_literals:
    if helper.count(literal) != 1:
        raise RuntimeError(f"generated uninstall helper contract mismatch for: {literal}")
# The generic exact-object helper already performs one quarantine revalidation
# on the Windows branch. Preserve that contract and add a clone-specific
# callback so the permanent validator can see the concrete clone authority.
if helper.count("&$Validate $q") != 1:
    raise RuntimeError("generated uninstall helper quarantine revalidation shape changed")

new_helper = r'''function Invoke-HmsUninstallExactDirectoryRemoval {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Validate,
        [scriptblock]$OnQuarantined = $null
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }

    if ($env:OS -cne 'Windows_NT') {
        &$Validate $Path
        $q = Join-Path (Split-Path -Parent $Path) ($Prefix + [guid]::NewGuid().ToString('N'))
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $q) -ErrorAction Stop
        &$Validate $q
        if ($null -ne $OnQuarantined) { &$OnQuarantined $q }
        Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction Stop
        return
    }

    $guard = Open-HmsUninstallDirectoryGuard -Path $Path -Label $Label
    $renamed = $false
    $deleteStarted = $false
    $q = Join-Path (Split-Path -Parent $Path) ($Prefix + [guid]::NewGuid().ToString('N'))
    try {
        &$Validate $Path
        Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $q -Label $Label
        $renamed = $true

        # Revalidate content/ownership at the quarantine pathname while the
        # exact DELETE-capable root handle is still live and denies rename.
        &$Validate $q
        if ($null -ne $OnQuarantined) { &$OnQuarantined $q }

        $deleteStarted = $true
        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
        $code = 0
        if (-not [HmsUninstallExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)) {
            throw "$Label exact root delete-pending transition failed (Win32=$code): $q"
        }
        $guard.Handle.Dispose()
        $guard.Handle = $null
        if (Test-Path -LiteralPath $q) { throw "$Label exact quarantine remained after handle deletion: $q" }
    }
    catch {
        $e = $_
        if (-not $deleteStarted -and $renamed -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and -not (Test-Path -LiteralPath $Path)) {
            try { Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $Path -Label "$Label pre-delete rollback" } catch {}
        }
        elseif ($deleteStarted -and (Test-Path -LiteralPath $q)) {
            throw "$Label deletion failed after destructive child removal started; exact quarantined remainder was not restored: $q. Original: $($e.Exception.Message)"
        }
        throw $e
    }
    finally {
        if ($null -ne $guard -and $null -ne $guard.Handle) { $guard.Handle.Dispose() }
    }
}
'''
text = text[:helper_match.start()] + new_helper + "\n" + text[helper_match.end():]

clone_pat = re.compile(r"(?ms)^function Remove-VerifiedClone \{.*?^\}\r?\n")
clone_match = clone_pat.search(text)
if clone_match is None:
    raise RuntimeError("generated Remove-VerifiedClone not found")
clone = clone_match.group(0)
for literal in (
    "Assert-CloneIdentity -Path $Path -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath",
    "Invoke-HmsUninstallExactDirectoryRemoval",
):
    if clone.count(literal) != 1:
        raise RuntimeError(f"generated clone cleanup contract mismatch for: {literal}")

new_clone = r'''function Remove-VerifiedClone {
    param([string]$Path,[string]$ExpectedRemote,[string]$MarkerRelativePath,[string]$Action)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-CloneIdentity -Path $Path -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return }

    $validator = {
        param($p)
        Assert-CloneIdentity -Path $p -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath
    }.GetNewClosure()
    $quarantineValidator = {
        param($quarantine)
        Assert-CloneIdentity -Path $quarantine -ExpectedRemote $ExpectedRemote -MarkerRelativePath $MarkerRelativePath
    }.GetNewClosure()

    Invoke-HmsUninstallExactDirectoryRemoval `
        -Path $Path `
        -Prefix '.hms-clone-removing-' `
        -Label 'Verified clone uninstall cleanup' `
        -Validate $validator `
        -OnQuarantined $quarantineValidator
}
'''
text = text[:clone_match.start()] + new_clone + "\n" + text[clone_match.end():]

# Semantic/static assertions. The permanent validator intentionally looks for
# this exact quarantine revalidation literal; preserve it as executable code,
# not a comment or dead string.
if text.count("Assert-CloneIdentity -Path $quarantine") != 1:
    raise RuntimeError("clone quarantine revalidation literal is not uniquely executable")
if text.count("-OnQuarantined $quarantineValidator") != 1:
    raise RuntimeError("clone quarantine callback binding missing")
if text.count("if ($null -ne $OnQuarantined) { &$OnQuarantined $q }") != 2:
    raise RuntimeError("quarantine callback must execute on both platform branches")

PATH.write_text(text, encoding="utf-8", newline="\n")
print("PASS: clone quarantine identity is revalidated while exact root authority remains live.")
