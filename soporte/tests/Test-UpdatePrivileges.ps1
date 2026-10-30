# No lanza UAC ni instala/desinstala componentes del equipo. Usa planes y fixtures.
$ErrorActionPreference='Stop'
$permissionAppRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($condition,$message){if(-not $condition){throw $message}}
# Conservar la definición completa y sus parámetros al importar, sin ejecutar la GUI.
$tokens=$null;$errors=$null
$guiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $permissionAppRoot 'HDZ-GUI.ps1'),[ref]$tokens,[ref]$errors)
$planNode=$guiAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HdzUpdateLaunchPlan'},$true)
. ([scriptblock]::Create($planNode.Extent.Text))
foreach($remote in @($false,$true)){
    $plan=Get-HdzUpdateLaunchPlan "C:\Users\O'Brien\HDZ Studio\instalacion\Actualizar-HDZStudio.ps1" 123 $false $remote
    Assert (-not $plan.Start.ContainsKey('Verb') -and -not $plan.ReopenAsOriginalUser) 'La instalación personal pide UAC'
    Assert ($plan.Start.WindowStyle -eq 'Hidden') 'Consola no deseada'
    Assert ($plan.Start.ArgumentList -contains '"C:\Users\O''Brien\HDZ Studio\instalacion\Actualizar-HDZStudio.ps1"') 'Ruta con espacios/apóstrofo mal escapada'
}
$adminPlan=Get-HdzUpdateLaunchPlan 'C:\Program Files\HDZ Studio\instalacion\Actualizar-HDZStudio.ps1' 123 $true $false
Assert ($adminPlan.Start.Verb -eq 'RunAs' -and $adminPlan.Start.PassThru -and $adminPlan.ReopenAsOriginalUser) 'El PC no pide UAC para la carpeta protegida'
Assert ($adminPlan.Start.ArgumentList -contains '-NoRelanzar') 'El actualizador elevado reabriría la GUI como administrador'
$blocked=$false
try{Get-HdzUpdateLaunchPlan 'C:\Program Files\HDZ Studio\instalacion\Actualizar-HDZStudio.ps1' 123 $true $true|Out-Null}catch{$blocked=$_.Exception.Message -match 'desde el PC' -and $_.Exception.Message -match 'carpeta de usuario'}
Assert $blocked 'La orden remota abriría UAC sin explicación'
$permissionTestRoot=Join-Path $env:TEMP ('hdz_test_permissions_'+[guid]::NewGuid().ToString('N'))
$fixture=Join-Path $permissionTestRoot 'app personal';$install=Join-Path $fixture 'instalacion';$bin=Join-Path $fixture 'bin'
foreach($dir in @($fixture,$install,$bin)){[void][IO.Directory]::CreateDirectory($dir)}
foreach($name in @('Actualizar-HDZStudio.ps1','Instalar-HDZStudio.ps1')){Copy-Item -LiteralPath (Join-Path $permissionAppRoot ('instalacion/'+$name)) -Destination (Join-Path $install $name)}
[IO.File]::WriteAllText((Join-Path $fixture 'HDZ-GUI.ps1'),'# fixture')
$toolNames=@('ffmpeg.exe','ffprobe.exe','mkvmerge.exe','mkvextract.exe','mkvpropedit.exe','MediaInfo.exe','dovi_tool.exe','PowerShell-7.6.3-win-x64.msi')
$tools=@(foreach($name in $toolNames){$path=Join-Path $bin $name;[IO.File]::WriteAllText($path,'fixture, never executable');@{name=$name;sha256=(Get-FileHash -LiteralPath $path).Hash}})
[IO.File]::WriteAllText((Join-Path $fixture 'tools.lock.json'),(@{version='fixture';files=$tools}|ConvertTo-Json -Depth 5))
# Evitar que el fixture MSI pudiera ejecutarse en un equipo que no tiene el runtime.
$nativeProgramFiles=if($env:ProgramW6432){$env:ProgramW6432}else{$env:ProgramFiles}
Assert (Test-Path -LiteralPath (Join-Path $nativeProgramFiles 'PowerShell/7/pwsh.exe')) 'La prueba necesita el runtime real ya instalado'
$shortcuts=@((Join-Path ([Environment]::GetFolderPath('Desktop')) 'HDZ Studio.lnk'),(Join-Path ([Environment]::GetFolderPath('Programs')) 'HDZ Studio.lnk'))
$before=@{};foreach($path in $shortcuts){$before[$path]=if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path).Hash}else{''}}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'Instalar-HDZStudio.ps1') -SkipContextMenu -SkipShortcuts
Assert ($LASTEXITCODE -eq 0) "Falló la configuración personal aislada: $permissionTestRoot"
Assert (Test-Path -LiteralPath (Join-Path $fixture 'HDZ Studio.vbs')) 'No se creó el lanzador personal'
foreach($path in $shortcuts){$after=if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path).Hash}else{''};Assert ($after -eq $before[$path]) 'La prueba alteró un acceso real'}
$setupAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $permissionAppRoot 'instalacion/Instalar-HDZStudio.ps1'),[ref]$tokens,[ref]$errors)
$runtimeNode=$setupAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HdzRuntimeInstallOptions'},$true)
. ([scriptblock]::Create($runtimeNode.Extent.Text))
Assert ((Get-HdzRuntimeInstallOptions 'C:\fixture.msi' $false).Verb -eq 'RunAs') 'El prerrequisito no pide sus propios permisos'
Assert (-not (Get-HdzRuntimeInstallOptions 'C:\fixture.msi' $true).ContainsKey('Verb')) 'Eleva innecesariamente el prerrequisito'
# El modo de reapertura nunca llama al actualizador. Solo usa un lanzador inocuo.
$marker=Join-Path $fixture 'reopened.txt'
[IO.File]::WriteAllText((Join-Path $fixture 'HDZ Studio.vbs'),('Set fs=CreateObject("Scripting.FileSystemObject"): fs.CreateTextFile("'+$marker+'.tmp", True).Close: fs.MoveFile "'+$marker+'.tmp", "'+$marker+'"'))
$waitProcess=Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 2') -PassThru -WindowStyle Hidden
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'Actualizar-HDZStudio.ps1') -ReabrirTrasProceso $waitProcess.Id -WaitForProcessId 2147483647
Assert ($LASTEXITCODE -eq 0) 'No terminó la espera del actualizador'
$limit=[datetime]::UtcNow.AddSeconds(5);while(-not (Test-Path -LiteralPath $marker) -and [datetime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 100}
Assert (Test-Path -LiteralPath $marker) 'No se reabrió con el ayudante del usuario original'
Remove-Item -LiteralPath $marker
# El actualizador puede fallar antes de que la GUI haya terminado de cerrarse.
$closingOwner=Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 2') -PassThru -WindowStyle Hidden
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'Actualizar-HDZStudio.ps1') -ReabrirTrasProceso 2147483647 -WaitForProcessId $closingOwner.Id
Assert ($LASTEXITCODE -eq 0) 'Fallo al esperar el cierre diferido de la GUI'
$limit=[datetime]::UtcNow.AddSeconds(5);while(-not(Test-Path -LiteralPath $marker) -and [datetime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 100}
Assert (Test-Path -LiteralPath $marker) 'Una salida rápida del actualizador impide reabrir'
Remove-Item -LiteralPath $marker
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'Actualizar-HDZStudio.ps1') -ReabrirTrasProceso 2147483647 -WaitForProcessId $PID
Assert ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $marker)) 'Reabre una segunda GUI si el proceso original sigue activo'
$uninstallAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $permissionAppRoot 'instalacion/Desinstalar-HDZStudio.ps1'),[ref]$tokens,[ref]$errors)
$shortcutNode=$uninstallAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-HdzShortcutOwner'},$true)
. ([scriptblock]::Create($shortcutNode.Extent.Text))
$shell=New-Object -ComObject WScript.Shell;$testShortcut=Join-Path $fixture 'test.lnk';$link=$shell.CreateShortcut($testShortcut);$link.TargetPath=Join-Path $env:WINDIR 'System32/wscript.exe';$link.Arguments='"'+(Join-Path $fixture 'HDZ Studio.vbs')+'"';$link.Save()
Assert (Test-HdzShortcutOwner $testShortcut $fixture) 'No reconoce un acceso propio'
Assert (-not (Test-HdzShortcutOwner $testShortcut (Join-Path $permissionTestRoot 'otra app'))) 'Quitaría accesos de otra instalación'
$iss=Get-Content -LiteralPath (Join-Path $permissionAppRoot 'instalacion/HDZStudio.iss') -Raw
Assert ($iss -match '(?m)^DefaultDirName=\{localappdata\}\\Programs\\HDZ Studio\s*$' -and $iss -match '(?m)^PrivilegesRequired=lowest\s*$' -and $iss -match '(?m)^UsePreviousAppDir=no\s*$') 'El instalador vuelve a Program Files o eleva todo el perfil'
Assert ($iss -match 'WizardIsTaskSelected' -and $iss -match 'SkipContextMenu') 'La integración opcional no respeta la elección'
Write-Host "UPDATE_PRIVILEGES_OK: local UAC plan, remote guard, personal setup PS5.1, original-user relaunch, no duplicate GUI, optional menu and shortcut ownership. $permissionTestRoot"
