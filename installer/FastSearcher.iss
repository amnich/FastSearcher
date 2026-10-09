#ifndef AppVersion
  #define AppVersion "1.4.0.0"
#endif
#ifndef AppExePath
  #if GetEnv("FASTSEARCHER_EXE_PATH") != ""
    #define AppExePath GetEnv("FASTSEARCHER_EXE_PATH")
  #else
    #define AppExePath "..\FastSearcher.exe"
  #endif
#endif
#ifndef AppIcon
  #if GetEnv("FASTSEARCHER_ICON_PATH") != ""
    #define AppIcon GetEnv("FASTSEARCHER_ICON_PATH")
  #else
    #define AppIcon "..\..\Mnich_Adam_Skrypty\!Helper\Logo_AM6.ico"
  #endif
#endif

#define AppName "FastSearcher"
#define AppPublisher "Adam Mnich"
#define AppExeName "FastSearcher.exe"

[Setup]
AppId={{DA492D21-083D-4AB7-A573-0619BF84B5C1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppComments=Multi-threaded file content search utility
DefaultDirName={localappdata}\Programs\FastSearcher
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
SetupIconFile="{#AppIcon}"
OutputDir=..\dist\installer
OutputBaseFilename=FastSearcher-Setup-{#AppVersion}
ArchitecturesAllowed=x86compatible
PrivilegesRequired=lowest
CloseApplications=yes
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#AppExePath}"; DestDir: "{app}"; DestName: "{#AppExeName}"; Flags: ignoreversion
Source: "..\language.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent