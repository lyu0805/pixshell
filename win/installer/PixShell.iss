;; PixShell Windows installer (Inno Setup 6)
; Build after self-contained publish:
;   iscc /DMyAppVersion=0.1.1 /DPublishDir=..\publish\win-x64 win\installer\PixShell.iss
;
; Defines (overridable via /D from CI env VERSION):
;   MyAppVersion  - product version without leading v (default 0.1.1)
;   PublishDir    - published win-x64 folder (default ..\publish\win-x64)
;   OutputDir     - installer output directory (default ..\dist\artifacts)
;   ArchLabel     - architecture label in filename (default x64)

#ifndef MyAppName
  #define MyAppName "PixShell"
#endif

#ifndef MyAppVersion
  #define MyAppVersion "0.1.1"
#endif

#ifndef MyAppPublisher
  #define MyAppPublisher "PixShell"
#endif

#ifndef MyAppURL
  #define MyAppURL "https://github.com/lyu0805/pixshell"
#endif

#ifndef MyAppExeName
  #define MyAppExeName "PixShell.exe"
#endif

#ifndef MyAppId
  #define MyAppId "{{A7C3E9F1-2B4D-4F68-9C1A-8E0D5B6A4C21}"
#endif

#ifndef PublishDir
  #define PublishDir "..\publish\win-x64"
#endif

#ifndef OutputDir
  #define OutputDir "..\dist\artifacts"
#endif

#ifndef ArchLabel
  #define ArchLabel "x64"
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
; Inno appends .exe → PixShell-0.1.1-win-x64-setup.exe
OutputBaseFilename=PixShell-{#MyAppVersion}-win-{#ArchLabel}-setup
SetupIconFile=..\Resources\AppIcon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
MinVersion=10.0
CloseApplications=yes
RestartApplications=no
AllowNoIcons=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Self-contained publish tree. Default Source is relative to this .iss:
;   win/installer/../publish/win-x64  →  win/publish/win-x64
; CI may pass absolute /DPublishDir=...
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
