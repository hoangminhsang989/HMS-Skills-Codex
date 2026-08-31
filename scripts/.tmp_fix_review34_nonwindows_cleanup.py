from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def write(rel, text):
    (ROOT / rel).write_text(text, encoding="utf-8", newline="\n")


def replace_function(text, name, body):
    pat = re.compile(rf"(?ms)^function {re.escape(name)} \{{.*?^\}}\r?\n")
    m = pat.search(text)
    if m is None:
        raise RuntimeError(f"function not found: {name}")
    return text[:m.start()] + body.rstrip() + "\n\n" + text[m.end():]


def insert_before_function(text, function_name, prelude):
    marker = f"function {function_name} {{"
    if text.count(marker) != 1:
        raise RuntimeError(f"function marker is not unique: {function_name}")
    return text.replace(marker, prelude.rstrip() + "\n\n" + marker, 1)


portable_template = r'''function {PORTABLE} {{
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {{
        throw "$Label portable identity requires a regular non-reparse directory: $Path"
    }}

    $kernel = [string](& uname -s 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kernel)) {{
        throw "$Label could not identify the non-Windows kernel for filesystem identity."
    }}
    if ($kernel.Trim() -ceq 'Linux') {{
        $values = @(& stat -Lc '%d:%i' -- $Path 2>$null)
    }}
    elseif ($kernel.Trim() -ceq 'Darwin') {{
        $values = @(& stat -f '%d:%i' $Path 2>$null)
    }}
    else {{
        throw "$Label does not support portable filesystem identity on kernel '$($kernel.Trim())'."
    }}
    if ($LASTEXITCODE -ne 0 -or $values.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$values[0])) {{
        throw "$Label could not capture portable device/inode identity: $Path"
    }}
    return ([string]$values[0]).Trim()
}}'''


def harden(rel, invoke_name, portable_name, prefix_parameter):
    text = read(rel)
    original_function_pattern = re.compile(rf"(?ms)^function {re.escape(invoke_name)} \{{.*?^\}}\r?\n")
    m = original_function_pattern.search(text)
    if m is None:
        raise RuntimeError(f"generated cleanup function missing in {rel}: {invoke_name}")
    old = m.group(0)

    forbidden = "Remove-Item -LiteralPath $q -Recurse -Force"
    if forbidden not in old:
        raise RuntimeError(f"expected non-Windows root-recursive cleanup baseline missing in {rel}")
    if "DeleteByHandle($guard.Handle" not in old:
        raise RuntimeError(f"Windows exact-handle delete contract missing in {rel}")
    if text.count(f"function {portable_name} {{") != 0:
        raise RuntimeError(f"portable identity helper already exists unexpectedly in {rel}")

    portable = portable_template.format(PORTABLE=portable_name)
    text = insert_before_function(text, invoke_name, portable)

    if prefix_parameter == "QuarantinePrefix":
        new = rf'''function {invoke_name} {{
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$QuarantinePrefix,[Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][scriptblock]$Validate)
    if (-not (Test-Path -LiteralPath $Path)) {{ return }}

    if ($env:OS -cne 'Windows_NT') {{
        $ownedIdentity = {portable_name} -Path $Path -Label $Label
        &$Validate $Path
        $q = Join-Path (Split-Path -Parent $Path) ($QuarantinePrefix + [guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $q) {{ throw "$Label portable quarantine destination is occupied: $q" }}
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $q) -ErrorAction Stop
        if (({portable_name} -Path $q -Label "$Label post-rename") -cne $ownedIdentity) {{ throw "$Label portable directory identity changed across quarantine rename: $q" }}
        &$Validate $q

        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) {{
            if (({portable_name} -Path $q -Label "$Label pre-child-delete") -cne $ownedIdentity) {{ throw "$Label portable quarantine root identity changed before child deletion: $q" }}
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }}
        if (({portable_name} -Path $q -Label "$Label pre-root-delete") -cne $ownedIdentity) {{ throw "$Label portable quarantine root identity changed before empty-root deletion: $q" }}
        if (@(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop).Count -ne 0) {{ throw "$Label portable quarantine root is not empty after child deletion: $q" }}
        Remove-Item -LiteralPath $q -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $q) {{ throw "$Label portable quarantine root remained after empty-root deletion: $q" }}
        return
    }}

    $guard = Open-HmsDeliveryDirectoryGuard -Path $Path -Label $Label
    $renamed = $false
    $deleteStarted = $false
    $q = Join-Path (Split-Path -Parent $Path) ($QuarantinePrefix + [guid]::NewGuid().ToString('N'))
    try {{
        &$Validate $Path
        Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $q -Label $Label
        $renamed = $true
        &$Validate $q
        $deleteStarted = $true
        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) {{ Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop }}
        $code = 0
        if (-not [HmsDeliveryExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)) {{ throw "$Label exact root delete-pending transition failed (Win32=$code): $q" }}
        $guard.Handle.Dispose()
        $guard.Handle = $null
        if (Test-Path -LiteralPath $q) {{ throw "$Label exact quarantine remained after handle deletion: $q" }}
    }}
    catch {{
        $e = $_
        if (-not $deleteStarted -and $renamed -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and -not (Test-Path -LiteralPath $Path)) {{
            try {{ Move-HmsDeliveryDirectoryGuard -Guard $guard -Destination $Path -Label "$Label pre-delete rollback" }} catch {{}}
        }}
        elseif ($deleteStarted -and (Test-Path -LiteralPath $q)) {{
            throw "$Label deletion failed after destructive child removal started; exact quarantined remainder was not restored: $q. Original: $($e.Exception.Message)"
        }}
        throw $e
    }}
    finally {{ if ($null -ne $guard -and $null -ne $guard.Handle) {{ $guard.Handle.Dispose() }} }}
}}'''
    else:
        # uninstall helper may have the clone-specific OnQuarantined callback
        # added by the preceding fixer; preserve it on both platform branches.
        if "[scriptblock]$OnQuarantined = $null" not in old:
            raise RuntimeError("clone-specific quarantine callback is missing before uninstall portable hardening")
        new = rf'''function {invoke_name} {{
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Validate,
        [scriptblock]$OnQuarantined = $null
    )
    if (-not (Test-Path -LiteralPath $Path)) {{ return }}

    if ($env:OS -cne 'Windows_NT') {{
        $ownedIdentity = {portable_name} -Path $Path -Label $Label
        &$Validate $Path
        $q = Join-Path (Split-Path -Parent $Path) ($Prefix + [guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $q) {{ throw "$Label portable quarantine destination is occupied: $q" }}
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $q) -ErrorAction Stop
        if (({portable_name} -Path $q -Label "$Label post-rename") -cne $ownedIdentity) {{ throw "$Label portable directory identity changed across quarantine rename: $q" }}
        &$Validate $q
        if ($null -ne $OnQuarantined) {{ &$OnQuarantined $q }}

        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) {{
            if (({portable_name} -Path $q -Label "$Label pre-child-delete") -cne $ownedIdentity) {{ throw "$Label portable quarantine root identity changed before child deletion: $q" }}
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }}
        if (({portable_name} -Path $q -Label "$Label pre-root-delete") -cne $ownedIdentity) {{ throw "$Label portable quarantine root identity changed before empty-root deletion: $q" }}
        if (@(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop).Count -ne 0) {{ throw "$Label portable quarantine root is not empty after child deletion: $q" }}
        Remove-Item -LiteralPath $q -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $q) {{ throw "$Label portable quarantine root remained after empty-root deletion: $q" }}
        return
    }}

    $guard = Open-HmsUninstallDirectoryGuard -Path $Path -Label $Label
    $renamed = $false
    $deleteStarted = $false
    $q = Join-Path (Split-Path -Parent $Path) ($Prefix + [guid]::NewGuid().ToString('N'))
    try {{
        &$Validate $Path
        Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $q -Label $Label
        $renamed = $true
        &$Validate $q
        if ($null -ne $OnQuarantined) {{ &$OnQuarantined $q }}
        $deleteStarted = $true
        foreach ($child in @(Get-ChildItem -LiteralPath $q -Force -ErrorAction Stop)) {{ Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop }}
        $code = 0
        if (-not [HmsUninstallExactFsNative]::DeleteByHandle($guard.Handle,[ref]$code)) {{ throw "$Label exact root delete-pending transition failed (Win32=$code): $q" }}
        $guard.Handle.Dispose()
        $guard.Handle = $null
        if (Test-Path -LiteralPath $q) {{ throw "$Label exact quarantine remained after handle deletion: $q" }}
    }}
    catch {{
        $e = $_
        if (-not $deleteStarted -and $renamed -and $null -ne $guard.Handle -and -not $guard.Handle.IsClosed -and -not (Test-Path -LiteralPath $Path)) {{
            try {{ Move-HmsUninstallDirectoryGuard -Guard $guard -Destination $Path -Label "$Label pre-delete rollback" }} catch {{}}
        }}
        elseif ($deleteStarted -and (Test-Path -LiteralPath $q)) {{
            throw "$Label deletion failed after destructive child removal started; exact quarantined remainder was not restored: $q. Original: $($e.Exception.Message)"
        }}
        throw $e
    }}
    finally {{ if ($null -ne $guard -and $null -ne $guard.Handle) {{ $guard.Handle.Dispose() }} }}
}}'''

    text = replace_function(text, invoke_name, new)
    if forbidden in text:
        raise RuntimeError(f"root-recursive quarantine deletion survived hardening in {rel}")
    if text.count(f"function {portable_name} {{") != 1:
        raise RuntimeError(f"portable identity helper was not inserted exactly once in {rel}")
    if "Remove-Item -LiteralPath $q -Force -ErrorAction Stop" not in text:
        raise RuntimeError(f"empty-root nonrecursive deletion missing in {rel}")
    write(rel, text)


harden(
    "scripts/Sync-DeliveryTools.ps1",
    "Invoke-HmsDeliveryExactDirectoryRemoval",
    "Get-HmsDeliveryPortableDirectoryIdentity",
    "QuarantinePrefix",
)
harden(
    "uninstall.ps1",
    "Invoke-HmsUninstallExactDirectoryRemoval",
    "Get-HmsUninstallPortableDirectoryIdentity",
    "Prefix",
)

print("PASS: non-Windows delivery/uninstall quarantine cleanup now binds device/inode identity and never recursively deletes the root pathname.")
