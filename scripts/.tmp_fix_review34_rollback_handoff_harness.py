from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts" / "Test-HmsRollbackIdentityHandoff.ps1"
text = PATH.read_text(encoding="utf-8")

anchor = """$reserveFunctionText=Get-FunctionText -Path $compositePath -Name 'Reserve-OwnedCompositeRollbackBackup'\n$restoreFunctionText=Get-FunctionText -Path $compositePath -Name 'Restore-OwnedCompositeRollbackBackup'\nInvoke-Expression $reserveFunctionText\nInvoke-Expression $restoreFunctionText\n\n"""
if text.count(anchor) != 1:
    raise RuntimeError("rollback handoff production-function anchor changed")

mock_block = r'''$reserveFunctionText=Get-FunctionText -Path $compositePath -Name 'Reserve-OwnedCompositeRollbackBackup'
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

'''
text = text.replace(anchor, mock_block, 1)

cleanup_line = "    Remove-Item -LiteralPath Function:\\Assert-OwnedCompositeIdentity -Force -ErrorAction SilentlyContinue"
if text.count(cleanup_line) != 1:
    raise RuntimeError("rollback handoff cleanup line changed")
cleanup_new = "\n".join((
    cleanup_line,
    "    Remove-Item -LiteralPath Function:\\Open-HmsCompositeDirectoryGuard -Force -ErrorAction SilentlyContinue",
    "    Remove-Item -LiteralPath Function:\\Move-HmsCompositeDirectoryGuard -Force -ErrorAction SilentlyContinue",
))
text = text.replace(cleanup_line, cleanup_new, 1)

for literal in (
    "Invoke-Expression $reserveFunctionText",
    "Invoke-Expression $restoreFunctionText",
    "function Open-HmsCompositeDirectoryGuard",
    "function Move-HmsCompositeDirectoryGuard",
    "Caller-visible composite reservation pathname remained null after successful rename.",
    "Function:\\Open-HmsCompositeDirectoryGuard",
    "Function:\\Move-HmsCompositeDirectoryGuard",
):
    if text.count(literal) != 1:
        raise RuntimeError(f"rollback handoff regression contract is not unique: {literal}")

PATH.write_text(text, encoding="utf-8", newline="\n")
print("PASS: rollback handoff regression now supplies only the newly factored exact-guard dependencies.")
