$ErrorActionPreference='Stop'
# Generación del BDInfo de un ISO con bin\BDInfo.exe: progreso, informe junto al ISO, fallos sin
# informes a medias y, en la interfaz, en segundo plano y en la pestaña que lo pidió.
$bdiTestRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($value,$message){if(-not $value){throw $message}}
$temp=Join-Path $env:TEMP ('hdz_bdinfo_gen_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$informe=@'
DISC INFO:

Disc Title:     PRUEBA_BDINFO
Disc Label:     PRUEBA_BDINFO
Disc Size:      40,168,587,264 bytes
Protection:     AACS
BDInfo:         2.0.6

PLAYLIST REPORT:

Name:                   00800.MPLS
Length:                 1:53:18.708 (h:m:s.ms)

VIDEO:

Codec                   Bitrate             Description
-----                   -------             -----------
MPEG-4 AVC Video        29999 kbps          1080p / 23.976 fps / 16:9 / High Profile 4.1

AUDIO:

Codec                           Language        Bitrate         Description
-----                           --------        -------         -----------
DTS-HD Master Audio             Spanish         2046 kbps       5.1 / 48 kHz / 2046 kbps / 16-bit
'@
# BDInfo simulado: mismo uso (-p ISO -o informe), progreso por la salida estándar.
$fakeDir=Join-Path $temp 'fake';[void][IO.Directory]::CreateDirectory($fakeDir)
[IO.File]::WriteAllText((Join-Path $fakeDir 'informe.txt'),$informe)
[IO.File]::WriteAllText((Join-Path $fakeDir 'fake.ps1'),@'
param([string]$p,[string]$o)
$modo=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'modo.txt')).Trim()
foreach($n in 1..4){ Write-Output ("Scanning 0000$n.M2TS | Progress:  {0},00% | Elapsed: 00:00:0$n | Remaining: 00:00:0{1}" -f ($n*25),(4-$n)); Start-Sleep -Milliseconds 150 }
if($modo -eq 'falla'){ Write-Output 'Error: no BDMV folder'; exit 3 }
if($modo -eq 'basura'){ [IO.File]::WriteAllText($o,'esto no es un informe'); exit 0 }
Copy-Item (Join-Path $PSScriptRoot 'informe.txt') $o
'@)
$fake=Join-Path $fakeDir 'BDInfo.cmd'
[IO.File]::WriteAllText($fake,"@pwsh -NoProfile -File `"%~dp0fake.ps1`" %*`r`n")
function Set-Modo($m){[IO.File]::WriteAllText((Join-Path $fakeDir 'modo.txt'),$m)}

. (Join-Path $bdiTestRoot 'HDZ-Disco.ps1')
# --- 1. Progreso ---
$p=Read-HdzBdinfoProgreso 'Scanning 00185.M2TS | Progress:   0,64% | Elapsed: 00:00:05 | Remaining: 00:14:08'
Assert ($p.Pct -eq 0.64 -and $p.Restante -eq '00:14:08') "Progreso mal leído: $($p.Pct) $($p.Restante)"
Assert ((Read-HdzBdinfoProgreso 'Progress: 57.5% | Remaining: 00:01:00').Pct -eq 57.5) 'Progreso con punto decimal'
Assert ($null -eq (Read-HdzBdinfoProgreso 'Please wait while we scan the disc...')) 'Una línea sin progreso no es progreso'

# --- 1b. Varias playlists: se queda la de MAYOR tamaño (no la más larga, que puede ser una trampa) ---
$varias=@"
Disc Title:     VARIAS
Disc Label:     VARIAS

********************
PLAYLIST: 00096.MPLS
********************
Name:                   00096.MPLS
Length:                 1:48:56.696 (h:m:s.ms)
Size:                   19,150,589,952 bytes
TRAMPA_LARGA

********************
PLAYLIST: 00001.MPLS
********************
Name:                   00001.MPLS
Length:                 1:28:34.684 (h:m:s.ms)
Size:                   22,450,237,440 bytes
PELICULA

QUICK SUMMARY:
Playlist: 00001.MPLS

********************
PLAYLIST: 00007.MPLS
********************
Name:                   00007.MPLS
Size:                   711,094,272 bytes
EXTRA
"@
$principal=Select-HdzBdinfoPrincipal $varias
Assert ($principal -match 'PELICULA' -and $principal -match 'QUICK SUMMARY' -and $principal -match 'Disc Label:\s+VARIAS') 'No eligió la playlist de la película con su cabecera'
Assert ($principal -notmatch 'TRAMPA_LARGA|EXTRA') 'Coló otras playlists en el informe'
Assert ((Select-HdzBdinfoPrincipal $informe) -eq $informe.TrimEnd()) 'Un informe de una sola playlist no debe cambiar'

# --- 2. Informe junto al ISO ---
$isoDir=Join-Path $temp 'Disco con espacios & símbolos';[void][IO.Directory]::CreateDirectory($isoDir)
$iso=Join-Path $isoDir 'Peli (2012) BDFull.iso';[IO.File]::WriteAllBytes($iso,[byte[]](1..64))
Set-Modo 'ok'
$sync=[hashtable]::Synchronized(@{Pct=0.0;Restante='';Cancelar=$false;Pid=0})
$ruta=Invoke-HdzBdinfo -RutaIso $iso -Exe $fake -Sync $sync
Assert ($ruta -eq (Join-Path $isoDir 'Peli (2012) BDFull.bdinfo.txt')) "Informe en sitio inesperado: $ruta"
Assert ($sync.Pct -eq 100) 'El progreso no llegó al 100 %'
$junto=Get-HdzBdinfoJunto $iso
Assert ($junto -and $junto.Ruta -eq $ruta) 'Get-HdzBdinfoJunto no encuentra el informe generado'
Assert ((ConvertFrom-HdzBdinfo $junto.Texto).Resolucion -eq '1080p') 'El informe generado no se interpreta'

# --- 3. Fallos: sin informe a medias ---
Remove-Item -LiteralPath $ruta
foreach($modo in 'falla','basura'){
    Set-Modo $modo
    $error1=$null;try{[void](Invoke-HdzBdinfo -RutaIso $iso -Exe $fake)}catch{$error1=$_.Exception.Message}
    Assert ($error1 -match 'BDInfo no pudo leer el disco') "Modo ${modo}: no avisó del fallo ($error1)"
    Assert (-not (Test-Path -LiteralPath $ruta)) "Modo ${modo}: dejó un informe junto al ISO"
}
$error2=$null;try{[void](Invoke-HdzBdinfo -RutaIso $iso -Exe (Join-Path $temp 'no-existe.exe'))}catch{$error2=$_.Exception.Message}
Assert ($error2 -match 'Falta la herramienta BDInfo') 'Sin BDInfo.exe debe decir que falta'

# --- 4. BDInfo real (bin\BDInfo.exe) con un ISO que no es un Blu-ray: falla limpio ---
$real=Get-HdzBdinfoExe (Join-Path $bdiTestRoot 'bin')
if($real){
    $error3=$null;try{[void](Invoke-HdzBdinfo -RutaIso $iso -Exe $real)}catch{$error3=$_.Exception.Message}
    Assert ($error3 -match 'BDInfo no pudo leer el disco') "BDInfo real con un ISO inválido: $error3"
    Assert (-not (Test-Path -LiteralPath $ruta)) 'BDInfo real dejó un informe a medias'
} else { Write-Host 'AVISO: bin\BDInfo.exe no está; se omite la pasada real.' }

# --- 5. Interfaz: en segundo plano, a su pestaña ---
$env:HDZ_GUI_TEST='1'
try {
    . (Join-Path $bdiTestRoot 'HDZ-GUI.ps1')
    Set-Item Function:Get-HdzBdinfoExe ({param([string]$Bin='') $fake}.GetNewClosure())
    function Wait-Bdinfo{
        # Sin GetNewClosure: el temporizador tiene que ver el mismo $script:bdiSync que la interfaz.
        $script:waitFrame=[Windows.Threading.DispatcherFrame]::new();$script:waitLimite=[DateTime]::Now.AddSeconds(60)
        $t=[Windows.Threading.DispatcherTimer]::new();$t.Interval=[TimeSpan]::FromMilliseconds(100)
        $t.Add_Tick({if(-not $script:bdiSync -or [DateTime]::Now -gt $script:waitLimite){$script:waitFrame.Continue=$false}});$t.Start()
        [Windows.Threading.Dispatcher]::PushFrame($script:waitFrame);$t.Stop()
        Assert (-not $script:bdiSync) 'El BDInfo no terminó'
    }
    Set-Modo 'ok'
    # 5a. Pestaña activa: rellena la ficha y las specs.
    $ui.upTitulo.Text='Disco A';$script:videoSubir=$iso;$ui.upMediainfo.Text=''
    Assert (Iniciar-BdinfoAsync $iso $script:subidaTabId) 'No arrancó el BDInfo'
    Assert (Test-BdinfoEnCurso) 'No figura en curso'
    Assert (@(Get-TareasAuxiliares | Where-Object {$_.tipo -eq 'bdinfo'}).Count -eq 1) 'No aparece en el panel de tareas'
    Wait-Bdinfo
    Assert ($ui.upMediainfo.Text -match 'PRUEBA_BDINFO') 'La ficha no recibió el BDInfo'
    Assert ($ui.lblTorrentInfo.Visibility -eq 'Collapsed') 'Quedó el aviso de progreso'
    # 5b. Generar con texto ya puesto: automático no pisa, manual (Reemplazar) sí.
    $ui.upMediainfo.Text='pegado a mano'
    Assert (Iniciar-BdinfoAsync $iso $script:subidaTabId) 'No arrancó el segundo BDInfo';Wait-Bdinfo
    Assert ($ui.upMediainfo.Text -eq 'pegado a mano') 'El automático pisó un BDInfo pegado a mano'
    Assert (Iniciar-BdinfoAsync $iso $script:subidaTabId $true) 'No arrancó el manual';Wait-Bdinfo
    Assert ($ui.upMediainfo.Text -match 'PRUEBA_BDINFO') 'Generar BDInfo (manual) no reemplazó el texto'
    # 5c. Cambias de pestaña mientras se genera: va a la pestaña que lo pidió.
    $ui.upMediainfo.Text='';$idA=$script:subidaTabId
    Assert (Iniciar-BdinfoAsync $iso $idA) 'No arrancó el BDInfo de A'
    Nueva-Tab;$ui.upTitulo.Text='Disco B';$ui.upMediainfo.Text=''
    Wait-Bdinfo
    Assert ([string]::IsNullOrWhiteSpace($ui.upMediainfo.Text)) 'El BDInfo de A cayó en la pestaña B'
    Assert ($script:tabs[0].Id -eq $idA -and $script:tabs[0].Mediainfo -match 'PRUEBA_BDINFO') 'La pestaña A no recibió su BDInfo'
    # 5d. Fallo: avisa y no rellena.
    Set-Modo 'falla';$ui.upMediainfo.Text=''
    Assert (Iniciar-BdinfoAsync $iso $script:subidaTabId) 'No arrancó el BDInfo fallido';Wait-Bdinfo
    Assert ([string]::IsNullOrWhiteSpace($ui.upMediainfo.Text) -and $ui.lblTorrentInfo.Text -match 'No se pudo generar el BDInfo') 'El fallo no se explicó en la ficha'
    # 5e. Sin herramienta: no arranca (queda el aviso de pegarlo a mano).
    Set-Item Function:Get-HdzBdinfoExe {param([string]$Bin='') $null}
    Assert (-not (Iniciar-BdinfoAsync $iso $script:subidaTabId)) 'Arrancó sin BDInfo.exe'
    Write-Host 'BDINFO_GENERAR_OK: progreso, informe junto al ISO, fallos limpios, BDInfo real, ficha, pestaña de origen y texto manual respetado.'
} finally {
    Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue
    try { Detener-Bdinfo } catch {}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
