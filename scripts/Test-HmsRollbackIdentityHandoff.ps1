[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'SKIP: rollback identity handoff regression requires Windows filesystem semantics.'
    return
}

$deliveryPath = Join-Path $RepoRoot 'scripts\Sync-DeliveryTools.ps1'
$compositePath = Join-Path $RepoRoot 'scripts\Build-HmsCompositeSkill.impl.ps1'
foreach ($path in @($deliveryPath,$compositePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Rollback identity regression source is missing: $path" }
}

function Get-FunctionText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $tokens=$null
    $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "PowerShell parser rejected $Path : $((@($errors) | ForEach-Object { $_.Message }) -join ' | ')"
    }
    $nodes=@($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name
    },$true))
    if ($nodes.Count -ne 1) { throw "Expected exactly one function '$Name' in $Path, found $($nodes.Count)." }
    return $nodes[0].Extent.Text
}

$deliveryText=[IO.File]::ReadAllText($deliveryPath)
if ($deliveryText -notmatch [regex]::Escape('-PreviousIdentityRef ([ref]$previousIdentity)')) {
    throw 'Production CodeGraph transition does not hand previous identity to caller-visible state before mutation.'
}
$compositeText=[IO.File]::ReadAllText($compositePath)
if ($compositeText -notmatch [regex]::Escape('-ReservedPathRef ([ref]$reservedBackup)')) {
    throw 'Production composite reservation does not hand the random reservation path to caller-visible state before post-rename validation.'
}

# P1 regression A: execute the production CodeGraph transition helper with an injected exact-handle
# rename failure after its marker rewrite. Caller-visible previous identity must already be populated, and
# the helper must restore the original candidate-role marker while current remains in place.
$moveFunctionText=Get-FunctionText -Path $deliveryPath -Name 'Move-CodeGraphCurrentToRollbackBackup'
Invoke-Expression $moveFunctionText

$caseA=Join-Path ([IO.Path]::GetTempPath()) ('hms-codegraph-identity-handoff-'+[guid]::NewGuid().ToString('N'))
$currentA=Join-Path $caseA 'current'
$backupA=Join-Path $caseA 'backup'
New-Item -ItemType Directory -Force -Path $currentA | Out-Null

$script:PreviousIdentity=[ordered]@{
    managed_by='HMS-Skills-Codex'
    artifact='hms-codegraph-transaction-bundle'
    transaction_id='11111111111111111111111111111111'
    role='candidate'
    version='old'
    tag='v-old'
    commit='old-commit'
    asset='old.zip'
    sha256=('a' * 64)
    bundle_tree_sha256=('b' * 64)
}
$backupIdentity=[ordered]@{
    managed_by='HMS-Skills-Codex'
    artifact='hms-codegraph-transaction-bundle'
    transaction_id='22222222222222222222222222222222'
    role='backup'
    version='old'
    tag='v-old'
    commit='old-commit'
    asset='old.zip'
    sha256=('a' * 64)
    bundle_tree_sha256=('b' * 64)
}
$script:MarkerIdentity=$script:PreviousIdentity

function Assert-CodeGraphBundleAgainstManifest {
    param([string]$Path,$Manifest)
    return $script:PreviousIdentity
}
function Write-CodeGraphBundleMarker {
    param([string]$Path,$Identity)
    $script:MarkerIdentity=$Identity
}
function Assert-CodeGraphTransactionBundle {
    param([string]$Path,$Identity)
    if ([string]$script:MarkerIdentity.transaction_id -cne [string]$Identity.transaction_id -or
        [string]$script:MarkerIdentity.role -cne [string]$Identity.role) {
        throw "Injected marker identity mismatch at $Path"
    }
}
function Open-HmsDeliveryDirectoryGuard {
    param([string]$Path,[string]$Label)
    if ($Path -cne $currentA) { throw "Injected CodeGraph guard opened an unexpected path: $Path" }
    return [pscustomobject]@{
        Path = $Path
        Identity = 'injected-current-directory'
        Handle = [IO.MemoryStream]::new()
    }
}
function Move-HmsDeliveryDirectoryGuard {
    param($Guard,[string]$Destination,[string]$Label)
    if ([string]$Guard.Path -ceq $currentA -and $Destination -ceq $backupA) {
        throw 'Injected Windows current-to-backup exact-handle rename failure after marker rewrite.'
    }
    throw "Injected CodeGraph guard received an unexpected transition: $($Guard.Path) -> $Destination"
}


$capturedPrevious=$null
$failedA=$false
try {
    Move-CodeGraphCurrentToRollbackBackup -CurrentPath $currentA -BackupPath $backupA -ExistingManifest ([ordered]@{}) -BackupIdentity $backupIdentity -PreviousIdentityRef ([ref]$capturedPrevious) | Out-Null
}
catch {
    $failedA=$true
}
finally {
    Remove-Item -LiteralPath Function:\Open-HmsDeliveryDirectoryGuard -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Move-HmsDeliveryDirectoryGuard -Force -ErrorAction SilentlyContinue
}
try {
    if (-not $failedA) { throw 'Injected CodeGraph post-marker/pre-rename failure did not fail.' }
    if ($null -eq $capturedPrevious) { throw 'Caller-visible previous CodeGraph identity remained null after authenticated marker mutation.' }
    if ([string]$capturedPrevious.transaction_id -cne [string]$script:PreviousIdentity.transaction_id -or [string]$capturedPrevious.role -cne 'candidate') {
        throw 'Caller-visible previous CodeGraph identity did not retain the original candidate identity.'
    }
    if ([string]$script:MarkerIdentity.transaction_id -cne [string]$script:PreviousIdentity.transaction_id -or [string]$script:MarkerIdentity.role -cne 'candidate') {
        throw 'CodeGraph helper did not restore the original marker after pre-rename failure.'
    }
    if (-not (Test-Path -LiteralPath $currentA -PathType Container)) { throw 'CodeGraph current disappeared during injected pre-rename failure.' }
    if (Test-Path -LiteralPath $backupA) { throw 'CodeGraph backup appeared despite injected rename failure.' }
}
finally {
    Remove-Item -LiteralPath $caseA -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Assert-CodeGraphBundleAgainstManifest -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Write-CodeGraphBundleMarker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Assert-CodeGraphTransactionBundle -Force -ErrorAction SilentlyContinue
}

# P1 regression B: execute the production composite reservation/restore helpers with an injected
# failure on the first post-rename validation. The caller must already know the random reservation
# pathname, and the production restore helper must be able to put that exact object back.
$reserveFunctionText=Get-FunctionText -Path $compositePath -Name 'Reserve-OwnedCompositeRollbackBackup'
$restoreFunctionText=Get-FunctionText -Path $compositePath -Name 'Restore-OwnedCompositeRollbackBackup'
Invoke-Expression $reserveFunctionText
Invoke-Expression $restoreFunctionText

# This regression isolates caller-visible reservation handoff semantics. The
# exact Win32 directory-handle primitive is independently exercised by the
# destructive/late-trust regressions. Mock only the two newly factored helper
# dependencies while executing the production Reserve/Restore functions byte-for-byte.
function Open-HmsCompositeDirectoryGuard {
    param([string]$Path,[string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Injected composite exact guard source is missing: $Path"
    }
    return [pscustomobject]@{
        Path = $Path
        Handle = [IO.MemoryStream]::new()
    }
}
function Move-HmsCompositeDirectoryGuard {
    param($Guard,[string]$Destination,[string]$Label)
    if (Test-Path -LiteralPath $Destination) {
        throw "Injected composite exact guard destination is occupied: $Destination"
    }
    Rename-Item -LiteralPath $Guard.Path -NewName (Split-Path -Leaf $Destination) -ErrorAction Stop
    $Guard.Path = $Destination
}

$caseB=Join-Path ([IO.Path]::GetTempPath()) ('hms-composite-reservation-handoff-'+[guid]::NewGuid().ToString('N'))
$backupB=Join-Path $caseB 'backup'
$finalB=Join-Path $caseB 'hms-superpowers'
New-Item -ItemType Directory -Force -Path $backupB | Out-Null
$sentinelB=Join-Path $backupB 'OLD.txt'
[IO.File]::WriteAllText($sentinelB,'old exact composite',[Text.Encoding]::UTF8)
$expectedTree=('c' * 64)
$script:FailReservedValidationOnce=$true

function Assert-OwnedCompositeIdentity {
    param([string]$Path,[string]$ExpectedTreeSha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Injected composite identity path is missing: $Path" }
    if ($script:FailReservedValidationOnce -and (Split-Path -Leaf $Path) -match '^\.hms-composite-rollback-reserved-[0-9a-f]{32}$') {
        $script:FailReservedValidationOnce=$false
        throw 'Injected transient composite post-rename identity validation failure.'
    }
}

$capturedReserved=$null
$failedB=$false
try {
    Reserve-OwnedCompositeRollbackBackup -Path $backupB -ExpectedTreeSha256 $expectedTree -ReservedPathRef ([ref]$capturedReserved) | Out-Null
}
catch {
    $failedB=$true
}
try {
    if (-not $failedB) { throw 'Injected composite post-rename identity validation failure did not fail.' }
    if ([string]::IsNullOrWhiteSpace([string]$capturedReserved)) { throw 'Caller-visible composite reservation pathname remained null after successful rename.' }
    if ((Split-Path -Leaf $capturedReserved) -notmatch '^\.hms-composite-rollback-reserved-[0-9a-f]{32}$') {
        throw "Caller-visible composite reservation pathname is not the random HMS reservation: $capturedReserved"
    }
    if (-not (Test-Path -LiteralPath $capturedReserved -PathType Container)) { throw 'Exact reserved composite object is not present after injected validation failure.' }
    if (Test-Path -LiteralPath $backupB) { throw 'Predictable composite backup pathname remained occupied after reservation rename.' }

    Restore-OwnedCompositeRollbackBackup -BackupPath $backupB -ReservedPath $capturedReserved -FinalPath $finalB -ExpectedTreeSha256 $expectedTree
    if (-not (Test-Path -LiteralPath $finalB -PathType Container)) { throw 'Composite restore did not recover FinalRoot from caller-visible reservation.' }
    if (Test-Path -LiteralPath $capturedReserved) { throw 'Composite reservation remained after successful exact restoration.' }
    if (([IO.File]::ReadAllText((Join-Path $finalB 'OLD.txt'))) -cne 'old exact composite') { throw 'Composite restoration did not recover the exact reserved previous bytes.' }
}
finally {
    Remove-Item -LiteralPath $caseB -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Assert-OwnedCompositeIdentity -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Open-HmsCompositeDirectoryGuard -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Move-HmsCompositeDirectoryGuard -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: CodeGraph previous-identity handoff and composite rollback reservation survive post-mutation transition failures.'