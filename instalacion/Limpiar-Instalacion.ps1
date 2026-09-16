# Solo para el desinstalador registrado. No acepta directorios arbitrarios.
param([Parameter(Mandatory)][string]$InstallPath, [int]$ParentId)
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HDZ Studio'
$registered = Get-ItemProperty -LiteralPath $key
$installed = [IO.Path]::GetFullPath("$($registered.InstallLocation)").TrimEnd('\')
if ($target -ne $installed -or $target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\') -or $target -eq [Environment]::GetFolderPath('UserProfile') -or -not (Test-Path -LiteralPath (Join-Path $target 'HDZ-GUI.ps1')) -or -not (Test-Path -LiteralPath (Join-Path $target 'VERSION.txt'))) { throw 'No se reconoce el destino. No se borra nada.' }
if ($ParentId) {
    $parentProcess = Get-Process -Id $ParentId -ErrorAction SilentlyContinue
    if ($parentProcess -and -not $parentProcess.WaitForExit(30000)) { throw 'El desinstalador no ha terminado; se cancela la limpieza.' }
}
$running = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -match 'pwsh|ffmpeg|mkvmerge' -and $_.CommandLine -like "*$target*" })
if ($running.Count) { throw 'Hay procesos de HDZ Studio activos. Cierra el programa antes de desinstalar.' }
Remove-Item -LiteralPath $target -Recurse -Force
Remove-Item -LiteralPath $key -Recurse -Force
