# =========================================================================
# Entrada compatible con accesos directos anteriores.
param([switch]$Forzar, [switch]$NoRelanzar, [int]$WaitForProcessId=0)
& (Join-Path $PSScriptRoot 'Actualizar-Seguro.ps1') -Forzar:$Forzar -NoRelanzar:$NoRelanzar -WaitForProcessId $WaitForProcessId
