# =========================================================================
# Entrada compatible con accesos directos anteriores.
param([switch]$Forzar, [switch]$NoRelanzar, [int]$WaitForProcessId=0, [int]$ReabrirTrasProceso=0)
if($ReabrirTrasProceso -gt 0){
    # Iniciado por la GUI SIN elevación tras aceptar UAC. El actualizador
    # elevado usa -NoRelanzar: HDZ vuelve con su usuario y privilegios originales.
    $ErrorActionPreference='Stop'
    if($ReabrirTrasProceso -eq $PID -or $WaitForProcessId -eq $PID){throw 'Proceso de espera no válido.'}
    $deadline=[datetime]::UtcNow.AddMinutes(30)
    while(Get-Process -Id $ReabrirTrasProceso -ErrorAction SilentlyContinue){
        if([datetime]::UtcNow -ge $deadline){throw 'El actualizador sigue activo. No se abrirá HDZ mientras pueda estar modificando archivos.'}
        Start-Sleep -Milliseconds 500
    }
    # La GUI inicia este ayudante justo antes de cerrarse. Si el actualizador
    # falla muy rápido, hay que esperar ese cierre y no perder la reapertura.
    $closeDeadline=[datetime]::UtcNow.AddSeconds(30)
    if($WaitForProcessId -gt 0){
        while((Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $closeDeadline){Start-Sleep -Milliseconds 100}
        if(Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue){return}
    }
    $launcher=Join-Path (Split-Path $PSScriptRoot -Parent) 'HDZ Studio.vbs'
    if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){throw 'No se encuentra el lanzador de HDZ Studio.'}
    Start-Process wscript.exe -ArgumentList ('"'+$launcher+'"') -WindowStyle Hidden
    return
}
& (Join-Path $PSScriptRoot 'Actualizar-Seguro.ps1') -Forzar:$Forzar -NoRelanzar:$NoRelanzar -WaitForProcessId $WaitForProcessId
