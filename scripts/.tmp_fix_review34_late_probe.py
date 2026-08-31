from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / 'scripts' / 'Test-HmsLateTrustBoundaries.ps1'
text = path.read_text(encoding='utf-8')
start_marker = '# Permanent destructive primitive proof: the production public builder exact-directory guard denies'
end_marker = "Write-Host 'PASS: exact DELETE-capable directory guards deny hostile root rename through destructive transitions.'"
start = text.find(start_marker)
end = text.find(end_marker, start)
if start < 0 or end < 0:
    raise RuntimeError('review34 runtime probe markers not found after main patcher')
end += len(end_marker)
replacement = r"""# Permanent destructive primitive proof: a DELETE-capable directory handle opened without
# FILE_SHARE_DELETE must keep the exact validated root non-renamable by a foreign process.
if (-not ('HmsLateExactRootProbeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class HmsLateExactRootProbeNative
{
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr sa,uint creation,uint flags,IntPtr template);
}
'@
}
$probeRoot = Join-Path $env:TEMP ('hms-review34-root-lock-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
Set-Content -LiteralPath (Join-Path $probeRoot 'sentinel.txt') -Value 'owned' -Encoding UTF8
$probeHandle = [HmsLateExactRootProbeNative]::CreateFileW(
    $probeRoot,
    [uint32]0x00010000,
    [uint32]3,
    [IntPtr]::Zero,
    [uint32]3,
    [uint32]0x02200000,
    [IntPtr]::Zero
)
if ($null -eq $probeHandle -or $probeHandle.IsInvalid) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($null -ne $probeHandle) { $probeHandle.Dispose() }
    throw "Review34 exact-root probe could not open DELETE-capable directory handle (Win32=$code)."
}
$probeJob = $null
try {
    $probeJob = Start-Job -ScriptBlock {
        param($Path)
        try {
            Rename-Item -LiteralPath $Path -NewName ('foreign-' + [guid]::NewGuid().ToString('N')) -ErrorAction Stop
            return $true
        }
        catch { return $false }
    } -ArgumentList $probeRoot
    $null = Wait-Job -Job $probeJob -Timeout 20
    if ($probeJob.State -ne 'Completed') { throw 'Exact-root hostile rename probe did not complete.' }
    if ([bool](Receive-Job -Job $probeJob -ErrorAction Stop)) { throw 'Foreign process renamed a DELETE-guarded exact root.' }
}
finally {
    if ($null -ne $probeJob) { Remove-Job -Job $probeJob -Force -ErrorAction SilentlyContinue }
    $probeHandle.Dispose()
    Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: exact DELETE-capable directory guards deny hostile root rename through destructive transitions.'"""
text = (text[:start] + replacement + text[end:]).rstrip() + '\n'
path.write_text(text, encoding='utf-8', newline='\n')
print('PASS: replaced cross-script helper injection with self-contained exact-root probe and normalized EOF whitespace.')
