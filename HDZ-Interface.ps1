# Presentation only: existing media/torrent controls and handlers remain authoritative.
function Get-HdzUiTexts($node) {
    if ($node -is [Windows.Controls.TextBlock]) { $node }
    foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($node)) {
        if ($child -is [Windows.DependencyObject]) { Get-HdzUiTexts $child }
    }
}
function Get-HdzCard($control) {
    $node = $control
    while ($node) {
        if ($node -is [Windows.Controls.Border] -and $node.Style -eq $win.Resources['Card']) { return $node }
        $node = [Windows.LogicalTreeHelper]::GetParent($node)
    }
}
function Move-HdzControl($control, $target) {
    if (-not $control) { return }
    $parent = [Windows.LogicalTreeHelper]::GetParent($control)
    if ($parent -is [Windows.Controls.Panel]) { [void]$parent.Children.Remove($control) }
    elseif ($parent -is [Windows.Controls.Decorator]) { $parent.Child=$null }
    else { throw "No se puede reubicar $($control.Name) sin conservar su propietario." }
    [void]$target.Children.Add($control)
}
function New-HdzUiSection($title, $expanded=$false) {
    $section = [Windows.Controls.Expander]::new()
    $section.Header=$title; $section.IsExpanded=$expanded; $section.Foreground=$win.Resources['TextBrush']
    $section.Margin='0,16,0,8'; $section.FontSize=15
    $section.Content=[Windows.Controls.StackPanel]::new()
    return $section
}
function Get-HdzRemixPresentation {
    $sources=@(Leer-RemezclaCarpetas)
    if (-not $ui.swRemezcla.IsChecked -or $sources.Count -lt 2) { return @() }
    $signature=($sources | ForEach-Object { "$($_.Ruta)|$($_.Archivo)|$($_.Video)|$($_.Audio)|$($_.Subs)" }) -join ';'
    if ($signature -eq $script:remixPresentationKey) { return @($script:remixPresentation) }
    $script:remixPresentationKey=$signature
    $rows=@()
    if (Es-RemezclaSeriePorEpisodio $sources) {
        $base=@($sources | Where-Object Video)[0]
        if ($base) {
            $map=Get-MapaEpisodiosRemezcla $base.Ruta
            foreach ($source in @($sources | Where-Object { -not $_.Video -and ($_.Audio -or $_.Subs) })) {
                $donors=Get-MapaEpisodiosRemezcla $source.Ruta; $used=@{}
                foreach ($ep in @($map.Keys | Sort-Object)) {
                    $matches=@($donors.Keys | Where-Object { Test-HdzEpisodeMatch $_ $ep })
                    foreach ($match in $matches) { $used[$match]=$true }
                    $files=@($matches | ForEach-Object { $donors[$_] })
                    $rows+=@{ episodio="$ep"; video=(@($map[$ep]) | ForEach-Object { Split-Path $_ -Leaf }) -join ', '; fuente=$source.Ruta; pistas=($files | ForEach-Object { Split-Path $_ -Leaf }) -join ', '; estado=$(if($matches.Count -eq 1 -and $files.Count -eq 1){'Emparejado'}elseif($matches.Count -eq 0){'Sin pareja'}else{'Ambiguo'}) }
                }
                foreach ($ep in @($donors.Keys | Where-Object { -not $used.ContainsKey($_) } | Sort-Object)) {
                    $rows+=@{episodio="$ep";video='';fuente=$source.Ruta;pistas=(@($donors[$ep]) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ';estado='Donante sin pareja'}
                }
            }
        }
    }
    $script:remixPresentation=@($rows)
    return @($rows)
}
function Get-HdzInterfaceState {
    if ($script:sectionSummaries) {
        $count=@($script:videosElegidos).Count
        $script:sectionSummaries.general.Text=if($count){if($count -eq 1){'1 vídeo elegido'}else{"$count vídeos elegidos"}}else{$folders=@(Get-CarpetasEntrada).Count;if($folders -eq 1){'1 carpeta'}else{"$folders carpetas"}}
        $script:sectionSummaries.proyecto.Text="$($ui.txtTitulo.Text) · $($ui.txtAno.Text)".Trim(' ','·')
    }
    if (Get-Command Update-HdzDesignState -ErrorAction SilentlyContinue) { Update-HdzDesignState }
    $busy=[bool]$script:networkBusy
    $hasVideos=@($script:ultimoScan).Count -gt 0
    $hasTorrent=-not [string]::IsNullOrWhiteSpace($ui.txtTorrentSubir.Text)
    $actions=[ordered]@{}
    foreach ($entry in @(@('iniciar','btnIniciar'),@('iniciar_todos','btnIniciarTodos'),@('subir','btnSubir'),@('send_log','btnEnviarLog'),@('capturas','btnCapGenerar'),@('imagenes','btnCapInsertar'))) {
        $enabled=$ui[$entry[1]].IsEnabled -and -not $busy
        if ($entry[0] -like 'iniciar*') { $enabled=$enabled -and $hasVideos }
        if ($entry[0] -eq 'subir') { $enabled=$enabled -and $hasTorrent }
        $actions[$entry[0]]=@{enabled=[bool]$enabled;reason=$(if($busy){'Petición en curso'}elseif(-not $enabled){'Prepara los archivos y espera a que termine la tarea actual'}else{''})}
    }
    $mkv=$ui.txtSalidaArchivo.Text
    if (-not $mkv) { $mkv='Junto al vídeo de origen (o su salida individual)' }
    $torrent=$ui.txtSalidaTorrent.Text
    if (-not $torrent) { $torrent=$ui.cfgCarpetaTorrent.Text }
    if (-not $torrent) { $torrent='Junto al vídeo de origen' }
    $secrets=[ordered]@{}
    foreach ($pair in @(@('cfgTrackerToken','cfgTrackerToken'),@('cfgTmdbKey','cfgTmdbKey'),@('cfgImgbbKey','cfgImgbbKey'),@('announce','txtAnnounce'))) {
        $secrets[$pair[0]]=-not [string]::IsNullOrWhiteSpace($ui[$pair[1]].Text)
    }
    $secrets.cfgImgboxPass=-not [string]::IsNullOrWhiteSpace($ui.cfgImgboxPass.Password)
    return [ordered]@{schema=1;actions=$actions;sections=@{modoLote=($ui.cardModoLote.Visibility -eq 'Visible');subFiltro=($ui.cardFiltro.Visibility -eq 'Visible')};credentials=$secrets;salidas=@{mkv="$mkv";torrent="$torrent"};seleccion=$(if(@($script:videosElegidos).Count){"$(@($script:videosElegidos).Count) vídeo(s) elegidos explícitamente"}else{"$(@(Get-CarpetasEntrada).Count) carpeta(s) de entrada"});remezcla=@(Get-HdzRemixPresentation)}
}
function Show-HdzRemixPairs {
    if (-not $script:remixPairsPanel) { return }
    $script:remixPairsPanel.Children.Clear()
    foreach($pair in @(Get-HdzRemixPresentation)) {
        $text=[Windows.Controls.TextBlock]::new();$text.Text="$($pair.episodio.ToUpper()) · $($pair.estado)`n$($pair.video)`n$($pair.pistas)`n$($pair.fuente)";$text.TextWrapping='Wrap';$text.Foreground=$win.Resources['SubBrush'];$text.Margin='0,6,0,6';[void]$script:remixPairsPanel.Children.Add($text)
    }
}
function Initialize-HdzInterface {
    $script:barraEntrada=Get-HdzCard $ui.txtCarpeta
    # The entry bar is not styled as a card in the original XAML.
    if (-not $script:barraEntrada) { $script:barraEntrada=[Windows.LogicalTreeHelper]::GetParent([Windows.LogicalTreeHelper]::GetParent($ui.txtCarpeta)); $script:barraEntrada=[Windows.LogicalTreeHelper]::GetParent($script:barraEntrada) }
    $ui.panGeneral.Visibility='Visible'; $ui.secChevGeneral.Text='▾'
    $script:remixPairsPanel=[Windows.Controls.StackPanel]::new()
    [void]$ui.panRemezcla.Children.Add($script:remixPairsPanel)
    $remixNote=[Windows.Controls.TextBlock]::new();$remixNote.Text='Las fuentes aportan las pistas; después se aplican los filtros de idiomas y las conversiones de Audio y Subtítulos.';$remixNote.TextWrapping='Wrap';$remixNote.Foreground=$win.Resources['SubBrush'];$remixNote.Margin='0,9,0,0';[void]$ui.panRemezcla.Children.Add($remixNote)
    foreach ($pair in @(@('secHdrGeneral','Entrada y trabajos'),@('secHdrProyecto','Identificación y origen'))) {
        $text=@(Get-HdzUiTexts $ui[$pair[0]] | Where-Object { $_.Name -notlike 'secChev*' })[0]
        if($text){$text.Text=$pair[1]}
    }
    $script:sectionSummaries=@{}
    foreach($pair in @(@('general','secHdrGeneral'),@('proyecto','secHdrProyecto'),@('audio','secHdrAudio'),@('subs','secHdrSubs'))) {
        $title=@(Get-HdzUiTexts $ui[$pair[1]] | Where-Object { $_.Name -notlike 'secChev*' })[0]
        $summary=[Windows.Controls.TextBlock]::new();$summary.FontSize=11;$summary.Foreground=$win.Resources['SubBrush'];$summary.Margin='12,0,0,0';$summary.MaxWidth=230;$summary.TextTrimming='CharacterEllipsis';$summary.VerticalAlignment='Center'
        $owner=[Windows.LogicalTreeHelper]::GetParent($title)
        if($owner -is [Windows.Controls.Panel]){[void]$owner.Children.Add($summary)}
        $script:sectionSummaries[$pair[0]]=$summary
    }
    # Keep only the authoritative selector, above all collapsible project sections.
    Move-HdzControl $ui.panTabsGen $ui.panCrear
    [void]$ui.panCrear.Children.Remove($ui.panTabsGen); $ui.panCrear.Children.Insert(0,$ui.panTabsGen)
    $output=New-HdzUiSection 'Salida y originales'
    $deliver=New-HdzUiSection 'Torrent y capturas del montaje'
    foreach ($control in @($ui.chOriginales,$ui.chSufijo,$ui.txtSalidaArchivo)) { Move-HdzControl (Get-HdzCard $control) $output.Content }
    Move-HdzControl (Get-HdzCard $ui.chTorrent) $deliver.Content
    Move-HdzControl $ui.cardCapturasProy $deliver.Content
    [void]$ui.panCrear.Children.Add($output); [void]$ui.panCrear.Children.Add($deliver)
    # Expose where outputs go, without changing any path-selection rules.
    $script:outputSummary=[Windows.Controls.TextBlock]::new();$script:outputSummary.TextWrapping='Wrap';$script:outputSummary.Foreground=$win.Resources['SubBrush'];$script:outputSummary.Margin='12,8,12,8'
    [void]$output.Content.Children.Add($script:outputSummary)
    $output.Add_Expanded({ $paths=(Get-HdzInterfaceState).salidas; $script:outputSummary.Text="MKV: $($paths.mkv)`nTorrent: $($paths.torrent)" })
    foreach ($pair in @(@($ui.panAudio,@('panProyTabsA','cardAudioTracks','cardConvAudio','cardDefAudio','cardUndAudio')),@($ui.panSubs,@('panProyTabsS','cardSubTracks','cardSubsUnicos','cardPGS','cardUndSub')))) {
        $index=0
        foreach($name in $pair[1]) { $control=$ui[$name]; if($control){[void]$pair[0].Children.Remove($control);$pair[0].Children.Insert($index++,$control)} }
    }
    # Match the upload order across desktop and mobile.
    $upload=$ui.panSubidaBody.Child
    $resources=New-HdzUiSection 'Descripción y recursos' $true
    $captureCard=Get-HdzCard $ui.panCapturas
    foreach($card in @($ui.cardLogos,$captureCard,(Get-HdzCard $ui.upDescripcion),$ui.cardFirmas)) { Move-HdzControl $card $resources.Content }
    $identify=Get-HdzCard $ui.upTmdb
    [void]$upload.Children.Remove($identify);$upload.Children.Insert(1,$identify)
    $upload.Children.Insert(3,$resources)
    $settings=@($ui.panAjustes.Children)
    $tmdbCard=Get-HdzCard $ui.cfgTmdbKey
    [void]$ui.panAjustes.Children.Remove($tmdbCard);$ui.panAjustes.Children.Insert(1,$tmdbCard)
    foreach($name in @('cfgTrackerToken','cfgTmdbKey','cfgImgbbKey','txtAnnounce','cfgImgboxPass')) {
        $field=$ui[$name];$parent=[Windows.LogicalTreeHelper]::GetParent($field)
        if($parent -isnot [Windows.Controls.Panel]){continue}
        $row=[Windows.Controls.StackPanel]::new();$row.Orientation='Horizontal';$row.Margin='0,4,0,6'
        $badge=[Windows.Controls.TextBlock]::new();$badge.Foreground=$win.Resources['SubBrush'];$badge.VerticalAlignment='Center'
        $badge.Text=if($field -is [Windows.Controls.PasswordBox]){if($field.Password){'Configurada'}else{'Sin configurar'}}else{if($field.Text){'Configurada'}else{'Sin configurar'}}
        $field.Tag=$badge
        if($field -is [Windows.Controls.PasswordBox]){$field.Add_PasswordChanged({param($sender) $sender.Tag.Text=if($sender.Password){'Configurada'}else{'Sin configurar'}})}
        else{$field.Add_TextChanged({param($sender) $sender.Tag.Text=if($sender.Text){'Configurada'}else{'Sin configurar'}})}
        $edit=[Windows.Controls.Button]::new();$edit.Style=$win.Resources['GhostMini'];$edit.Content='Mostrar / cambiar';$edit.Tag=$field;$edit.Margin='10,0,0,0'
        $edit.Add_Click({param($sender) $sender.Tag.Visibility=if($sender.Tag.Visibility -eq 'Visible'){'Collapsed'}else{'Visible'}})
        $field.Visibility='Collapsed';[void]$row.Children.Add($badge);[void]$row.Children.Add($edit)
        $parent.Children.Insert($parent.Children.IndexOf($field),$row)
    }
    $info=New-HdzUiSection 'Información y conexión'
    $infoText=[Windows.Controls.TextBlock]::new();$infoText.Foreground=$win.Resources['SubBrush'];$infoText.TextWrapping='Wrap';$infoText.Text="HDZ Studio v$($script:HDZVersion). La web remota controla esta instancia; las rutas elegidas son rutas de este PC. El indicador de conexión y respuesta se consulta desde la web.";$infoText.Margin='12,8,12,8';[void]$info.Content.Children.Add($infoText);[void]$ui.panAjustes.Children.Add($info)
    # Correct visible copy, never the media configuration values.
    $copy=@{
        'Análisis del lote'='Archivos y fuentes del trabajo';
        'Subtítulos sin señal: ¿forzado o completo?'='Subtítulos sin tipo definido: ¿forzado o completo?';
        'Host de imágenes'='Servidores de imágenes';
        'Opciones'='Etiquetas y opciones del tracker';
        'Tipo'='Tipo de release';
        'Si no hay capturas junto al vídeo, créalas aquí (📷). Marca las que quieras y pulsa «Subir y añadir»: se suben como PNG y se insertan como miniaturas enlazadas al original. Clic en una miniatura para verla a tamaño completo.'='Crea o añade capturas, selecciónalas y pulsa «Subir y añadir». Se usan enlaces directos a tamaño completo con [img=350]…[/img], en filas de cinco.';
        'Elige tu servidor preferido. Si falla, se probarán automáticamente los demás. freeimage, imgbox y Pixhost no necesitan clave; imgbb solo se usará si tiene clave. Se conserva la imagen original y una miniatura proporcional enlazada.'='Elige el servidor preferido. Si falla, se prueban los demás. imgbb requiere clave. Se enlaza la imagen original, sin envoltorios [url].';
        'Las opciones se adaptan a lo detectado en tus vídeos. Todo se decide aquí: el montaje corre sin preguntar nada en consola.'='Configura aquí el montaje. El OCR de PGS requiere Subtitle Edit y confirmar en el PC.';
        'El título y el año se usan para nombrar el resultado. El título es obligatorio: el montaje no pregunta nada en consola.'='El título y el año se usan para nombrar el resultado. Cada trabajo conserva su propia identificación.';
    }
    foreach($text in @(Get-HdzUiTexts $win.Content)){if($copy.ContainsKey($text.Text)){$text.Text=$copy[$text.Text]}}
    $ui.swAplicarTodos.Visibility='Collapsed';$ui.swAplicarTodos.IsChecked=$true;$ui.swProyecto.IsChecked=$true
    $ui.btnIniciarTodos.Content='▶▶  Procesar todos los pendientes';$ui.btnSubir.Content='☁  Subir al tracker'
    $ui.upAnon.Content='Publicación anónima';$ui.upPersonal.Content='Release propia'
    $ui.btnReset.ToolTip='Vacía la sesión y detiene las tareas tras confirmar. No borra vídeos, ajustes, credenciales ni el historial guardado.'
    $ui.lblEstado.TextWrapping='NoWrap';$ui.lblEstado.TextTrimming='CharacterEllipsis';$ui.lblEstado.MaxWidth=360
    $stateHost=[Windows.Controls.DockPanel]::new();$stateHost.VerticalAlignment='Center';$stateHost.LastChildFill=$true
    $stateParent=[Windows.LogicalTreeHelper]::GetParent($ui.lblEstado)
    [void]$stateParent.Children.Remove($ui.lblEstado);[Windows.Controls.Grid]::SetColumn($stateHost,1)
    $detailsButton=[Windows.Controls.Button]::new();$detailsButton.Content='Ver detalles';$detailsButton.Style=$win.Resources['GhostMini'];$detailsButton.Margin='8,0,8,0'
    $detailsButton.Add_Click({if($ui.lblEstado.Text){[void](Show-DialogoHDZ -Owner $win -Titulo 'Detalles del estado' -Mensaje $ui.lblEstado.Text -BotonSi 'Cerrar' -BotonNo '')}})
    [Windows.Controls.DockPanel]::SetDock($detailsButton,'Right');[void]$stateHost.Children.Add($detailsButton);[void]$stateHost.Children.Add($ui.lblEstado);[void]$stateParent.Children.Add($stateHost)
    $ui.lblEstado.ToolTip='Ver detalles del estado'
    $ui.lblEstado.Cursor='Hand'
    $ui.lblEstado.Add_MouseLeftButtonUp({ if($ui.lblEstado.Text){[void](Show-DialogoHDZ -Owner $win -Titulo 'Detalles del estado' -Mensaje $ui.lblEstado.Text -BotonSi 'Cerrar' -BotonNo '')} })
    $ui.lblEstado.Add_KeyDown({param($sender,$e) if($e.Key -in @('Enter','Space')){[void](Show-DialogoHDZ -Owner $win -Titulo 'Detalles del estado' -Mensaje $ui.lblEstado.Text -BotonSi 'Cerrar' -BotonNo '')}})
    $ui.lblEstado.Focusable=$true
    foreach($name in @('secHdrGeneral','secHdrProyecto','secHdrAudio','secHdrSubs')) {
        $header=$ui[$name];$header.Focusable=$true
        $header.Add_KeyDown({param($sender,$e) if($e.Key -in @('Enter','Space')){$mouse=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left);$mouse.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent;$sender.RaiseEvent($mouse);$e.Handled=$true}})
    }
}
