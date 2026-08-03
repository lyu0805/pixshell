;; PixShell Windows installer (Inno Setup 6)
; Build after self-contained publish:
;   iscc /DMyAppVersion=0.1.7 /DPublishDir=..\publish\win-x64 win\installer\PixShell.iss
;
; Defines (overridable via /D from CI env VERSION):
;   MyAppVersion  - product version without leading v (default 0.1.7)
;   PublishDir    - published win-x64 folder (default ..\publish\win-x64)
;   OutputDir     - installer output directory (default ..\dist\artifacts)
;   ArchLabel     - architecture label in filename (default x64)

#ifndef MyAppName
  #define MyAppName "PixShell"
#endif

#ifndef MyAppVersion
  #define MyAppVersion "0.1.7"
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
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
; Inno appends .exe → PixShell-0.1.7-win-x64-setup.exe
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
Name: "chinesesimplified"; MessagesFile: "languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Self-contained publish tree. Default Source is relative to this .iss:
;   win/installer/../publish/win-x64  →  win/publish/win-x64
; CI may pass absolute /DPublishDir=...
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; WebView2 Evergreen bootstrapper — installed silently on first install if runtime missing.
;   Download source: https://go.microsoft.com/fwlink/p/?LinkId=2124703 (x64)
Source: "..\Resources\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; 静默安装 WebView2 Runtime（仅当缺失时；/silent /install 由 bootstrapper 自动请求提权）
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "正在安装 WebView2 Runtime（首次安装需要联网下载）…"; Flags: waituntilterminated skipifdoesntexist; Check: NeedsWebView2
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
// WebView2 Evergreen Runtime 检测：per-machine 与 per-user 注册表均查。
// 官方安装检测键：HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}
// （该键存在于 WebView2 Runtime 安装时；Edge 自带不保证提供 WebView2，故只查 WebView2 专用键）
const
  WebView2ClientsKey = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function NeedsWebView2: Boolean;
begin
  Result := True;
  // 64 位系统 per-machine（Inno 的 HKLM32 在 x64compatible 安装模式下映射 WOW6432Node）
  if RegKeyExists(HKLM32, WebView2ClientsKey) then
    Result := False
  else if RegKeyExists(HKCU, WebView2ClientsKey) then
    Result := False;
end;
