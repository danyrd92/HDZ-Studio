$ErrorActionPreference='Stop'
$env:HDZ_GUI_TEST='1'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($condition,$message){if(-not $condition){throw $message}}
# «Cada archivo distinto»: cabeceras plegables por archivo en cada apartado y la casilla
# «Aplicar a todos los archivos lo elegido en el primero». Análisis simulado, sin vídeos reales.
try {
    . (Join-Path $root 'HDZ-GUI.ps1')
    $nombres=@('Uno.2001.1080p.NF.WEB-DL.mkv','Dos.2002.1080p.AMZN.WEB-DL.mkv','Tres.2003.1080p.HMAX.WEB-DL.mkv')
    $script:ultimoScan=@($nombres|ForEach-Object {
        @{Nombre=$_;Ruta="C:\v\$_";Error=$null;Video=@{Codec='hevc';Height=1080;EsDV=$false;EsHDR=$false}
          Audios=@(@{Index=1;TrackId=1;Codec='eac3';Profile='';Lang='eng';Title='';Forced=$false;Channels=6},@{Index=2;TrackId=2;Codec='eac3';Profile='';Lang='spa';Title='';Forced=$false;Channels=6})
          Subs=@(@{Index=3;TrackId=3;Codec='subrip';Lang='spa';Title='';Forced=$false;EsPGS=$false},@{Index=4;TrackId=4;Codec='subrip';Lang='eng';Title='';Forced=$false;EsPGS=$false})}
    })
    $script:gruposProy=@($nombres|ForEach-Object {@{Clave=$_;Principal=$_;Archivos=@($_)}})
    Set-ChipValor 'modoLote' 'HETEROGENEO'
    Actualizar-ModoLote

    # Al analizar: casilla visible y, en cada apartado, tres cabeceras plegadas sin cuerpo a la vista.
    Assert ($ui.panTabsGen.Visibility -eq 'Visible') 'La casilla de aplicar al resto no aparece'
    Assert (@($script:acordeones).Count -eq 4) 'Faltan apartados con cabeceras por archivo'
    foreach($acc in $script:acordeones){
        Assert ($acc.Arriba.Children.Count -eq 3 -and $acc.Abajo.Children.Count -eq 0) "Cabeceras incorrectas en $($acc.Key)"
        Assert ($acc.Cuerpo.Visibility -eq 'Collapsed') "Opciones desplegadas al empezar en $($acc.Key)"
    }
    foreach($card in @($ui.cardModoLote,$ui.cardRemezcla)){
        Assert (-not @($script:acordeones|Where-Object {$_.Cuerpo.Child.Children.Contains($card)}).Count) 'Una opción común quedó dentro de un archivo'
    }
    $entrega=@($script:acordeones|Where-Object Key -eq 'entrega')[0]
    Assert ($entrega.Cuerpo.Child.Children.Contains((Get-HdzCard $ui.txtSalidaArchivo))) 'Las carpetas de salida no van dentro de cada archivo'

    # Desplegar el 2: queda activo, con una cabecera encima y otra debajo de sus opciones.
    Switch-HdzArchivoAcordeon 1
    Assert ($script:tabProyActual -eq 1 -and $script:acordeonAbierto) 'Desplegar no activa el archivo'
    foreach($acc in $script:acordeones){
        Assert ($acc.Arriba.Children.Count -eq 2 -and $acc.Abajo.Children.Count -eq 1 -and $acc.Cuerpo.Visibility -eq 'Visible') "Archivo 2 mal desplegado en $($acc.Key)"
    }
    Switch-HdzArchivoAcordeon 1
    Assert (-not $script:acordeonAbierto -and $script:acordeones[0].Cuerpo.Visibility -eq 'Collapsed') 'Volver a pulsar no pliega'

    # Archivo 1: título propio, 20 capturas, plataforma escrita, sin la pista de audio castellana y una conversión.
    Switch-HdzArchivoAcordeon 0
    $ui.txtTitulo.Text='Primero';$ui.txtPlataformaOtra.Text='COPIA';Set-ChipValor 'capturasProy' 20
    $fila=@($script:audioTrackRows|Where-Object {$_.Id -eq 2})[0]
    Set-HdzTrackSelected 'Audio' $fila $false
    [void](Add-FilaConv)
    $conv0=@(Leer-ConversionesActuales)
    Assert ($conv0.Count -eq 1) 'No se pudo preparar la conversión del archivo 1'
    $titulo2="$($script:tabsProy[1].Estado.Titulo)"

    $ui.swAplicarPrimero.IsChecked=$true
    Cambiar-SincroPrimero
    Assert ($script:tabProyActual -eq 0 -and $ui.txtTitulo.Text -eq 'Primero') 'Activar la casilla cambió el archivo visible'
    for($i=1;$i -lt 3;$i++){
        $t=$script:tabsProy[$i]
        Assert ([int]$t.Estado.Capturas -eq 20 -and $t.Estado.PlatOtra -eq 'COPIA') "El archivo $($i+1) no copió capturas/plataforma"
        Assert ($t.Estado.Titulo -ne 'Primero') "El archivo $($i+1) perdió su título"
        $fuera=@($t.Decisiones.AudioTracksExcluded|ForEach-Object {"$($_.Archivo)|$($_.Id)"})
        Assert ($fuera -contains "C:\v\$($nombres[$i])|2" -and $fuera.Count -eq 1) "El archivo $($i+1) no quitó su pista castellana"
        Assert (@($t.Decisiones.Conv).Count -eq 1 -and "$(@($t.Decisiones.Conv)[0].ArchivoFuente)" -eq "C:\v\$($nombres[$i])") "El archivo $($i+1) no tradujo la conversión a su pista"
    }
    Assert ($script:tabsProy[1].Estado.Titulo -eq $titulo2) 'La copia pisó el título del archivo 2'
    Assert ($script:audioTracksExcluded.ContainsKey("C:\v\$($nombres[0])|2")) 'El archivo 1 perdió su propia selección'

    # Con la casilla: en Audio y Entrega los archivos 2+ no se despliegan; en Identidad sí, con el origen bloqueado.
    $audio=@($script:acordeones|Where-Object Key -eq 'audio')[0]
    Assert (@($audio.Abajo.Children|Where-Object {$_.Opacity -lt 1}).Count -eq 2) 'Audio deja editar los archivos copiados'
    Switch-HdzArchivoAcordeon 2
    Assert ($script:tabProyActual -eq 2) 'Identidad no deja abrir el archivo 3'
    Assert ($audio.Cuerpo.Visibility -eq 'Collapsed') 'Audio muestra las opciones de un archivo copiado'
    Assert (-not (Get-HdzCard $ui.chOrigen).IsEnabled) 'El origen del archivo 3 se puede tocar con la casilla activada'
    Assert ($ui.txtTitulo.Text -eq $script:tabsProy[2].Estado.Titulo) 'Identidad del archivo 3 sin su título'

    # Un cambio posterior en el archivo 1 llega al resto al cambiar de archivo.
    Switch-HdzArchivoAcordeon 0
    Set-ChipValor 'capturasProy' 3
    Switch-HdzArchivoAcordeon 1
    Assert ([int]$script:tabsProy[2].Estado.Capturas -eq 3 -and [int](Get-ChipValor 'capturasProy') -eq 3) 'El cambio del archivo 1 no llegó al resto'

    # Sin casilla, cada archivo vuelve a ser independiente y el origen editable.
    $ui.swAplicarPrimero.IsChecked=$false
    Cambiar-SincroPrimero
    Assert ((Get-HdzCard $ui.chOrigen).IsEnabled) 'El origen sigue bloqueado sin la casilla'
    Set-ChipValor 'capturasProy' 20
    Switch-HdzArchivoAcordeon 0
    Assert ([int]$script:tabsProy[1].Estado.Capturas -eq 20 -and [int](Get-ChipValor 'capturasProy') -eq 3) 'Sin casilla, los archivos no son independientes'

    # Sin lote no hay pack: «Pack del lote» y «Ambos» se ocultan y una elección así pasa a «Uno por archivo».
    $pack=@($script:gruposChips['torrent']|Where-Object {$_.Valor -in @('PACK','AMBOS')})
    Assert (@($pack|Where-Object {$_.Radio.Visibility -eq 'Visible'}).Count -eq 0) 'Pack del lote visible en «Cada archivo distinto»'
    Set-ChipValor 'torrent' 'PACK';Actualizar-OpcionesTorrentLote
    Assert ((Get-ChipValor 'torrent') -eq 'INDIVIDUAL') 'Queda elegido el pack del lote'

    # Carpetas de salida propias: cada archivo guarda la suya y el motor las recibe por archivo.
    $fixture=Join-Path $env:TEMP ('hdz_acordeon_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
    $ui.txtCarpeta.Text=$fixture;$script:seleccion=@{};foreach($n in $nombres){$script:seleccion[$n]=$true}
    $ui.txtSalidaArchivo.Text='D:\Salida\Uno';$ui.txtSalidaTorrent.Text='D:\Torrents\Uno'
    Switch-HdzArchivoAcordeon 1
    Assert ($ui.txtSalidaArchivo.Text -ne 'D:\Salida\Uno') 'El archivo 2 hereda la carpeta del 1'
    $ui.txtSalidaArchivo.Text='E:\Salida\Dos';$ui.txtSalidaTorrent.Text=''
    Switch-HdzArchivoAcordeon 2
    $ui.txtSalidaArchivo.Text='';$ui.txtSalidaTorrent.Text=''
    Switch-HdzArchivoAcordeon 0
    Assert ($ui.txtSalidaArchivo.Text -eq 'D:\Salida\Uno' -and $ui.txtSalidaTorrent.Text -eq 'D:\Torrents\Uno') 'El archivo 1 perdió sus carpetas'
    foreach($i in 0..2){$script:tabsProy[$i].Estado.Titulo="Peli $i"}
    $ui.txtTitulo.Text='Peli 0'
    $script:testJobsMontaje=@();Iniciar-Montaje 'todos'
    Assert (@($script:testJobsMontaje).Count -ge 1) "No se lanzó el montaje: $($ui.lblEstado.Text)"
    $cfgs=@($script:testJobsMontaje|ForEach-Object {$_.CfgJson|ConvertFrom-Json})
    $sal=@{};$tor=@{};foreach($c in $cfgs){
        Assert (-not $c.CarpetaSalida -and -not $c.CarpetaTorrent) 'Se envía la carpeta global de una película a todas'
        Assert ("$($c.ModoTorrent)" -notin @('PACK','AMBOS')) 'Se envía un pack del lote'
        if($c.CarpetaSalidaPorArchivo){foreach($p in $c.CarpetaSalidaPorArchivo.PSObject.Properties){$sal[$p.Name]=$p.Value}}
        if($c.CarpetaTorrentPorArchivo){foreach($p in $c.CarpetaTorrentPorArchivo.PSObject.Properties){$tor[$p.Name]=$p.Value}}
    }
    Assert ($sal[$nombres[0]] -eq 'D:\Salida\Uno' -and $sal[$nombres[1]] -eq 'E:\Salida\Dos' -and -not $sal.ContainsKey($nombres[2])) "Carpetas MKV por archivo incorrectas: $(($sal.GetEnumerator()|ForEach-Object {"$($_.Key)=$($_.Value)"}) -join '; ')"
    Assert ($tor[$nombres[0]] -eq 'D:\Torrents\Uno' -and -not $tor.ContainsKey($nombres[1])) 'Carpetas .torrent por archivo incorrectas'
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue

    # Mismo proyecto: sin cabeceras ni casilla, con todas las opciones a la vista.
    Set-ChipValor 'modoLote' 'HOMOGENEO'
    Actualizar-ModoLote
    Assert ($ui.panTabsGen.Visibility -eq 'Collapsed') 'La casilla sale en «Mismo proyecto»'
    foreach($acc in $script:acordeones){Assert ($acc.Arriba.Children.Count -eq 0 -and $acc.Cuerpo.Visibility -eq 'Visible') "Cabeceras en modo homogéneo ($($acc.Key))"}
    Assert (@($pack|Where-Object {$_.Radio.Visibility -ne 'Visible'}).Count -eq 0) 'El pack del lote no vuelve en «Mismo proyecto»'
    $ui.swAplicarPrimero.IsChecked=$true
    Reset-Todo
    Assert (-not $ui.swAplicarPrimero.IsChecked -and -not $script:acordeonAbierto) 'Empezar de Zero conserva la casilla'
    Write-Host 'ACORDEON_ARCHIVOS_OK: cabeceras plegadas por archivo, despliegue, copia del primero (sin título), traducción de pistas y conversiones, bloqueo y modo homogéneo.'
} finally {Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue}
