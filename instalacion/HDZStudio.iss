; ============================================================
;  HDZStudio.iss  —  (OPCIONAL) Instalador .exe con Inno Setup
; ============================================================
;  Esto NO hace falta para repartir el programa: con el ZIP +
;  "Instalar HDZ Studio.cmd" ya es suficiente. Esto es la opción
;  "profesional": genera un Setup.exe con desinstalador.
;
;  CÓMO USARLO (lo hace el desarrollador, una vez):
;   1. Instala Inno Setup:  https://jrsoftware.org/isdl.php
;   2. Abre este archivo con Inno Setup y pulsa "Compile".
;   3. Te genera  Salida\HDZ Studio Setup.exe  para repartir.
;
;  El Setup copia el programa, y al terminar ejecuta el mismo
;  Instalar-HDZStudio.ps1 (descarga herramientas a bin\, asegura
;  PowerShell 7 y crea los accesos directos). Reutiliza esa lógica.
; ============================================================

#define AppName "HDZ Studio"
#define AppVer  "1.24"
#ifndef StageRoot
  #error "Usa Preparar-Release.ps1 y compila con /DStageRoot=ruta_del_paquete_verificado"
#endif

[Setup]
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher=HDZ Studio
DefaultDirName={localappdata}\Programs\HDZ Studio
UsePreviousAppDir=no
DefaultGroupName=HDZ Studio
DisableProgramGroupPage=yes
OutputDir=Salida
OutputBaseFilename=HDZStudio-Setup-{#AppVer}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; La aplicación pertenece al usuario. Los prerrequisitos que lo necesiten
; solicitan UAC por separado, sin elevar todo el instalador.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
SetupIconFile=..\HDZ.ico

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "contextmenu"; Description: "Añadir capturas al menú contextual de Windows (puede pedir permisos de administrador)"; Flags: unchecked

[Files]
; La carpeta de entrada la genera una lista positiva, nunca el workspace completo.
Source: "{#StageRoot}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[UninstallRun]
; Al desinstalar: quita accesos directos y lanzador (deja PowerShell 7 y los ajustes intactos).
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\instalacion\Desinstalar-HDZStudio.ps1"""; \
  Flags: runhidden; RunOnceId: "DesinstalarHDZ"

[Code]
function InitializeSetup(): Boolean;
var Locator, Wmi, Processes: Variant;
begin
  Result := False;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Wmi := Locator.ConnectServer('', 'root\CIMV2');
    Processes := Wmi.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name=''pwsh.exe'' AND (CommandLine LIKE ''%HDZ-GUI.ps1%'' OR CommandLine LIKE ''%HDZnew.ps1%'')');
    if Processes.Count > 0 then begin
      MsgBox('Cierra HDZ Studio antes de instalar. Si hay un montaje, espera a que termine.', mbError, MB_OK);
      Exit;
    end;
  except
    { Si WMI no permite leer los procesos, no arriesgar una actualización parcial. }
    MsgBox('No se puede comprobar si HDZ Studio está abierto. Reinicia Windows e inténtalo de nuevo.', mbError, MB_OK);
    Exit;
  end;
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var ExitCode: Integer; Params: String;
begin
  if CurStep = ssPostInstall then begin
    Params := ExpandConstant('-NoProfile -ExecutionPolicy Bypass -File "{app}\instalacion\Instalar-HDZStudio.ps1"');
    if not WizardIsTaskSelected('contextmenu') then Params := Params + ' -SkipContextMenu';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params,
      '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
      RaiseException('No se completó la configuración. Consulta el registro detallado en %TEMP%\HDZ-Studio-setup.log.');
  end;
end;
