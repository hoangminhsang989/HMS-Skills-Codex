@echo off
setlocal EnableExtensions DisableDelayedExpansion

if "%~1"=="" goto :usage
if not "%~2"=="" goto :usage

if /I "%~1"=="update" (
  set "HMS_LIFECYCLE_ACTION=update"
) else if /I "%~1"=="repair" (
  set "HMS_LIFECYCLE_ACTION=repair"
) else if /I "%~1"=="uninstall" (
  set "HMS_LIFECYCLE_ACTION=uninstall"
) else (
  goto :usage
)

set "HMS_LIFECYCLE_ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $root=[IO.Path]::GetFullPath($env:HMS_LIFECYCLE_ROOT).TrimEnd([char]92); if(-not (Test-Path -LiteralPath (Join-Path $root '.git'))){throw 'Lifecycle launcher expected an HMS Git checkout.'}; $git=@((Get-Command git.exe -CommandType Application -ErrorAction Stop))[0].Source; $head=((& $git -C $root rev-parse HEAD 2>$null)-join '').Trim().ToLowerInvariant(); if($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$'){throw 'Lifecycle launcher could not resolve a canonical HMS HEAD.'}; $spec=$head+':scripts/Invoke-HmsLifecycleAction.ps1'; $expected=((& $git -C $root rev-parse $spec 2>$null)-join '').Trim().ToLowerInvariant(); if($LASTEXITCODE -ne 0 -or $expected -notmatch '^[0-9a-f]{40}$'){throw 'Lifecycle launcher could not resolve the committed lifecycle shim blob.'}; $type=((& $git -C $root cat-file -t $expected 2>$null)-join '').Trim().ToLowerInvariant(); if($LASTEXITCODE -ne 0 -or $type -cne 'blob'){throw 'Lifecycle launcher expected a committed blob for the lifecycle shim.'}; $path=Join-Path $root 'scripts\Invoke-HmsLifecycleAction.ps1'; $item=Get-Item -LiteralPath $path -Force; if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Lifecycle launcher rejected a reparse-point shim.'}; $fs=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); try{if($fs.Length -gt [int]::MaxValue){throw 'Lifecycle shim is too large.'}; $bytes=New-Object byte[] ([int]$fs.Length); $offset=0; while($offset -lt $bytes.Length){$n=$fs.Read($bytes,$offset,$bytes.Length-$offset); if($n -le 0){throw 'Lifecycle shim ended before snapshot completion.'}; $offset+=$n}}finally{$fs.Dispose()}; $header=[Text.Encoding]::ASCII.GetBytes(('blob '+[string]$bytes.Length+[char]0)); $sha=[Security.Cryptography.SHA1]::Create(); $ms=New-Object IO.MemoryStream; try{$ms.Write($header,0,$header.Length); if($bytes.Length -gt 0){$ms.Write($bytes,0,$bytes.Length)}; $ms.Position=0; $actual=(($sha.ComputeHash($ms)|ForEach-Object{$_.ToString('x2')})-join '')}finally{$ms.Dispose();$sha.Dispose()}; if($actual -cne $expected){throw ('Lifecycle launcher rejected uncommitted shim bytes. Expected '+$expected+', found '+$actual+'.')}; $source=(New-Object System.Text.UTF8Encoding($false,$true)).GetString($bytes); $script=[ScriptBlock]::Create($source); & $script -Action $env:HMS_LIFECYCLE_ACTION -TrustedRepoRoot $root -TrustedHead $head -TrustedBootstrapBlob $expected"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo HMS lifecycle action exited with an error.
exit /b %RC%

:usage
echo Usage: HMS-Lifecycle.cmd ^<update^|repair^|uninstall^>
exit /b 64
