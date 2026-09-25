; Inno Setup script for Strakalari GUI Installer
; Generates a lightweight, single-click installer with no admin privileges required.

#define MyAppName "Strakalari"
; CI stamps the release version: ISCC /DMyAppVersion=1.2.3 (or 1.2.3-beta.1).
; Local builds fall back to the hardcoded version below.
#ifndef MyAppVersion
#define MyAppVersion "0.1.0-beta.3"
#endif
#define MyAppPublisher "Strakalari"
#define MyAppExeName "Strakalari.exe"

[Setup]
AppId={{D94B0B7F-65C1-4D52-9A47-E30D6E26F22B}
AppName={#MyAppName}
AppVerName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
LicenseFile=LICENSE
; Install to Local AppData so no Administrator elevation (UAC prompt) is required
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=Strakalari-Setup-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ShowLanguageDialog=yes
CloseApplications=yes
RestartApplications=no
SetupIconFile=assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "czech"; MessagesFile: "compiler:Languages\Czech.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
; Shown on fresh installs only: on updates the existing HKCU Run value is
; left untouched instead of asking again.
Name: "autostart"; Description: "{cm:AutostartDesc}"; GroupDescription: "{cm:AutomationGroup}"; Check: IsFreshInstall

[CustomMessages]
english.AutostartDesc=Start Strakaláři automatically on Windows startup
english.AutomationGroup=Automation:
english.RemoveDataMsg=Do you also want to remove all user data (settings, credentials, cache and the downloaded browser)?%n%nChoose Yes for a complete removal, or No to keep your data for a later reinstall (the install folder with your data will remain in place).
czech.AutostartDesc=Spustit Strakaláře automaticky při startu Windows
czech.AutomationGroup=Automatizace:
czech.RemoveDataMsg=Chcete také odstranit všechna uživatelská data (nastavení, přihlašovací údaje, mezipaměť a stažený prohlížeč)?%n%nZvolte Ano pro úplné odebrání, nebo Ne pro zachování dat pro případnou přeinstalaci (složka s daty zůstane na místě).

[Files]
Source: "dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "config.example.json"; DestDir: "{app}"; Flags: ignoreversion
; NOTE: strava_blacklist.example.json is NOT seeded as a live file: the
; default blacklist is empty (the template is just "[]") and a missing
; blacklist already means "no bans". Old templates held a
; YOUR_BLACKLIST_EXAMPLE placeholder, which is still ignored if found.
Source: "strava_blacklist.example.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "already_excused_lessons.example.json"; DestDir: "{app}"; DestName: "already_excused_lessons.json"; Flags: onlyifdoesntexist

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "{#MyAppName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"; AppUserModelID: "{#MyAppName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; AppUserModelID: "{#MyAppName}"

[Registry]
; Same mechanism the app itself reads/writes (HKCU Run value), so the
; in-app autostart toggle always reflects the installer task state.
; The task above is hidden on updates (Check: IsFreshInstall), so this
; entry only runs on fresh installs and never resets a changed setting.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExeName}"" --minimized"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
; NOTE: Chromium (~320 MB) is NOT bundled. The app window opens first and
; Chromium downloads in the background on first refresh/automation
; (internet required) via ensure_browser() into a persistent per-user
; location (exe-adjacent browsers/ when writable, else the platform
; ms-playwright cache) — never the Temp _MEIPASS extraction dir, which
; is wiped on exit and caused "Executable doesn't exist" launch failures.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  RemoveUserData: Boolean;

function IsFreshInstall(): Boolean;
begin
  { Update = exe already present in the target dir (which defaults to the
    previous install dir). False hides the autostart task, so the [Registry]
    entry is skipped and the current HKCU Run value survives the update —
    including a value the user later toggled in Settings. }
  Result := not FileExists(ExpandConstant('{app}\{#MyAppExeName}'));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  NeedsRestart := False;
  Result := '';
  { The app runs as same-named processes (tray + UI child) with no
    Restart-Manager-aware windows, so CloseApplications alone cannot stop
    them and the install would fail with "unable to close applications".
    Ask politely first (WM_CLOSE lets the app flush caches), then force
    any stragglers — mirroring the uninstall step below. Result codes are
    intentionally ignored: no running instance is the common case. }
  Exec('taskkill.exe', '/T /IM Strakalari.exe', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  Sleep(2000);
  Exec('taskkill.exe', '/F /T /IM Strakalari.exe', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
  { NOTE: no flet.exe sweep here on purpose. Killing by the generic
    flet.exe image name would also kill other vendors' Flet apps running
    on this machine. Only our own Strakalari.exe tree (above) is stopped;
    detached helpers of a previous install hold no install locks. }
end;

function IsUninstallSilent(): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if (CompareText(ParamStr(I), '/SILENT') = 0) or
       (CompareText(ParamStr(I), '/VERYSILENT') = 0) then
    begin
      Result := True;
      Break;
    end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDir, FallbackDataDir: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    { A running app or tray locks the exe and its data files, which ends the
      uninstall with "Some elements could not be removed". Stop it first
      (window and --minimized tray share the exe name). This step runs only
      after the uninstall was confirmed, so cancelling never kills the app. }
    Exec('taskkill.exe', '/F /T /IM Strakalari.exe', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    { NOTE: no flet.exe sweep here on purpose — same reason as in
      PrepareToInstall above: the generic image name would also match
      other vendors' Flet apps. Only our own Strakalari.exe is stopped. }
    { Silent uninstalls never prompt: keep user data (non-destructive default). }
    if IsUninstallSilent() then
      RemoveUserData := False
    else
      { Default button is No so a click-through never wipes credentials. }
      RemoveUserData :=
        MsgBox(CustomMessage('RemoveDataMsg'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
    { The password key lives in Windows Credential Manager, which only the
      app itself can address: ask it to forget the key while its exe still
      exists (files are removed after this step). }
    if RemoveUserData and FileExists(ExpandConstant('{app}\{#MyAppExeName}')) then
      Exec(ExpandConstant('{app}\{#MyAppExeName}'), '--forget-secrets', '', SW_HIDE,
        ewWaitUntilTerminated, ResultCode);
  end
  else if CurUninstallStep = usPostUninstall then
  begin
    { The autostart entry points at the exe being removed; it would dangle
      after any uninstall, so it is always cleaned up (not user data). }
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Strakalari');
    { Legacy Startup-folder shortcut from older installers dangles too. }
    DeleteFile(ExpandConstant('{userstartup}\Strakalari.lnk'));

    if RemoveUserData then
    begin
      { Standard per-user installs keep data inside the install dir itself
        (it is writable, so get_user_data_dir() returns it). Only known
        app files are deleted — never a wholesale DelTree of the install
        dir, since the user may have picked a non-empty folder. Inno removes
        the files it installed (exe, example JSONs) on its own. }
      AppDir := ExpandConstant('{app}');
      DeleteFile(AppDir + '\config.json');
      DeleteFile(AppDir + '\secret.key');
      DeleteFile(AppDir + '\data_cache.json');
      DeleteFile(AppDir + '\log.txt');
      DeleteFile(AppDir + '\log.txt.lock');
      DeleteFile(AppDir + '\update_cache.json');
      DeleteFile(AppDir + '\*.log');
      DeleteFile(AppDir + '\strava_blacklist.json');
      DeleteFile(AppDir + '\already_excused_lessons.json');
      DeleteFile(AppDir + '\automation_history.jsonl');
      DeleteFile(AppDir + '\automation_history.jsonl.old');
      DeleteFile(AppDir + '\log.txt.old');
      DeleteFile(AppDir + '\console.log.old');
      { Quarantined corrupt files, config backups, atomic-write and lock leftovers. }
      DeleteFile(AppDir + '\*.corrupt-*');
      DeleteFile(AppDir + '\*.bak');
      DeleteFile(AppDir + '\*.tmp');
      DeleteFile(AppDir + '\*.lock');
      { Downloaded Chromium (~320 MB) lives next to the exe when writable. }
      DelTree(AppDir + '\browsers', True, True, True);
      { Fallback data dir used when the install dir is read-only.
        Fully owned by the app, so the whole tree can go. The shared
        ms-playwright cache is intentionally left alone (other apps). }
      FallbackDataDir := ExpandConstant('{localappdata}\Strakalari');
      if CompareText(FallbackDataDir, AppDir) <> 0 then
        DelTree(FallbackDataDir, True, True, True);
      { Removes the install dir itself once the above emptied it.
        The running uninstaller files are deleted by Inno afterwards. }
      RemoveDir(AppDir);
    end;
  end;
end;
