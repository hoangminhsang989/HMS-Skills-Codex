from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = "2d2558648f3f8f62194ce45b8d7d1f4886ea9cf9"
BLOBS = {
    "manager/HmsModelSettings.utf8.ps1": "acf84c232b09ef7b5471ce0732358752842a7f64",
    "scripts/Test-HmsLateTrustBoundaries.ps1": "0e2ece28bb567fb51d1fa48396c9df9d19c5c0d9",
}

def git(*args):
    return subprocess.check_output(["git","-C",str(ROOT),*args],text=True).strip()

def req(c,m):
    if not c: raise RuntimeError(m)

def rep(text,old,new,label):
    n=text.count(old); req(n==1,f"{label}: expected 1 occurrence, found {n}")
    return text.replace(old,new,1)

def read(rel): return (ROOT/rel).read_text(encoding="utf-8")
def write(rel,text): (ROOT/rel).write_text(text,encoding="utf-8",newline="\n")

req(subprocess.run(["git","-C",str(ROOT),"merge-base","--is-ancestor",BASE,"HEAD"]).returncode==0,"2d255 baseline must be an ancestor")
for rel,blob in BLOBS.items(): req(git("rev-parse",f"HEAD:{rel}").lower()==blob,f"baseline blob mismatch: {rel}")

rel="manager/HmsModelSettings.utf8.ps1"
t=read(rel)
old='''    [DllImport("kernel32.dll", SetLastError = true)]\n    [return: MarshalAs(UnmanagedType.Bool)]\n    private static extern bool SetFileInformationByHandle(SafeFileHandle hFile, int infoClass, IntPtr info, uint size);\n\n'''
new='''    [DllImport("kernel32.dll", SetLastError = true)]\n    [return: MarshalAs(UnmanagedType.Bool)]\n    private static extern bool SetFileInformationByHandle(SafeFileHandle hFile, int infoClass, IntPtr info, uint size);\n    [DllImport("kernel32.dll", SetLastError = true)]\n    [return: MarshalAs(UnmanagedType.Bool)]\n    private static extern bool GetFileSizeEx(SafeFileHandle hFile, out long fileSize);\n    [DllImport("kernel32.dll", SetLastError = true)]\n    [return: MarshalAs(UnmanagedType.Bool)]\n    private static extern bool SetFilePointerEx(SafeFileHandle hFile, long distance, out long newPosition, uint moveMethod);\n    [DllImport("kernel32.dll", SetLastError = true)]\n    [return: MarshalAs(UnmanagedType.Bool)]\n    private static extern bool ReadFile(SafeFileHandle hFile, IntPtr buffer, uint bytesToRead, out uint bytesRead, IntPtr overlapped);\n\n'''
t=rep(t,old,new,"native guarded read imports")
anchor='''    public static bool RenameHmsModelSettingsFileByHandle(SafeFileHandle handle, string destination, out int error)\n'''
method='''    public static byte[] ReadAllHmsModelSettingsBytes(SafeFileHandle handle, out int error)\n    {\n        long size;\n        if (!GetFileSizeEx(handle, out size)) { error = Marshal.GetLastWin32Error(); return null; }\n        if (size < 0 || size > 1048576) { error = 223; return null; } // ERROR_FILE_TOO_LARGE / bounded settings contract.\n        long position;\n        if (!SetFilePointerEx(handle, 0, out position, 0)) { error = Marshal.GetLastWin32Error(); return null; }\n        byte[] result = new byte[(int)size];\n        if (size == 0) { error = 0; return result; }\n        IntPtr buffer = Marshal.AllocHGlobal((int)size);\n        try\n        {\n            int offset = 0;\n            while (offset < result.Length)\n            {\n                uint read;\n                uint remaining = (uint)(result.Length - offset);\n                if (!ReadFile(handle, IntPtr.Add(buffer, offset), remaining, out read, IntPtr.Zero))\n                {\n                    error = Marshal.GetLastWin32Error();\n                    return null;\n                }\n                if (read == 0) { error = 38; return null; } // ERROR_HANDLE_EOF: exact bytes changed/truncated unexpectedly.\n                offset += (int)read;\n            }\n            Marshal.Copy(buffer, result, 0, result.Length);\n            error = 0;\n            return result;\n        }\n        finally { Marshal.FreeHGlobal(buffer); }\n    }\n\n'''
t=rep(t,anchor,method+anchor,"native guarded read method")

anchor2='''function Move-HmsModelSettingsFileGuard {\n'''
helpers='''function Read-HmsModelSettingsTextFromGuard {\n    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)\n    if ($null -eq $Guard.Handle -or $Guard.Handle.IsClosed -or $Guard.Handle.IsInvalid) { throw "$Label exact settings guard is unavailable for read." }\n    $identity = Get-HmsModelSettingsIdentityFromHandle -Handle $Guard.Handle -Label $Label\n    if ($identity -cne [string]$Guard.Identity) { throw "$Label exact settings identity changed before guarded read." }\n    $errorCode = 0\n    $bytes = [HmsModelSettingsNative]::ReadAllHmsModelSettingsBytes($Guard.Handle,[ref]$errorCode)\n    if ($null -eq $bytes) { throw "$Label exact settings bytes could not be read through the locked handle (Win32=$errorCode)." }\n    $strict = New-Object System.Text.UTF8Encoding($false,$true)\n    try { return $strict.GetString([byte[]]$bytes) }\n    catch { throw "$Label exact settings bytes are not valid UTF-8: $($_.Exception.Message)" }\n}\n\n'''
t=rep(t,anchor2,helpers+anchor2,"guarded text helper")

oldread='''function Read-ModelState-Unserialized {\n    param([string]$Path = $SettingsPath)\n\n    if (-not (Test-Path -LiteralPath $Path)) { return New-DefaultModelState }\n    Assert-RegularSettingsFile -Path $Path\n\n    try { $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }\n    catch { throw "Model settings are invalid JSON: $($_.Exception.Message)" }\n\n    if ($null -eq $settings.PSObject.Properties['schema_version']) { throw 'Model settings are missing schema_version.' }\n    Assert-ExactSchemaVersionOne -Value $settings.schema_version\n    if ([string]$settings.managed_by -cne 'HMS-Skills-Codex') { throw 'Model settings ownership mismatch.' }\n    if ([string]$settings.artifact -cne 'hms-model-settings') { throw 'Model settings artifact mismatch.' }\n    if ($null -eq $settings.models) { throw 'Model settings are missing models.' }\n\n    $state = [ordered]@{}\n    foreach ($key in @('luna','terra','sol')) {\n        $property = $settings.models.PSObject.Properties[$key]\n        if ($null -eq $property) { throw "Model settings are missing '$key'." }\n        if ($property.Value -isnot [bool]) { throw "Model setting '$key' must be boolean." }\n        $state[$key] = $property.Value\n    }\n    return $state\n}\n'''
newread='''function Convert-ModelSettingsTextToState {\n    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Label)\n    try { $settings = $Text | ConvertFrom-Json }\n    catch { throw "$Label are invalid JSON: $($_.Exception.Message)" }\n    if ($null -eq $settings.PSObject.Properties['schema_version']) { throw 'Model settings are missing schema_version.' }\n    Assert-ExactSchemaVersionOne -Value $settings.schema_version\n    if ([string]$settings.managed_by -cne 'HMS-Skills-Codex') { throw 'Model settings ownership mismatch.' }\n    if ([string]$settings.artifact -cne 'hms-model-settings') { throw 'Model settings artifact mismatch.' }\n    if ($null -eq $settings.models) { throw 'Model settings are missing models.' }\n    $state = [ordered]@{}\n    foreach ($key in @('luna','terra','sol')) {\n        $property = $settings.models.PSObject.Properties[$key]\n        if ($null -eq $property) { throw "Model settings are missing '$key'." }\n        if ($property.Value -isnot [bool]) { throw "Model setting '$key' must be boolean." }\n        $state[$key] = $property.Value\n    }\n    return $state\n}\n\nfunction Read-ModelStateFromGuard {\n    param([Parameter(Mandatory)]$Guard,[Parameter(Mandatory)][string]$Label)\n    $text = Read-HmsModelSettingsTextFromGuard -Guard $Guard -Label $Label\n    return Convert-ModelSettingsTextToState -Text $text -Label $Label\n}\n\nfunction Read-ModelState-Unserialized {\n    param([string]$Path = $SettingsPath)\n    if (-not (Test-Path -LiteralPath $Path)) { return New-DefaultModelState }\n    Assert-RegularSettingsFile -Path $Path\n    try { $text = [IO.File]::ReadAllText($Path,(New-Object System.Text.UTF8Encoding($false,$true))) }\n    catch { throw "Model settings could not be read: $($_.Exception.Message)" }\n    return Convert-ModelSettingsTextToState -Text $text -Label 'Model settings'\n}\n'''
t=rep(t,oldread,newread,"factor guarded/path model-state parser")

t=rep(t,"            $null = Read-ModelState-Unserialized -Path $Path\n            $hadExisting = $true\n","            $null = Read-ModelStateFromGuard -Guard $existingGuard -Label 'Existing model settings'\n            $hadExisting = $true\n","existing guarded validation")
t=rep(t,"        $actualCandidateText = [IO.File]::ReadAllText($temp,$utf8)\n        if ($actualCandidateText -cne $json) { throw 'Candidate model settings bytes changed before publication.' }\n        $null = Read-ModelState-Unserialized -Path $temp\n","        $actualCandidateText = Read-HmsModelSettingsTextFromGuard -Guard $candidateGuard -Label 'Candidate model settings'\n        if ($actualCandidateText -cne $json) { throw 'Candidate model settings bytes changed before publication.' }\n        $null = Read-ModelStateFromGuard -Guard $candidateGuard -Label 'Candidate model settings'\n","candidate guarded validation")
t=rep(t,"        $verified = Read-ModelState-Unserialized -Path $Path\n","        $verified = Read-ModelStateFromGuard -Guard $candidateGuard -Label 'Published candidate model settings'\n","published guarded verification")
t=rep(t,"                $null = Read-ModelState-Unserialized -Path $Path\n                $existingGuard.Handle.Dispose();","                $null = Read-ModelStateFromGuard -Guard $existingGuard -Label 'Restored previous model settings'\n                $existingGuard.Handle.Dispose();","restored guarded verification")
write(rel,t)

rel2="scripts/Test-HmsLateTrustBoundaries.ps1"
t=read(rel2)
needle="Write-Host 'PASS: validated Model Settings file is pinned against foreign rename and moved/deleted only through its exact handle.'\n\n# Resolver must not observe the writer's deliberate canonical-path gap.\n"
add="Write-Host 'PASS: validated Model Settings file is pinned against foreign rename and moved/deleted only through its exact handle.'\n\n# Run the production UTF-8 implementation self-test directly so exact-handle sharing/read compatibility\n# is qualified before the public lifecycle workflows. This uses only temp settings files.\n& $modelPath -SelfTest\nWrite-Host 'PASS: direct Model Settings self-test is compatible with exact guarded reads/writes.'\n\n# Resolver must not observe the writer's deliberate canonical-path gap.\n"
t=rep(t,needle,add,"direct model settings selftest regression")
write(rel2,t)

req("ReadAllHmsModelSettingsBytes" in read("manager/HmsModelSettings.utf8.ps1"),"guarded native read missing")
req("Read-ModelStateFromGuard -Guard $existingGuard" in read("manager/HmsModelSettings.utf8.ps1"),"existing guarded state read missing")
req("& $modelPath -SelfTest" in read(rel2),"direct model selftest missing")
print("PASS: patched exact-handle Model Settings reads and direct permanent self-test.")
