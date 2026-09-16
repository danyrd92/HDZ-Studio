# =========================================================================
# Desinstalar-Completo.ps1  —  Desinstalador para "Agregar o quitar programas"
# =========================================================================
# Lo registra el instalador WPF (Instalar-GUI.ps1) como UninstallString.
# Quita accesos directos, la entrada de "Agregar o quitar programas" y la
# carpeta del programa. NO borra los ajustes/credenciales del usuario (viven
# en %APPDATA%), para no perder la configuracion si se reinstala.
# Compatible con Windows PowerShell 5.1 (guardado con BOM). Se auto-eleva.
# =========================================================================

$ErrorActionPreference = "SilentlyContinue"

# --- Auto-elevacion (escribir en Archivos de programa y HKLM requiere admin) ---
$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object System.Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process "powershell.exe" -Verb RunAs -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
    return
}

# Carpeta del programa = un nivel por encima de \instalacion
$instalDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $instalDir
if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'HDZ-GUI.ps1')) -or -not (Test-Path -LiteralPath (Join-Path $appRoot 'VERSION.txt'))) { throw 'No se reconoce la carpeta instalada.' }
$registered = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HDZ Studio' -ErrorAction Stop
if ([IO.Path]::GetFullPath("$($registered.InstallLocation)").TrimEnd('\') -ne [IO.Path]::GetFullPath($appRoot).TrimEnd('\')) { throw 'Esta carpeta no es la instalación registrada. No se cambia nada.' }

# Quitar antes de borrar la carpeta del programa para no dejar verbos de
# Explorer apuntando a un fichero que ya no existe.
$instMenuCapturas = Join-Path $instalDir "Instalar-menu-capturas.ps1"
if (Test-Path -LiteralPath $instMenuCapturas) {
    try { & $instMenuCapturas -Desinstalar } catch {}
}

# 1) Accesos directos (Escritorio + Menu Inicio) y lanzador
foreach ($lnk in @(
    (Join-Path ([Environment]::GetFolderPath('Desktop'))  'HDZ Studio.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'HDZ Studio.lnk')
)) { if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force } }

# 2) Confirmacion silenciosa: dejamos PowerShell 7 y los ajustes del usuario intactos.

# 3) El ayudante vuelve a validar la ruta registrada y solo utiliza PowerShell.
$registered = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HDZ Studio' -ErrorAction Stop
if ([IO.Path]::GetFullPath("$($registered.InstallLocation)").TrimEnd('\') -ne [IO.Path]::GetFullPath($appRoot).TrimEnd('\')) { throw 'Esta carpeta no es la instalación registrada. No se borra.' }
$helper = Join-Path $PSScriptRoot 'Limpiar-Instalacion.ps1'
Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $helper + '"'),'-InstallPath',('"' + $appRoot + '"'),'-ParentId',"$PID") -WindowStyle Hidden
