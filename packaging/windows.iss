#ifndef AppVersion
#define AppVersion "1.0.0"
#endif
[Setup]
AppId={{91D15019-34CA-4D43-9365-401511324E4A}
AppName=D110 Studio
AppVersion={#AppVersion}
AppPublisher=lalalala
AppPublisherURL=https://github.com/l4l4l4l4/d110-studio
DefaultDirName={localappdata}\Programs\D110 Studio
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=D110-Studio-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\d110_studio.exe
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{autoprograms}\D110 Studio"; Filename: "{app}\d110_studio.exe"
[Run]
Filename: "{app}\d110_studio.exe"; Description: "Launch D110 Studio"; Flags: nowait postinstall skipifsilent
