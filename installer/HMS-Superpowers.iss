#define MyAppName "HMS Superpowers"
#define MyAppVersion "0.3.0"
#define MyAppExeName "HMS-Superpowers.exe"
#define MySetupBaseName "HMS-Superpowers-Setup-v0.3.0"

[Setup]
AppId={{0F79350C-96D6-4DF6-9A2A-95244DC44C6C}
AppName={#MyAppName}
AppVersion=0.3.0
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=HMS
AppPublisherURL=https://github.com/hoangminhsang989/HMS-Skills-Codex
DefaultDirName={localappdata}\Programs\HMS Superpowers
DefaultGroupName=HMS Superpowers
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\artifacts\windows-setup
OutputBaseFilename=HMS-Superpowers-Setup-v0.3.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
ChangesEnvironment=no
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &Desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Files]
; Menu payload produced by the exact-head Windows build.
Source: "..\desktop\HmsSuperpowers\bin\Release\net10.0-windows\win-x64\publish\HMS-Superpowers.exe"; DestDir: "{app}"; DestName: "{#MyAppExeName}"; Flags: ignoreversion

; Persist Setup-owned bootstrap inputs for diagnostics/provenance and future qualified repair wiring.
Source: "Invoke-HmsSetupBootstrap.ps1"; DestDir: "{app}\setup"; Flags: ignoreversion
Source: "setup-tools.lock.json"; DestDir: "{app}\setup"; Flags: ignoreversion
Source: "generated\setup-authority.json"; DestDir: "{app}\setup"; Flags: ignoreversion

; The same exact packaged bytes are staged to {tmp} before installation. Setup does not
; copy the application or create success shortcuts unless this bootstrap succeeds.
Source: "Invoke-HmsSetupBootstrap.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "setup-tools.lock.json"; DestDir: "{tmp}"; Flags: dontcopy
Source: "generated\setup-authority.json"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{group}\HMS Superpowers"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Check: BootstrapReady
Name: "{group}\Uninstall HMS Superpowers"; Filename: "{uninstallexe}"; Check: BootstrapReady
Name: "{autodesktop}\HMS Superpowers"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon; Check: BootstrapReady

[Code]
var
  BootstrapSucceeded: Boolean;

function BootstrapReady(): Boolean;
begin
  Result := BootstrapSucceeded;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  PowerShellPath: String;
  BootstrapPath: String;
  AuthorityPath: String;
  ToolsLockPath: String;
  Params: String;
  ResultCode: Integer;
  Started: Boolean;
begin
  Result := '';
  BootstrapSucceeded := False;

  ExtractTemporaryFile('Invoke-HmsSetupBootstrap.ps1');
  ExtractTemporaryFile('setup-tools.lock.json');
  ExtractTemporaryFile('setup-authority.json');

  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  BootstrapPath := ExpandConstant('{tmp}\Invoke-HmsSetupBootstrap.ps1');
  ToolsLockPath := ExpandConstant('{tmp}\setup-tools.lock.json');
  AuthorityPath := ExpandConstant('{tmp}\setup-authority.json');

  if not FileExists(PowerShellPath) then
  begin
    Result := 'HMS Setup requires Windows PowerShell 5.1.';
    Exit;
  end;

  if (not FileExists(BootstrapPath)) or (not FileExists(ToolsLockPath)) or (not FileExists(AuthorityPath)) then
  begin
    Result := 'HMS Setup could not stage its verified bootstrap inputs.';
    Exit;
  end;

  WizardForm.StatusLabel.Caption := 'Preparing verified HMS support tools and source...';
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + BootstrapPath +
    '" -AuthorityPath "' + AuthorityPath + '" -ToolsLockPath "' + ToolsLockPath + '" -Mode Install';

  Started := Exec(PowerShellPath, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Started then
  begin
    Result := 'HMS verified bootstrap could not be started. Setup has not installed the application or shortcuts.';
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    Result := 'HMS verified bootstrap failed with exit code ' + IntToStr(ResultCode) +
      '. Setup has not installed the application or shortcuts.';
    Exit;
  end;

  BootstrapSucceeded := True;
end;
