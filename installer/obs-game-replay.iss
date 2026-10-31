#ifndef AppVersion
  #error AppVersion must be supplied by build-installer.ps1
#endif
#ifndef PayloadDir
  #error PayloadDir must be supplied by build-installer.ps1
#endif

[Setup]
AppId={{A8DA1B8E-15F0-460D-A8EF-59B198B94FEC}
AppName=OBS Game Replay Automation
AppVersion={#AppVersion}
AppPublisher=Church54711
AppPublisherURL=https://github.com/Church54711/obs-game-replay-automation
AppSupportURL=https://github.com/Church54711/obs-game-replay-automation/issues
AppUpdatesURL=https://github.com/Church54711/obs-game-replay-automation/releases
DefaultDirName={autopf}\OBS Game Replay Automation
DefaultGroupName=OBS Game Replay Automation
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableWelcomePage=no
LicenseFile={#PayloadDir}\LICENSE
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=no
RestartApplications=no
SetupMutex=OBSGameReplayAutomationSetup
UninstallDisplayName=OBS Game Replay Automation
OutputDir={#InstallerOutputDir}
OutputBaseFilename=obs-game-replay-automation-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
#ifdef EnableSigning
SignTool=ReplaySign
SignedUninstaller=yes
SignToolRunMinimized=yes
#endif

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}\payload"; Flags: ignoreversion
Source: "setup-bridge.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: updatechecks; Description: "Enable daily update notifications"; Flags: unchecked

[Icons]
Name: "{group}\Check for Updates"; Filename: "{code:ScriptsFolder}\Update OBS Game Replay Automation.cmd"
Name: "{group}\Setup instructions"; Filename: "{app}\payload\README.md"
Name: "{group}\Uninstall OBS Game Replay Automation"; Filename: "{uninstallexe}"

[UninstallDelete]
Type: files; Name: "{app}\deployment-state.json"
Type: files; Name: "{app}\deployment-state.pending.json"

[Code]
var
  ObsPage, ReplayPage: TInputDirWizardPage;
  FinalPage: TOutputMsgWizardPage;
  DeploymentFailure: String;

function CleanFolder(Value: String): String;
begin
  Result := RemoveBackslashUnlessRoot(Trim(Value));
end;

function ScriptsFolder(Param: String): String;
var
  Root, Previous: String;
begin
  Root := CleanFolder(ObsPage.Values[0]);
  Previous := ExpandConstant('{param:SCRIPTSDIR|}') ;
  if Previous = '' then begin
    if CompareText(Root, GetPreviousData('ObsRoot', '')) = 0 then
      Previous := GetPreviousData('ScriptsDir', '');
  end;
  if Previous <> '' then Result := CleanFolder(Previous)
  else if FileExists(Root + '\data\obs-plugins\frontend-tools\scripts\game-replay-auto.lua') then
    Result := Root + '\data\obs-plugins\frontend-tools\scripts'
  else Result := Root + '\data\scripts\obs-game-replay-automation';
end;

function DetectObs: String;
var
  Candidate: String;
begin
  Result := GetPreviousData('ObsRoot', '');
  if Result <> '' then exit;
  if RegQueryStringValue(HKLM64, 'SOFTWARE\OBS Studio', '', Candidate) then
    if FileExists(AddBackslash(Candidate) + 'bin\64bit\obs64.exe') then Result := Candidate;
  if Result = '' then Result := ExpandConstant('{autopf}\obs-studio');
end;

procedure InitializeWizard;
begin
  ObsPage := CreateInputDirPage(wpLicense, 'OBS Studio location',
    'Select the OBS installation and your OBS configuration folder.',
    'Close OBS before continuing. Existing scripts and settings are preserved during an upgrade.', False, '');
  ObsPage.Add('OBS installation folder:');
  ObsPage.Add('OBS configuration folder:');
  ObsPage.Values[0] := ExpandConstant('{param:OBSROOT|}') ;
  if ObsPage.Values[0] = '' then ObsPage.Values[0] := DetectObs;
  ObsPage.Values[1] := ExpandConstant('{param:OBSCONFIGROOT|}') ;
  if ObsPage.Values[1] = '' then
    ObsPage.Values[1] := GetPreviousData('ObsConfigRoot', ExpandConstant('{userappdata}\obs-studio'));
  ReplayPage := CreateInputDirPage(ObsPage.ID, 'Replay clips',
    'Where should new replay clips be saved?',
    'Setup checks that the folder is writable. Existing installations keep their current configuration.', False, '');
  ReplayPage.Add('Replay folder:');
  ReplayPage.Values[0] := ExpandConstant('{param:REPLAYROOT|}') ;
  if ReplayPage.Values[0] = '' then ReplayPage.Values[0] := GetEnv('USERPROFILE') + '\Videos\OBS Replays';
  FinalPage := CreateOutputMsgPage(wpInfoAfter, 'Enable the script in OBS',
    'One OBS step is needed for a first installation.', '');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = ReplayPage.ID) and FileExists(ScriptsFolder('') + '\game-replay-auto-config.txt')) or
    ((PageID = FinalPage.ID) and (DeploymentFailure <> ''));
end;

function ValidFolder(Value: String): Boolean;
begin
  Result := (Length(Value) > 2) and (Pos('"', Value) = 0) and
    (Pos(#13, Value) = 0) and (Pos(#10, Value) = 0) and
    (((Copy(Value, 2, 2) = ':\')) or (Copy(Value, 1, 2) = '\\'));
end;

function WriteRequest: String;
var
  Body, Checks: String;
begin
  Checks := '0';
  if WizardIsTaskSelected('updatechecks') then Checks := '1';
  Result := ExpandConstant('{tmp}\replay-setup-request.txt');
  Body := 'ObsRoot=' + CleanFolder(ObsPage.Values[0]) + #13#10 +
    'ObsConfigRoot=' + CleanFolder(ObsPage.Values[1]) + #13#10 +
    'ScriptsDir=' + ScriptsFolder('') + #13#10 +
    'ReplayRoot=' + CleanFolder(ReplayPage.Values[0]) + #13#10 +
    'EnableUpdateChecks=' + Checks + #13#10;
  if not SaveStringToFile(Result, UTF8Encode(Body), False) then RaiseException('Cannot write setup request.');
end;

function RunBridge(Bridge, Action, Request: String): String;
var
  Params, ResultFile: String;
  ExitCode: Integer;
  Contents: AnsiString;
begin
  ResultFile := ExpandConstant('{tmp}\replay-setup-result.txt');
  DeleteFile(ResultFile);
  Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Bridge +
    '" -Action ' + Action + ' -AppDir "' + ExpandConstant('{app}') +
    '" -ResultFile "' + ResultFile + '"';
  if Request <> '' then Params := Params + ' -RequestFile "' + Request + '"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    Result := 'Windows PowerShell could not be started.'
  else if ExitCode <> 0 then begin
    if LoadStringFromFile(ResultFile, Contents) then Result := UTF8Decode(Contents)
    else Result := 'Installation helper failed. Exit code: ' + IntToStr(ExitCode);
  end else Result := '';
  Log(Action + ': ' + Result);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if not IsAdminInstallMode and
    ((Pos(Lowercase(AddBackslash(ExpandConstant('{commonpf64}'))), Lowercase(AddBackslash(ScriptsFolder('')))) = 1) or
     (Pos(Lowercase(AddBackslash(ExpandConstant('{commonpf32}'))), Lowercase(AddBackslash(ScriptsFolder('')))) = 1)) then begin
    Result := 'A per-user setup cannot manage Program Files. Run Setup without /CURRENTUSER, or choose writable portable OBS folders.';
    exit;
  end;
  if not ValidFolder(ObsPage.Values[0]) or not ValidFolder(ObsPage.Values[1]) or
    not ValidFolder(ScriptsFolder('')) or not ValidFolder(ReplayPage.Values[0]) then begin
    Result := 'Choose absolute folder paths, such as C:\Program Files\obs-studio.';
    exit;
  end;
  ExtractTemporaryFile('setup-bridge.ps1');
  Result := RunBridge(ExpandConstant('{tmp}\setup-bridge.ps1'), 'Check', WriteRequest);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Failure: String;
begin
  if CurStep = ssPostInstall then begin
    Failure := RunBridge(ExpandConstant('{app}\setup-bridge.ps1'), 'Install', WriteRequest);
    if Failure <> '' then begin
      { Inno catches ssPostInstall exceptions and can still return zero. Keep
        failure explicitly for the exit status and the final wizard page. }
      DeploymentFailure := Failure;
      RaiseException(Failure);
    end;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if DeploymentFailure <> '' then Result := 1 else Result := 0;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and (DeploymentFailure <> '') then begin
    WizardForm.FinishedHeadingLabel.Caption := 'Setup did not complete';
    WizardForm.FinishedLabel.Caption := DeploymentFailure + #13#10#13#10 +
      'Correct the problem and run Setup again. You can remove the setup files through Windows Installed Apps.';
  end;
  if CurPageID = FinalPage.ID then FinalPage.MsgLabel.Caption :=
    'In OBS, open Tools > Scripts, click +, and select:' + #13#10#13#10 +
    ScriptsFolder('') + '\game-replay-auto.lua' + #13#10#13#10 +
    'If this script is already listed, no additional copy is needed.' + #13#10#13#10 +
    'Create Game Capture and Application Audio Capture sources as described in the Start Menu setup instructions. ' +
    'Your clips, configuration, and recovery backups are retained if you uninstall.';
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'ObsRoot', CleanFolder(ObsPage.Values[0]));
  SetPreviousData(PreviousDataKey, 'ScriptsDir', ScriptsFolder(''));
  SetPreviousData(PreviousDataKey, 'ObsConfigRoot', CleanFolder(ObsPage.Values[1]));
end;

function InitializeUninstall: Boolean;
var
  Failure: String;
begin
  Failure := RunBridge(ExpandConstant('{app}\setup-bridge.ps1'), 'CheckUninstall', '');
  Result := Failure = '';
  if not Result then SuppressibleMsgBox(Failure, mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Failure: String;
begin
  { This runs AFTER confirmation and BEFORE Inno removes anything. Raising an
    exception here aborts uninstall and leaves the uninstaller usable. }
  if CurUninstallStep = usUninstall then begin
    Failure := RunBridge(ExpandConstant('{app}\setup-bridge.ps1'), 'Uninstall', '');
    if Failure <> '' then RaiseException(Failure);
  end;
end;
