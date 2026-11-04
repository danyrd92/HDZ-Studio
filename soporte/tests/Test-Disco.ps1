# Discos completos (ISO): BDInfo, nombre de la release y capturas desde ISOs sintéticos
# de Blu-ray y DVD creados aquí mismo. No usa discos ni archivos del usuario.
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PATH = (Join-Path $root 'bin') + ';' + $env:PATH
. (Join-Path $root 'HDZ-Capturas.ps1')
$testRoot = Join-Path $env:TEMP ('hdz_test_disco_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }

# --- 1. BDInfo: informe completo de un UHD con Dolby Vision ---------------
$bdinfoCompleto = @'
DISC INFO:

Disc Title:     AVATAR_FIRE_AND_ASH
Disc Label:     AVATAR_3
Disc Size:      88,123,456,789 bytes
Protection:     AACS2
Extras:         Ultra HD, BD-Java
BDInfo:         0.7.5.5

PLAYLIST REPORT:

Name:                   00800.MPLS
Length:                 3:17:21.123 (h:m:s.ms)

VIDEO:

Codec                   Bitrate             Description
-----                   -------             -----------
MPEG-H HEVC Video       58003 kbps          2160p / 23.976 fps / 16:9 / Main 10 @ Level 5.1 @ High / 10 bits / HDR10 / BT.2020
* MPEG-H HEVC Video     3926 kbps           1080p / 23.976 fps / 16:9 / Main 10 @ Level 5.1 @ High / 10 bits / Dolby Vision / BT.2020

AUDIO:

Codec                           Language        Bitrate         Description
-----                           --------        -------         -----------
Dolby TrueHD/Atmos Audio        English         4807 kbps       7.1+11 objects / 48 kHz / 4167 kbps / 24-bit (AC3 Core: 5.1-EX / 48 kHz / 640 kbps)
DTS Audio                       Spanish         1509 kbps       5.1 / 48 kHz / 1509 kbps / 24-bit

SUBTITLES:

Codec                           Language        Bitrate         Description
-----                           --------        -------         -----------
Presentation Graphics           Spanish         25.123 kbps
'@
$d = ConvertFrom-HdzBdinfo $bdinfoCompleto
Assert ($d.Resolucion -eq '2160p') "BDInfo: resolución '$($d.Resolucion)'"
Assert ($d.Codec -eq 'HEVC') "BDInfo: códec '$($d.Codec)'"
Assert ($d.HDR10 -and $d.DV -and -not $d.HDR10P) 'BDInfo: HDR10 + Dolby Vision mal detectados'
Assert ($d.Audio -eq 'DTS' -and $d.AudioCanales -eq '5.1') "BDInfo: debe elegir el castellano (DTS 5.1), no '$($d.Audio) $($d.AudioCanales)'"
Assert ($d.Etiqueta -eq 'AVATAR_FIRE_AND_ASH') "BDInfo: etiqueta '$($d.Etiqueta)'"
$nombre = Get-HdzDiscoNombre -Titulo 'Avatar: Fuego y ceniza' -Anio '2025' -Datos $d
Assert ($nombre -eq 'Avatar: Fuego y ceniza (2025) UHDFull 2160p DV HDR10 HEVC DTS 5.1') "Nombre: '$nombre'"
$archivo = ConvertTo-HdzNombreArchivo $nombre
Assert ($archivo -eq 'Avatar - Fuego y ceniza (2025) UHDFull 2160p DV HDR10 HEVC DTS 5.1') "Nombre de archivo: '$archivo'"

# --- 2. BDInfo: Quick Summary de un Blu-ray 1080p sin castellano ------------
$bdinfoResumen = @'
Disc Title: THE_FILM
Disc Size: 45,000,000,000 bytes
Protection: AACS
Playlist: 00001.MPLS
Size: 40,000,000,000 bytes
Length: 2:01:00.000
Total Bitrate: 40.00 Mbps
Video: MPEG-4 AVC Video / 30000 kbps / 1080p / 23.976 fps / 16:9 / High Profile 4.1
Audio: English / DTS-HD Master Audio / 7.1 / 48 kHz / 5000 kbps / 24-bit (DTS Core: 5.1 / 48 kHz / 1509 kbps / 24-bit)
Audio: French / Dolby Digital Audio / 5.1 / 48 kHz / 640 kbps
Subtitle: English / 30.000 kbps
'@
$d2 = ConvertFrom-HdzBdinfo $bdinfoResumen
Assert ($d2.Resolucion -eq '1080p' -and $d2.Codec -eq 'AVC') 'Quick Summary: vídeo mal leído'
Assert (-not $d2.HDR10 -and -not $d2.DV) 'Quick Summary: HDR falso'
Assert ($d2.Audio -eq 'DTS-HD MA' -and $d2.AudioCanales -eq '7.1') "Quick Summary: audio '$($d2.Audio) $($d2.AudioCanales)'"
$n2 = Get-HdzDiscoNombre -Titulo 'La película' -Anio '2020' -Datos $d2
Assert ($n2 -eq 'La película (2020) BDFull 1080p AVC DTS-HD MA 7.1') "Nombre BD: '$n2'"
Assert ((ConvertFrom-HdzBdinfo '').Resolucion -eq '') 'BDInfo vacío'

# --- 3. Título desde el nombre del ISO -----------------------------------
$ta = Get-HdzDiscoTituloDesdeArchivo 'Avatar.Fire.and.Ash.2025.UHD.BluRay.iso'
Assert ($ta.Titulo -eq 'Avatar Fire and Ash' -and $ta.Anio -eq '2025') "Título: '$($ta.Titulo)' '$($ta.Anio)'"
$ta2 = Get-HdzDiscoTituloDesdeArchivo 'Avatar 3 jupk.iso'
Assert ($ta2.Titulo -eq 'Avatar 3 jupk' -and -not $ta2.Anio) "Título suelto: '$($ta2.Titulo)'"
Assert (Test-HdzEsDisco 'C:\x\Peli.ISO') 'No reconoce .ISO'
Assert (-not (Test-HdzEsDisco 'C:\x\Peli.mkv')) 'Toma un MKV por disco'

# --- 4. ISOs sintéticos (UDF, como los de los discos reales) --------------
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
public static class HdzIsoTest {
  public static void Save(object stream, string path) {
    var s = (IStream)stream; byte[] b = new byte[1 << 20]; IntPtr p = Marshal.AllocHGlobal(4);
    try { using (var f = File.Create(path)) { while (true) { s.Read(b, b.Length, p); int n = Marshal.ReadInt32(p); if (n <= 0) break; f.Write(b, 0, n); } } }
    finally { Marshal.FreeHGlobal(p); }
  }
}
'@
function New-TestIso([string]$Carpeta, [string]$Iso, [string]$Etiqueta) {
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 4   # UDF
    $fsi.VolumeName = $Etiqueta
    $fsi.Root.AddTree($Carpeta, $false)
    [HdzIsoTest]::Save($fsi.CreateResultImage().ImageStream, $Iso)
}
function Assert-Desmontado([string]$Iso) {
    $img = Get-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue
    Assert (-not ($img -and $img.Attached)) "El ISO quedó montado: $Iso"
}

$isos = @()
try {
    # Blu-ray: BDMV\STREAM con la película (60 s) y un extra corto. Sin index.bdmv, la lectura
    # directa falla y se usa el respaldo: montar y tomar el .m2ts más grande.
    $bd = Join-Path $testRoot 'bd'
    [void][IO.Directory]::CreateDirectory((Join-Path $bd 'BDMV\STREAM'))
    & ffmpeg -v error -f lavfi -i 'testsrc2=s=320x180:r=24:d=60' -f lavfi -i 'sine=frequency=440:duration=60' -c:v libx264 -preset ultrafast -c:a ac3 -ac 6 -f mpegts (Join-Path $bd 'BDMV\STREAM\00001.m2ts')
    Assert ($LASTEXITCODE -eq 0) 'No se pudo crear la película del Blu-ray sintético'
    & ffmpeg -v error -f lavfi -i 'color=c=black:s=320x180:r=24:d=4' -c:v libx264 -preset ultrafast -f mpegts (Join-Path $bd 'BDMV\STREAM\00002.m2ts')
    Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el extra del Blu-ray sintético'
    $isoBd = Join-Path $testRoot 'Avatar 3 jupk.iso'
    New-TestIso $bd $isoBd 'TEST_BD'; $isos += $isoBd

    $disco = Open-HdzDisco $isoBd
    try {
        Assert ($disco.Montado -and $disco.Metodo -eq 'montado') 'El Blu-ray sintético no se montó'
        Assert ($disco.Entrada -like '*00001.m2ts') "No eligió la película principal: $($disco.Entrada)"
        Assert ($disco.Etiqueta -eq 'TEST_BD') "Etiqueta del volumen: '$($disco.Etiqueta)'"
        $datos = Get-HdzDiscoDatos $disco
        Assert ($datos.Codec -eq 'AVC' -and $datos.Audio -eq 'DD' -and $datos.AudioCanales -eq '5.1') "Datos ffprobe: $($datos.Codec) $($datos.Audio) $($datos.AudioCanales)"
        Assert (-not $datos.HDR10 -and -not $datos.DV) 'HDR falso en un SDR'
        Assert ($datos.Duracion -gt 50) "Duración: $($datos.Duracion)"
    } finally { Close-HdzDisco $disco }
    Assert-Desmontado $isoBd
    Assert (-not (Test-HdzVideoHdr $isoBd)) 'Test-HdzVideoHdr: el ISO SDR sale HDR'
    Assert-Desmontado $isoBd

    $caps = New-HdzCapturas -ArchivoVideo $isoBd -NumCapturas 3 -EsHdr $false -DirCapturas (Join-Path $testRoot 'caps_bd')
    Assert (@($caps.Capturas).Count -eq 3) "Capturas del Blu-ray: $(@($caps.Capturas).Count)/3"
    foreach ($c in $caps.Capturas) { Assert ((Split-Path $c -Leaf) -like 'Avatar 3 jupk_cap_*.png') "Nombre de captura: $c" }
    Assert-Desmontado $isoBd

    # Si el usuario ya tenía el ISO montado, se reutiliza y NO se le desmonta.
    Mount-DiskImage -ImagePath $isoBd -StorageType ISO | Out-Null
    try {
        $d3 = Open-HdzDisco $isoBd -SinLecturaDirecta
        Assert (-not $d3.Montado -and $d3.Unidad) 'No reutilizó el ISO ya montado'
        Close-HdzDisco $d3
        Assert ((Get-DiskImage -ImagePath $isoBd).Attached) 'Desmontó un ISO que montó el usuario'
    } finally { Dismount-DiskImage -ImagePath $isoBd | Out-Null }

    # El torrent de un ISO se crea como el de cualquier archivo.
    . (Join-Path $root 'HDZ-Torrent.ps1')
    $tor = New-TorrentArchivo $isoBd '' '' (Join-Path $testRoot 'torrent')
    Assert ($tor -and (Test-Path -LiteralPath $tor)) 'No se creó el torrent del ISO'

    # BDInfo guardado junto al ISO.
    Set-Content -LiteralPath (Join-Path $testRoot 'Avatar 3 jupk.txt') -Value $bdinfoCompleto -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $testRoot 'notas.txt') -Value 'nada que ver' -Encoding UTF8
    $junto = Get-HdzBdinfoJunto $isoBd
    Assert ($junto -and $junto.Ruta -like '*Avatar 3 jupk.txt' -and $junto.Texto -match 'DISC INFO') 'No encontró el BDInfo junto al ISO'

    # DVD: VIDEO_TS con la película en dos VOB (título 01) y un extra (título 02).
    $dvd = Join-Path $testRoot 'dvd'
    $vts = Join-Path $dvd 'VIDEO_TS'
    [void][IO.Directory]::CreateDirectory($vts)
    $vobLargo = Join-Path $testRoot 'largo.vob'
    & ffmpeg -v error -f lavfi -i 'testsrc2=s=720x576:r=25:d=40' -f lavfi -i 'sine=frequency=440:duration=40' -c:v mpeg2video -b:v 2M -c:a mp2 -aspect 16:9 -f vob $vobLargo
    Assert ($LASTEXITCODE -eq 0) 'No se pudo crear el VOB sintético'
    # Se parte en dos VOB consecutivos, como en un DVD real.
    $bytes = [IO.File]::ReadAllBytes($vobLargo)
    $mitad = [int]([Math]::Floor($bytes.Length / 2 / 2048) * 2048)
    [IO.File]::WriteAllBytes((Join-Path $vts 'VTS_01_1.VOB'), $bytes[0..($mitad - 1)])
    [IO.File]::WriteAllBytes((Join-Path $vts 'VTS_01_2.VOB'), $bytes[$mitad..($bytes.Length - 1)])
    & ffmpeg -v error -f lavfi -i 'color=c=black:s=720x576:r=25:d=3' -c:v mpeg2video -f vob (Join-Path $vts 'VTS_02_1.VOB')
    & ffmpeg -v error -f lavfi -i 'color=c=red:s=720x576:r=25:d=2' -c:v mpeg2video -f vob (Join-Path $vts 'VTS_01_0.VOB')
    $isoDvd = Join-Path $testRoot 'Pelicula DVD.iso'
    New-TestIso $dvd $isoDvd 'TEST_DVD'; $isos += $isoDvd

    $dd = Open-HdzDisco $isoDvd
    try {
        Assert ($dd.Tipo -eq 'dvd') "Tipo de disco: $($dd.Tipo)"
        Assert ($dd.Entrada -like 'concat:*VTS_01_1.VOB|*VTS_01_2.VOB') "VOB de la película: $($dd.Entrada)"
        Assert ($dd.Entrada -notlike '*VTS_01_0*' -and $dd.Entrada -notlike '*VTS_02*') 'Mezcla el menú o el extra con la película'
        $dvdDatos = Get-HdzDiscoDatos $dd
        Assert ($dvdDatos.Codec -eq 'MPEG-2' -and $dvdDatos.Resolucion -eq '576p') "Datos del DVD: $($dvdDatos.Codec) $($dvdDatos.Resolucion)"
        Assert ((Get-HdzDiscoMarca $dvdDatos 'dvd') -eq 'DVDFull') 'Marca del DVD'
    } finally { Close-HdzDisco $dd }
    $capsDvd = New-HdzCapturas -ArchivoVideo $isoDvd -NumCapturas 2 -EsHdr $false -DirCapturas (Join-Path $testRoot 'caps_dvd')
    Assert (@($capsDvd.Capturas).Count -eq 2) "Capturas del DVD: $(@($capsDvd.Capturas).Count)/2"
    # Aspecto corregido: 720x576 anamórfico 16:9 -> 1024x576.
    $ancho = "$(& ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 $capsDvd.Capturas[0])".Trim()
    Assert ($ancho -eq '1024') "La captura del DVD no corrige el aspecto (ancho $ancho)"
    Assert-Desmontado $isoDvd

    # --- 5. Interfaz: preparar el disco (nombre + renombrado), cargar su torrent y la ficha ---
    $env:HDZ_GUI_TEST = '1'; $env:HDZ_GUI_TEST_DIR = $testRoot; $env:HDZ_HISTORY_TEST_DIR = Join-Path $testRoot 'history'
    . (Join-Path $root 'HDZ-GUI.ps1')
    Reset-Todo
    $ui.cfgTmdbKey.Text = ''
    $nombreTracker = 'Avatar: Fuego y ceniza (2025) UHDFull 2160p DV HDR10 HEVC DTS 5.1'
    $script:discoRespuestaTest = @{ Accion = 'renombrar'; Nombre = $nombreTracker }
    $prep = Preparar-DiscoParaTorrent $isoBd
    $isoRenombrado = Join-Path $testRoot 'Avatar - Fuego y ceniza (2025) UHDFull 2160p DV HDR10 HEVC DTS 5.1.iso'
    $isos += $isoRenombrado
    Assert ($prep.Ruta -eq $isoRenombrado -and (Test-Path -LiteralPath $isoRenombrado)) "No se renombró el ISO: $($prep.Ruta)"
    Assert (-not (Test-Path -LiteralPath $isoBd)) 'Quedó el ISO con el nombre antiguo'
    Assert (Test-Path -LiteralPath ($isoRenombrado -replace '\.iso$', '.txt')) 'El BDInfo no se renombró con el ISO'
    Assert ($prep.NombreTracker -eq $nombreTracker) 'Se perdió el título del tracker (con «:»)'
    Assert ($prep.Datos.Fuente -eq 'bdinfo' -and $prep.Datos.DV) 'Los datos del disco no salieron del BDInfo'

    # Torrent junto al ISO, como al cargarlo a mano con «Examinar…» (sin pistas del creador).
    $torIso = New-TorrentArchivo $isoRenombrado '' '' $testRoot
    Cargar-TorrentParaSubir $torIso
    Assert ($script:videoSubir -eq $isoRenombrado) "La ficha no localizó el ISO: $($script:videoSubir)"
    Assert (Test-SubidaEsDisco) 'La ficha no se reconoce como disco'
    Assert ($ui.upMediainfo.Text -match 'DISC INFO') 'No se cargó el BDInfo en la ficha'
    Assert ($ui.lblMediainfoTitulo.Text -eq 'BDInfo' -and "$($ui.btnBdinfoCargar.Visibility)" -eq 'Visible') 'La tarjeta no pasó a modo BDInfo'
    Assert ((Get-ComboValor $ui.upTipo) -eq 3) "Tipo: $(Get-ComboValor $ui.upTipo) (se esperaba Full UHD)"
    Assert ((Get-ComboValor $ui.upResolucion) -eq 2) 'Resolución distinta de 2160p'
    Assert ($ui.upDV.IsChecked -and $ui.upHDR10.IsChecked) 'Specs DV/HDR10 sin marcar'
    $campos = Get-CamposInfoTecnica $ui.upMediainfo.Text $true
    Assert ($campos.bdinfo -match 'DISC INFO' -and $campos.mediainfo -eq '') 'Un disco debe enviar BDInfo y no MediaInfo'
    $camposMkv = Get-CamposInfoTecnica 'General' $false
    Assert ($camposMkv.mediainfo -eq 'General' -and -not $camposMkv.bdinfo) 'Un MKV debe seguir enviando MediaInfo'
    Reset-Todo
    Assert ($ui.lblMediainfoTitulo.Text -eq 'MediaInfo' -and "$($ui.btnBdinfoCargar.Visibility)" -eq 'Collapsed') 'Reiniciar no devuelve la tarjeta a MediaInfo'
    Assert-Desmontado $isoRenombrado
} finally {
    Remove-Item Env:HDZ_GUI_TEST, Env:HDZ_GUI_TEST_DIR, Env:HDZ_HISTORY_TEST_DIR -ErrorAction SilentlyContinue
    foreach ($i in $isos) { try { Dismount-DiskImage -ImagePath $i -ErrorAction SilentlyContinue | Out-Null } catch {} }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'DISCO_ISO_OK: BDInfo, nombre, montaje, capturas de Blu-ray y DVD, torrent, ficha BDInfo y desmontaje.'
