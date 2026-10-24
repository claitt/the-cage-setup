; Inno Setup script for The Cage Setup.
; Build with build-installer.ps1, or run ISCC.exe on this file after
; build-winui.ps1 (the payload is read from dist\TheCageSetup\).

#define AppName "The Cage Setup"
#define DisplayName "The Cage"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
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
UninstallDisplayName={#DisplayName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} setup
; Upgrades: same AppId, same default folder, previous choices kept.
UsePreviousAppDir=yes
UsePreviousTasks=yes
UsePreviousGroup=yes
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Older versions used the product name for the shortcut files. Remove
; them so an in-place upgrade leaves one entry, named "The Cage".
Type: files; Name: "{autodesktop}\The Cage Setup.lnk"
Type: files; Name: "{group}\The Cage Setup.lnk"

[Files]
Source: "..\dist\TheCageSetup\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#DisplayName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#DisplayName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(DisplayName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
