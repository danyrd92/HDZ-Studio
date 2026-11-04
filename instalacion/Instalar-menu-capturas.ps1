<#
  Instala o quita «Hacer capturas de pantalla» en el menú contextual de vídeos.

  Se registra en HKLM porque en esta instalación de Windows 11 los verbos de
  HKCU\Software\Classes no aparecen en el menú contextual moderno. Requiere UAC.

      .\instalacion\Instalar-menu-capturas.ps1
      .\instalacion\Instalar-menu-capturas.ps1 -Desinstalar
#>
[CmdletBinding()]
param([switch]$Desinstalar)

$ErrorActionPreference = 'Stop'

$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($id)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $elevated = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $elevated) { $elevated = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Desinstalar) { $args += '-Desinstalar' }
    Start-Process -FilePath $elevated -ArgumentList $args -Verb RunAs -Wait
    return
}

$appRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $appRoot 'Capturas-MenuContextual.ps1'
$launcher = Join-Path $appRoot 'Capturas-MenuContextual.vbs'
$modernRoot = Join-Path $appRoot 'modern-menu'
$modernPackage = Join-Path $modernRoot 'HDZEROStudio.ContextMenu.identity.msix'
$modernCertificate = Join-Path $modernRoot 'HDZEROStudio.ContextMenu.cer'
$modernComHost = Join-Path $modernRoot 'HDZStudioModernMenu.comhost.dll'
$modernManifest = Join-Path $modernRoot 'AppxManifest.xml'
$registrationManifest = Join-Path $appRoot 'AppxManifest.xml'
$contextInstallKey = 'HKLM:\SOFTWARE\HDZEROStudio\ContextMenu'
$contextInstallKeyUser = 'HKCU:\Software\HDZEROStudio\ContextMenu'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
# .iso: disco completo (Blu-ray, UHD o DVD); se capturan las imágenes de su película principal.
# Solo en el menú clásico («Mostrar más opciones»): el paquete moderno de Windows 11 lleva su
# lista de tipos firmada dentro del .msix.
$extensions = @('.mkv', '.mp4', '.avi', '.mov', '.m4v', '.ts', '.m2ts', '.webm', '.wmv', '.flv', '.iso')
$verbName = 'HDZStudioCapturas'
$label = 'Hacer capturas de pantalla'

if ($Desinstalar) {
    $modernPackageState = Get-AppxPackage -Name 'HDZEROStudio.ContextMenu' -ErrorAction SilentlyContinue
    foreach ($pkg in @($modernPackageState)) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
            Write-Host 'Extensión moderna de Windows 11 eliminada.' -ForegroundColor Green
        } catch {
            Write-Warning "No pude quitar la extensión moderna: $($_.Exception.Message)"
        }
    }
    foreach ($ext in $extensions) {
        $key = "HKLM:\SOFTWARE\Classes\SystemFileAssociations\$ext\shell\$verbName"
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    }
    foreach ($key in @($contextInstallKey, $contextInstallKeyUser)) {
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "Opción `"$label`" eliminada del menú contextual." -ForegroundColor Green
    return
}

foreach ($required in @($scriptPath, $launcher, (Join-Path $appRoot 'HDZ-Capturas.ps1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "No encuentro el fichero necesario: $required" }
}

$icon = Join-Path $appRoot 'HDZ.ico'
if (-not (Test-Path -LiteralPath $icon)) { $icon = "$env:WINDIR\System32\imageres.dll,70" }
$command = '"{0}" "{1}" "%1"' -f $wscript, $launcher

foreach ($ext in $extensions) {
    $baseKey = "HKLM:\SOFTWARE\Classes\SystemFileAssociations\$ext\shell\$verbName"
    New-Item -Path "$baseKey\command" -Force | Out-Null
    New-ItemProperty -Path $baseKey -Name '(default)' -Value $label -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $baseKey -Name 'MUIVerb' -Value $label -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $baseKey -Name 'Icon' -Value $icon -PropertyType String -Force | Out-Null
    New-ItemProperty -Path "$baseKey\command" -Name '(default)' -Value $command -PropertyType String -Force | Out-Null
}

foreach ($key in @($contextInstallKey, $contextInstallKeyUser)) {
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'InstallPath' -Value $appRoot -PropertyType String -Force | Out-Null
}

Write-Host "Instalado: $label" -ForegroundColor Green
Write-Host 'Afecta a: MKV, MP4, AVI, MOV, M4V, TS, M2TS, WEBM, WMV, FLV e ISO (discos completos).' -ForegroundColor Gray

# Windows 11 solo muestra en el primer menú los comandos registrados como una
# extensión moderna IExplorerCommand dentro de un paquete (sparse MSIX). El
# verbo clásico anterior se conserva como respaldo para Windows 10 y para
# «Mostrar más opciones».
if ((Test-Path -LiteralPath $modernPackage -PathType Leaf) -and
    (Test-Path -LiteralPath $modernCertificate -PathType Leaf) -and
    (Test-Path -LiteralPath $modernComHost -PathType Leaf)) {
    try {
        & (Join-Path $PSScriptRoot 'Instalar-RuntimeMenu.ps1')
        $certificateThumbprint = (Get-PfxCertificate -FilePath $modernCertificate).Thumbprint
        foreach ($store in @('Cert:\LocalMachine\TrustedPeople')) {
            try {
                Import-Certificate -FilePath $modernCertificate -CertStoreLocation $store -ErrorAction Stop | Out-Null
            } catch {
                Write-Warning "No pude confiar el certificado en ${store}: $($_.Exception.Message)"
            }
        }
        $machineCertificateTrusted = $false
        foreach ($store in @('Cert:\LocalMachine\TrustedPeople')) {
            if (@(Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
                    Where-Object Thumbprint -eq $certificateThumbprint).Count -gt 0) {
                $machineCertificateTrusted = $true
                break
            }
        }
        if (-not $machineCertificateTrusted) {
            throw 'El certificado del paquete moderno no está en los almacenes de confianza del equipo. Ejecuta esta instalación como administrador y acepta el aviso de UAC.'
        }
        $previous = Get-AppxPackage -Name 'HDZEROStudio.ContextMenu' -ErrorAction SilentlyContinue
        foreach ($pkg in @($previous)) {
            try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop } catch {}
        }
        try {
            Add-AppxPackage -Path $modernPackage -ExternalLocation $appRoot -ForceApplicationShutdown -ErrorAction Stop
            Write-Host 'Entrada moderna instalada en el primer menú de Windows 11.' -ForegroundColor Green
        } catch {
            # En equipos con una política que no acepta el certificado local,
            # la misma manifest se puede registrar como paquete de desarrollo.
            # Mantiene la extensión IExplorerCommand y no altera el registro
            # clásico; si tampoco se permite, se conserva el respaldo.
            if (-not (Test-Path -LiteralPath $registrationManifest -PathType Leaf)) {
                Copy-Item -LiteralPath $modernManifest -Destination $registrationManifest -Force
            }
            Add-AppxPackage -Register -Path (Resolve-Path -LiteralPath $registrationManifest) `
                -ExternalLocation $appRoot -ForceApplicationShutdown -ErrorAction Stop
            Write-Warning 'El paquete moderno quedó solo en modo desarrollo; Windows puede no mostrarlo en el primer menú. La entrada clásica sigue disponible en «Mostrar más opciones».'
        }
    } catch {
        Write-Warning "No pude registrar la entrada moderna de Windows 11: $($_.Exception.Message)"
        Write-Host 'La entrada clásica sigue disponible en «Mostrar más opciones».' -ForegroundColor Yellow
    }
} else {
    Write-Host 'No se encontró el paquete moderno; la entrada clásica queda en «Mostrar más opciones».' -ForegroundColor Yellow
}
