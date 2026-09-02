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
const
  FILE_ATTRIBUTE_DIRECTORY = $10;
  FILE_ATTRIBUTE_REPARSE_POINT = $400;
  INVALID_FILE_ATTRIBUTES = $FFFFFFFF;

var
  BootstrapSucceeded: Boolean;

function SetProcessEnvironmentVariable(Name: String; Value: String): Boolean;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';
function GetFileAttributesW(lpFileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function BootstrapReady(): Boolean;
begin
  Result := BootstrapSucceeded;
end;

function IsReparsePoint(const Path: String): Boolean;
var
  Attributes: Cardinal;
begin
  Attributes := GetFileAttributesW(Path);
  if Attributes = INVALID_FILE_ATTRIBUTES then
    RaiseException('Unable to inspect Setup-owned path attributes: ' + Path);
  Result := (Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0;
end;

procedure AssertTreeHasNoReparsePoints(const Directory: String);
var
  FindRec: TFindRec;
  Child: String;
begin
  if IsReparsePoint(Directory) then
    RaiseException('Refusing support cleanup through a reparse-point directory: ' + Directory);

  if FindFirst(AddBackslash(Directory) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          Child := AddBackslash(Directory) + FindRec.Name;
          if (FindRec.Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
            RaiseException('Refusing support cleanup because a reparse point exists: ' + Child);
          if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
            AssertTreeHasNoReparsePoints(Child);
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

procedure AssertOwnedSupportDirectory(const Directory: String; const Kind: String);
var
  MarkerPath: String;
  MarkerText: AnsiString;
begin
  if not DirExists(Directory) then
    RaiseException('Expected Setup-owned support directory is missing: ' + Directory);
  AssertTreeHasNoReparsePoints(Directory);

  MarkerPath := AddBackslash(Directory) + '.hms-owned-support-v1.json';
  if (not FileExists(MarkerPath)) or IsReparsePoint(MarkerPath) then
    RaiseException('Setup-owned support marker is missing or unsafe: ' + MarkerPath);
  if not LoadStringFromFile(MarkerPath, MarkerText) then
    RaiseException('Unable to read Setup-owned support marker: ' + MarkerPath);
  if (Pos('"owner"', MarkerText) = 0) or
     (Pos('HMS Superpowers', MarkerText) = 0) or
     (Pos('"kind"', MarkerText) = 0) or
     (Pos(Kind, MarkerText) = 0) then
    RaiseException('Setup-owned support marker identity mismatch: ' + MarkerPath);
end;

procedure RemoveVerifiedSupportDirectory(const Directory: String; const Kind: String);
begin
  AssertOwnedSupportDirectory(Directory, Kind);
  if not DelTree(Directory, True, True, True) then
    RaiseException('Unable to remove verified Setup-owned support directory: ' + Directory);
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

procedure RunHmsLifecycleUninstall();
var
  RepoRoot: String;
  Launcher: String;
  CmdExe: String;
  OldPath: String;
  ChildPath: String;
  Params: String;
  ResultCode: Integer;
  Started: Boolean;
begin
  RepoRoot := AddBackslash(GetEnv('USERPROFILE')) + '.codex\hms-skills-codex';
  Launcher := AddBackslash(RepoRoot) + 'HMS-Lifecycle.cmd';
  CmdExe := ExpandConstant('{sys}\cmd.exe');

  if (GetEnv('USERPROFILE') = '') or (not DirExists(RepoRoot)) or (not FileExists(Launcher)) then
    RaiseException('HMS source/lifecycle authority is unavailable; refusing to remove Setup-owned files first.');
  if not FileExists(CmdExe) then
    RaiseException('Trusted Windows cmd.exe is unavailable; refusing HMS uninstall.');

  OldPath := GetEnv('PATH');
  ChildPath := ExpandConstant('{app}\support\git\cmd;{app}\support\codex;') + OldPath;
  if not SetProcessEnvironmentVariable('PATH', ChildPath) then
    RaiseException('Unable to prepare the process-local HMS support PATH for uninstall.');

  try
    Params := '/d /q /v:off /s /c ""' + Launcher + '" uninstall"';
    Started := Exec(CmdExe, Params, RepoRoot, SW_HIDE, ewWaitUntilTerminated, ResultCode);
  finally
    SetProcessEnvironmentVariable('PATH', OldPath);
  end;

  if not Started then
    RaiseException('Authenticated HMS lifecycle uninstall could not be started; Setup-owned files were not removed.');
  if ResultCode <> 0 then
    RaiseException('Authenticated HMS lifecycle uninstall failed with exit code ' + IntToStr(ResultCode) + '.');
end;

procedure RemoveSetupOwnedSupportTools();
var
  SupportRoot: String;
  GitRoot: String;
  CodexRoot: String;
begin
  SupportRoot := ExpandConstant('{app}\support');
  GitRoot := AddBackslash(SupportRoot) + 'git';
  CodexRoot := AddBackslash(SupportRoot) + 'codex';

  if not DirExists(SupportRoot) then
    RaiseException('Setup-owned support root is missing; refusing ambiguous uninstall cleanup.');
  if IsReparsePoint(SupportRoot) then
    RaiseException('Setup-owned support root is a reparse point; refusing cleanup.');

  RemoveVerifiedSupportDirectory(GitRoot, 'mingit');
  RemoveVerifiedSupportDirectory(CodexRoot, 'codex');

  if not RemoveDir(SupportRoot) then
    RaiseException('Setup-owned support root contains unexpected residual entries; refusing broader deletion: ' + SupportRoot);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RunHmsLifecycleUninstall();
    RemoveSetupOwnedSupportTools();
  end;
end;
