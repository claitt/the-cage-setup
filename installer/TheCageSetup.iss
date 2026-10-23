; Inno Setup script for The Cage Setup.
; Build with build-installer.ps1, or run ISCC.exe on this file after
; build-winui.ps1 (the payload is read from dist\TheCageSetup\).

#define AppName "The Cage Setup"
#define AppVersion "2.0.0"
#define AppExe "TheCageSetup.exe"

[Setup]
AppId={{8E4F1C62-3B7A-4D2E-9C51-6A0D5B8E7F14}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=claitt
AppPublisherURL=https://github.com/claitt/the-cage-setup
AppSupportURL=https://github.com/claitt/the-cage-setup/issues
AppUpdatesURL=https://github.com/claitt/the-cage-setup/releases
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist\installer
OutputBaseFilename=TheCageSetup-{#AppVersion}-setup
SetupIconFile=..\CageSetup.WinUI\Assets\Lunar_Tear.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
VersionInfoVersion=2.0.0.0
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\dist\TheCageSetup\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
