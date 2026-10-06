[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
UninstallDisplayIcon={app}\{{EXECUTABLE_NAME}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}

[Code]
const
  TaskCleanupScript =
    'param([string]$Executable)'#13#10 +
    '$ErrorActionPreference = ''Stop'''#13#10 +
    'Import-Module (Join-Path ([Environment]::SystemDirectory) ''WindowsPowerShell\v1.0\Modules\ScheduledTasks\ScheduledTasks.psd1'') -Force'#13#10 +
    '$task = Get-ScheduledTask -TaskPath ''\'' -TaskName ''FlClash-Meow'' -ErrorAction SilentlyContinue'#13#10 +
    'if ($null -eq $task) { exit 0 }'#13#10 +
    '$actions = @($task.Actions)'#13#10 +
    'if ($actions.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals($actions[0].Execute, $Executable) -or -not [String]::IsNullOrEmpty($actions[0].Arguments)) { exit 0 }'#13#10 +
    'Unregister-ScheduledTask -TaskPath ''\'' -TaskName ''FlClash-Meow'' -Confirm:$false';

procedure KillProcesses;
var
  Processes: TArrayOfString;
  i: Integer;
  ResultCode: Integer;
begin
  Processes := ['FlClashMeow.exe', 'FlClashMeowCore.exe', 'FlClashMeowHelperService.exe'];

  for i := 0 to GetArrayLength(Processes)-1 do
  begin
    Exec('taskkill', '/f /im ' + Processes[i], '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

procedure UnregisterHelperService;
var
  HelperPath: String;
  ResultCode: Integer;
begin
  HelperPath := ExpandConstant('{app}\\FlClashMeowHelperService.exe');
  if FileExists(HelperPath) then
  begin
    Exec(HelperPath, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

procedure UnregisterProduct;
var
  Executable, Command, TaskScript: String;
  ProtocolKey, RunKey: String;
  ResultCode: Integer;
begin
  Executable := ExpandConstant('{app}\FlClashMeow.exe');
  ProtocolKey := 'Software\Classes\flclash-meow';
  RunKey := 'Software\Microsoft\Windows\CurrentVersion\Run';
  if RegQueryStringValue(HKCU, ProtocolKey + '\shell\open\command', '', Command) and
     (CompareText(Command, '"' + Executable + '" "%1"') = 0) then
    RegDeleteKeyIncludingSubkeys(HKCU, ProtocolKey);
  if RegQueryStringValue(HKCU, RunKey, 'FlClash-Meow', Command) and
     (CompareText(Command, Executable) = 0) then
  begin
    RegDeleteValue(HKCU, RunKey, 'FlClash-Meow');
    RegDeleteValue(HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
      'FlClash-Meow');
  end;
  TaskScript := ExpandConstant('{tmp}\flclash-meow-unregister-task.ps1');
  if SaveStringToFile(TaskScript, TaskCleanupScript, False) then
  begin
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + TaskScript +
      '" -Executable "' + Executable + '"', '', SW_HIDE, ewWaitUntilTerminated,
      ResultCode) or (ResultCode <> 0) then
      Log('FlClash-Meow scheduled-task cleanup could not be confirmed');
    DeleteFile(TaskScript);
  end
  else
    Log('FlClash-Meow scheduled-task cleanup script could not be written');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  UnregisterHelperService;
  KillProcesses;
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  UnregisterHelperService;
  KillProcesses;
  UnregisterProduct;
  Result := True;
end;

[Languages]
{% for locale in LOCALES %}
{% if locale.lang == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale.lang == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale.lang == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale.lang == 'zh' %}Name: "chineseSimplified"; MessagesFile: "{{ locale.file }}"{% endif %}
{% if locale.lang == 'zh_TW' %}Name: "chineseTraditional"; MessagesFile: "{{ locale.file }}"{% endif %}
{% endfor %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: {% if PRIVILEGES_REQUIRED == 'admin' %}runascurrentuser{% endif %} nowait postinstall skipifsilent
