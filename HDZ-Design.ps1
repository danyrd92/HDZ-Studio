# Visual design only; keep all existing media/torrent handlers and values.
$script:hdzIcons=@{
 entrada=@('M2,9 Q2,7 4,7 L20,7 Q22,7 22,9 L20,20 L4,20 Z','M3,6 L3,4 L9,4 L12,7 L3,7 Z')
 proyecto=@('M3,8 L21,8 L21,19 Q21,21 19,21 L5,21 Q3,21 3,19 Z M9,11 L9,18 L16,14.5 Z','M3,3 L8,3 L5,7 L3,7 Z M10,3 L15,3 L12,7 L7,7 Z M17,3 L21,3 L21,7 L14,7 Z M9,11 L16,14.5 L9,18 Z')
 audio=@('M3,9 Q4.5,9 4.5,10.5 L4.5,13.5 Q4.5,15 3,15 Q1.5,15 1.5,13.5 L1.5,10.5 Q1.5,9 3,9 Z M12,3 Q13.5,3 13.5,4.5 L13.5,19.5 Q13.5,21 12,21 Q10.5,21 10.5,19.5 L10.5,4.5 Q10.5,3 12,3 Z M21,9 Q22.5,9 22.5,10.5 L22.5,13.5 Q22.5,15 21,15 Q19.5,15 19.5,13.5 L19.5,10.5 Q19.5,9 21,9 Z','M7.5,6 Q9,6 9,7.5 L9,16.5 Q9,18 7.5,18 Q6,18 6,16.5 L6,7.5 Q6,6 7.5,6 Z M16.5,6 Q18,6 18,7.5 L18,16.5 Q18,18 16.5,18 Q15,18 15,16.5 L15,7.5 Q15,6 16.5,6 Z')
 subs=@('M4,4 L20,4 Q22,4 22,6 L22,18 Q22,20 20,20 L4,20 Q2,20 2,18 L2,6 Q2,4 4,4 Z M4,7 L4,17 L20,17 L20,7 Z','M11,8 L11,10 L7,10 L7,14 L11,14 L11,16 L5,16 L5,8 Z M19,8 L19,10 L15,10 L15,14 L19,14 L19,16 L13,16 L13,8 Z')
 salida=@('M3,12 L6,12 L6,17 L18,17 L18,12 L21,12 L21,20 Q21,22 19,22 L5,22 Q3,22 3,20 Z','M10.5,2 L13.5,2 L13.5,10 L17,10 L12,15 L7,10 L10.5,10 Z')
 torrent=@('M5,4 L11,10 L9,12 L3,6 Z M13,10 L19,4 L21,6 L15,12 Z M10.5,14 L13.5,14 L13.5,20 L10.5,20 Z M7,5 A3,3 0 1 1 1,5 A3,3 0 1 1 7,5 Z M23,5 A3,3 0 1 1 17,5 A3,3 0 1 1 23,5 Z M15,20 A3,3 0 1 1 9,20 A3,3 0 1 1 15,20 Z','M16,12 A4,4 0 1 1 8,12 A4,4 0 1 1 16,12 Z')
 ajustes=@('M2,5 L22,5 L22,7 L2,7 Z M2,11 L22,11 L22,13 L2,13 Z M2,17 L22,17 L22,19 L2,19 Z','M10,6 A3,3 0 1 1 4,6 A3,3 0 1 1 10,6 Z M20,12 A3,3 0 1 1 14,12 A3,3 0 1 1 20,12 Z M13,18 A3,3 0 1 1 7,18 A3,3 0 1 1 13,18 Z')
 recursos=@('M4,3 L20,3 Q22,3 22,5 L22,19 Q22,21 20,21 L4,21 Q2,21 2,19 L2,5 Q2,3 4,3 Z M5,6 L5,18 L19,18 L19,6 Z','M5,17 L9,11 L13,15 L16,12 L19,17 Z M18,9 A2,2 0 1 1 14,9 A2,2 0 1 1 18,9 Z')
 info=@('M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 Z M19,12 A7,7 0 1 1 5,12 A7,7 0 1 1 19,12 Z','M10.5,10 L13.5,10 L13.5,18 L10.5,18 Z M13.5,7 A1.5,1.5 0 1 1 10.5,7 A1.5,1.5 0 1 1 13.5,7 Z')
}
function New-HdzOutlineIcon($key) {
 if(-not $script:hdzIcons.ContainsKey($key)){$key='info'}
 $canvas=[Windows.Controls.Canvas]::new();$canvas.Width=24;$canvas.Height=24
 $main=[Windows.Shapes.Path]::new();$main.Data=[Windows.Media.Geometry]::Parse($script:hdzIcons[$key][0]);$main.Fill=$win.Resources['TextBrush'];$main.Opacity=0.9
 $accent=[Windows.Shapes.Path]::new();$accent.Data=[Windows.Media.Geometry]::Parse($script:hdzIcons[$key][1]);$accent.Fill=$win.Resources['AccentHoverBrush']
 [void]$canvas.Children.Add($main);[void]$canvas.Children.Add($accent)
 $icon=[Windows.Controls.Viewbox]::new();$icon.Width=22;$icon.Height=22;$icon.Child=$canvas;$icon.VerticalAlignment='Center';$icon.HorizontalAlignment='Left';$icon.Tag=$main;return $icon
}
function New-HdzSectionHeader($title,$icon,$summary,$chevron) {
 $grid=[Windows.Controls.Grid]::new();$grid.MinHeight=44
 foreach($width in @('40','*','Auto','28')){$c=[Windows.Controls.ColumnDefinition]::new();$c.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$grid.ColumnDefinitions.Add($c)}
 [void]$grid.Children.Add((New-HdzOutlineIcon $icon))
 $title.FontSize=15;$title.FontWeight='SemiBold';$title.Foreground=$win.Resources['TextBrush'];$title.VerticalAlignment='Center';$title.TextTrimming='CharacterEllipsis';[Windows.Controls.Grid]::SetColumn($title,1);[void]$grid.Children.Add($title)
 if($summary){$summary.FontSize=12;$summary.MaxWidth=260;$summary.Margin='16,0,16,0';$summary.Foreground=$win.Resources['SubBrush'];$summary.VerticalAlignment='Center';$summary.TextTrimming='CharacterEllipsis';[Windows.Controls.Grid]::SetColumn($summary,2);[void]$grid.Children.Add($summary)}
 $chevron.FontSize=20;$chevron.FontWeight='Normal';$chevron.Foreground=$win.Resources['SubBrush'];$chevron.VerticalAlignment='Center';$chevron.HorizontalAlignment='Center';$chevron.Margin='0';[Windows.Controls.Grid]::SetColumn($chevron,3);[void]$grid.Children.Add($chevron)
 return $grid
}
function Set-HdzNavigationDesign {
 foreach($entry in @(@('navProyecto','proyecto','Proyecto'),@('navSubida','torrent','Torrent y subida'),@('navAjustes','ajustes','Ajustes'))) {
  $nav=$ui[$entry[0]];$row=[Windows.Controls.StackPanel]::new();$row.Orientation='Horizontal';$row.VerticalAlignment='Center';$icon=New-HdzOutlineIcon $entry[1];$binding=[Windows.Data.Binding]::new('Foreground');$binding.Source=$nav;[void]$icon.Tag.SetBinding([Windows.Shapes.Shape]::FillProperty,$binding);[void]$row.Children.Add($icon)
  if(-not $script:sidebarColapsado){$label=[Windows.Controls.TextBlock]::new();$label.Text=$entry[2];$label.Margin='12,0,0,0';$label.VerticalAlignment='Center';[void]$row.Children.Add($label)}
  $nav.Content=$row;$nav.ToolTip=$entry[2];[Windows.Automation.AutomationProperties]::SetName($nav,$entry[2])
 }
}
function Update-HdzDesignState {
 if(-not $script:hdzDesignReady){return}
 if(@($script:ultimoScan).Count -eq 0){if(-not $script:emptyListCompact){$script:previousListHeight=$ui.gridListado.Height;$ui.gridListado.Height=88;$script:emptyListCompact=$true}}
 elseif($script:emptyListCompact){$ui.gridListado.Height=$script:previousListHeight;$script:emptyListCompact=$false}
 $audio=@($script:chipsIdiomasAudio|Where-Object IsChecked|ForEach-Object {"$($_.Content)"})
 $script:sectionSummaries.audio.Text=if(@($script:ultimoScan).Count){if($audio.Count){$audio -join ', '}else{'Sin pistas de audio seleccionadas'}}else{'Se adapta a los vídeos elegidos'}
 $script:sectionSummaries.subs.Text=if(@($script:ultimoScan).Count){switch(Get-ChipValor 'filtro'){'TODOS'{'Todos los idiomas'}'CAST_ENG'{'Castellano e inglés'}default{'Idiomas personalizados'}}}else{'Se adapta a los vídeos elegidos'}
 $originales=switch(Get-ChipValor 'originales'){'BORRAR'{'Borrar originales'}'INTACTO'{'Originales intactos'}default{'Archivar originales'}}
 $script:designOutputSummary.Text=$originales
 $torrent=switch(Get-ChipValor 'torrent'){'INDIVIDUAL'{'Torrent por archivo'}'PACK'{'Torrent del lote'}'AMBOS'{'Torrents individuales y pack'}default{'Sin torrent'}}
 $script:designDeliverSummary.Text="$torrent · $(Get-ChipValor 'capturasProy') capturas"
 foreach($summary in @($script:sectionSummaries.Values)+@($script:designOutputSummary,$script:designDeliverSummary)){$summary.ToolTip=$summary.Text}
 Update-HdzProductState
}
function Initialize-HdzDesign {
 $resources=@'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
 <Style x:Key="HdzSectionHeader" TargetType="Border">
  <Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="#303038"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="CornerRadius" Value="0"/><Setter Property="Padding" Value="8,0"/><Setter Property="Margin" Value="0,4,0,10"/>
  <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1A1A20"/><Setter Property="BorderBrush" Value="#52525E"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="#EF4444"/><Setter Property="BorderThickness" Value="2"/></Trigger></Style.Triggers>
 </Style>
 <Style x:Key="HdzSection" TargetType="Expander">
  <Setter Property="Margin" Value="0,4,0,10"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Expander"><StackPanel>
   <ToggleButton Content="{TemplateBinding Header}" IsChecked="{Binding IsExpanded,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}" HorizontalContentAlignment="Stretch">
    <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border x:Name="outline" Background="Transparent" BorderBrush="#303038" BorderThickness="0,0,0,1" CornerRadius="0" Padding="8,0"><ContentPresenter HorizontalAlignment="Stretch"/></Border>
     <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="outline" Property="Background" Value="#1A1A20"/><Setter TargetName="outline" Property="BorderBrush" Value="#52525E"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="outline" Property="BorderBrush" Value="#EF4444"/><Setter TargetName="outline" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></ToggleButton.Template>
   </ToggleButton>
   <ContentPresenter x:Name="body" Content="{TemplateBinding Content}" Margin="0,12,0,0" Visibility="Collapsed"/>
  </StackPanel><ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="body" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
 </Style>
 <Style x:Key="HdzKeyboardFocus" TargetType="Control"><Setter Property="Template"><Setter.Value><ControlTemplate><Border BorderBrush="#EF4444" BorderThickness="2" CornerRadius="7" Margin="-3"/></ControlTemplate></Setter.Value></Setter></Style>
</ResourceDictionary>
'@
 $dict=[Windows.Markup.XamlReader]::Parse($resources);$win.Resources.MergedDictionaries.Add($dict);$script:hdzHeaderStyle=$dict['HdzSectionHeader'];$script:hdzExpanderStyle=$dict['HdzSection']
 foreach($entry in @(@('secHdrGeneral','secChevGeneral','general','entrada'),@('secHdrProyecto','secChevProyecto','proyecto','proyecto'),@('secHdrAudio','secChevAudio','audio','audio'),@('secHdrSubs','secChevSubs','subs','subs'))) {
  $header=$ui[$entry[0]];$chevron=$ui[$entry[1]];$summary=$script:sectionSummaries[$entry[2]];$title=@(Get-HdzUiTexts $header | Where-Object {$_ -ne $summary -and $_ -ne $chevron})[0]
  foreach($node in @($title,$chevron,$summary)){$parent=[Windows.LogicalTreeHelper]::GetParent($node);if($parent -is [Windows.Controls.Panel]){[void]$parent.Children.Remove($node)}}
  $title.Text=$title.Text -replace '^[^\p{L}\p{N}]+','';$header.Child=New-HdzSectionHeader $title $entry[3] $summary $chevron;$header.Style=$script:hdzHeaderStyle
  $header.ClearValue([Windows.Controls.Border]::BackgroundProperty);$header.ClearValue([Windows.FrameworkElement]::MarginProperty);$header.ClearValue([Windows.Controls.Border]::PaddingProperty);[Windows.Automation.AutomationProperties]::SetName($header,$title.Text)
 }
 $expanders=@($ui.panCrear.Children|Where-Object {$_ -is [Windows.Controls.Expander]})+@($ui.panSubidaBody.Child.Children|Where-Object {$_ -is [Windows.Controls.Expander]})+@($ui.panAjustes.Children|Where-Object {$_ -is [Windows.Controls.Expander]})
 $script:designedExpanders=@($expanders)
 foreach($section in $expanders){
  $name="$($section.Header)";$title=[Windows.Controls.TextBlock]::new();$title.Text=$name;$key=if($name -like 'Salida*'){'salida'}elseif($name -like 'Torrent*'){'torrent'}elseif($name -like 'Descripción*'){'recursos'}else{'info'}
  $summary=$null
  if($key -in @('salida','torrent')){$summary=[Windows.Controls.TextBlock]::new();if($key -eq 'salida'){$script:designOutputSummary=$summary}else{$script:designDeliverSummary=$summary}}
  $chevron=[Windows.Controls.TextBlock]::new();$chevron.Text=if($section.IsExpanded){'▾'}else{'▸'};$section.Tag=$chevron;$section.Header=New-HdzSectionHeader $title $key $summary $chevron;$section.Style=$script:hdzExpanderStyle;$section.ClearValue([Windows.FrameworkElement]::MarginProperty)
  $section.Add_Expanded({param($sender,$e) if($sender -eq $e.OriginalSource){$sender.Tag.Text='▾'}});$section.Add_Collapsed({param($sender,$e) if($sender -eq $e.OriginalSource){$sender.Tag.Text='▸'}});[Windows.Automation.AutomationProperties]::SetName($section,$name)
 }
 $win.FontFamily='Segoe UI';$win.FontSize=14
 foreach($key in @('SubBrush','MutedBrush')){if(-not $win.Resources[$key].IsFrozen){$win.Resources[$key].Color=[Windows.Media.ColorConverter]::ConvertFromString($(if($key -eq 'SubBrush'){'#B0B0BC'}else{'#9595A3'}))}}
 foreach($text in @(Get-HdzUiTexts $win.Content)){if($text.Style -eq $win.Resources['D']){$text.FontSize=13;$text.LineHeight=19}elseif($text.Style -eq $win.Resources['H']){$text.FontSize=15;$text.FontWeight='SemiBold'}elseif($text.Style -eq $win.Resources['Lbl']){$text.FontSize=13}}
 foreach($control in $ui.Values){if($control -is [Windows.Controls.Control]){$control.FocusVisualStyle=$dict['HdzKeyboardFocus'];if($control -is [Windows.Controls.Button] -or $control -is [Windows.Controls.Primitives.ToggleButton]){$control.MinHeight=36}}}
 $ui.lblVersion.Foreground=$win.Resources['SubBrush'];$ui.lblPie.Foreground=$win.Resources['SubBrush'];$ui.lblPie.FontSize=12;$ui.lblSecMontaje.Text='MONTAJE';$ui.lblSecTorrent.Text='PUBLICACIÓN'
 $ui.btnReset.Content='Empezar de Zero';$ui.btnElegirVideos.Content='Elegir vídeos';$ui.btnExaminar.Content='Elegir carpeta';$ui.btnAnadirTemporada.Content='+ Añadir temporada'
 $ui.lblPie.Text='PGS: el OCR manual requiere Subtitle Edit en el PC.'
 $main=[Windows.LogicalTreeHelper]::GetParent($script:barraEntrada);$main.MaxWidth=[double]::PositiveInfinity;$main.HorizontalAlignment='Stretch'
 foreach($old in @(Get-HdzUiTexts $script:barraEntrada | Where-Object Text -eq '📁')){
  $parent=[Windows.LogicalTreeHelper]::GetParent($old);if($parent -is [Windows.Controls.Grid]){[void]$parent.Children.Remove($old);$folder=New-HdzOutlineIcon 'entrada';[Windows.Controls.Grid]::SetColumn($folder,0);[void]$parent.Children.Add($folder)}
 }
 Set-HdzNavigationDesign;$script:hdzDesignReady=$true;Update-HdzDesignState
 Initialize-HdzProduct
 Initialize-HdzWorkspace
}
function New-HdzProductText($text,$size,$brush) {
 $block=[Windows.Controls.TextBlock]::new();$block.Text=$text;$block.FontSize=$size;$block.Foreground=$win.Resources[$brush];$block.TextWrapping='Wrap';return $block
}
function Initialize-HdzProduct {
 $main=[Windows.LogicalTreeHelper]::GetParent($script:barraEntrada)
 $top=[Windows.Controls.StackPanel]::new();[void]$main.Children.Remove($script:barraEntrada);[Windows.Controls.Grid]::SetRow($top,0)
 $hero=[Windows.Controls.Grid]::new();$hero.Margin='0,0,0,12'
 $left=[Windows.Controls.StackPanel]::new()
 $script:productKicker=New-HdzProductText 'ESPACIO DE TRABAJO' 10.5 'SubBrush';$script:productKicker.FontWeight='SemiBold'
 $script:productTitle=New-HdzProductText 'Proyecto' 20 'TextBrush';$script:productTitle.FontWeight='SemiBold';$script:productTitle.Margin='0,0,0,0'
 $script:productSubtitle=New-HdzProductText '' 13 'SubBrush'
 $script:productKicker.Visibility='Collapsed';$script:productSubtitle.Visibility='Collapsed'
 foreach($child in @($script:productKicker,$script:productTitle,$script:productSubtitle)){[void]$left.Children.Add($child)}
 [void]$hero.Children.Add($left)
 $script:productBadge=New-HdzProductText 'Sin archivos' 12 'SubBrush';$script:productBadge.MaxWidth=180
 $badgeFrame=[Windows.Controls.Border]::new();$badgeFrame.HorizontalAlignment='Right';$badgeFrame.VerticalAlignment='Center';$badgeFrame.Background=$win.Resources['ChipBrush'];$badgeFrame.BorderBrush=$win.Resources['CardBorderBrush'];$badgeFrame.BorderThickness='1';$badgeFrame.CornerRadius='16';$badgeFrame.Padding='12,6';$badgeFrame.Child=$script:productBadge
 $badgeFrame.Visibility='Collapsed'
 [void]$hero.Children.Add($badgeFrame);[void]$top.Children.Add($hero);[void]$top.Children.Add($script:barraEntrada);[void]$main.Children.Add($top)
 $overview=[Windows.Controls.Border]::new();$overview.Background=$win.Resources['CardBrush'];$overview.BorderBrush=$win.Resources['CardBorderBrush'];$overview.BorderThickness='1';$overview.CornerRadius='12';$overview.Margin='0,0,0,12';$overview.Padding='16,12'
 $columns=[Windows.Controls.Primitives.UniformGrid]::new();$columns.Columns=3;$script:productMetrics=@()
 foreach($caption in @('ENTRADA','TRABAJO','DESTINO')){
  $column=[Windows.Controls.StackPanel]::new();$column.Margin='0,0,16,0';$label=New-HdzProductText $caption 10.5 'SubBrush';$value=New-HdzProductText '' 14 'TextBrush';$value.FontWeight='SemiBold';$value.TextWrapping='NoWrap';$value.TextTrimming='CharacterEllipsis';$value.Margin='0,4,0,0';[void]$column.Children.Add($label);[void]$column.Children.Add($value);[void]$columns.Children.Add($column);$script:productMetrics+=,$value
 }
 $overview.Child=$columns;$overview.Visibility='Collapsed';$ui.panCrear.Children.Insert(0,$overview)
 $jumps=[Windows.Controls.WrapPanel]::new();$jumps.Margin='0,0,0,16'
 foreach($entry in @(@('Tracker','cfgTrackerUrl'),@('TMDB','cfgTmdbKey'),@('Imágenes','cfgImgbbKey'),@('Carpetas','cfgCarpetaTorrent'),@('Soporte','cfgUsuarioSoporte'))){
  $button=[Windows.Controls.Button]::new();$button.Style=$win.Resources['GhostMini'];$button.Content=$entry[0];$button.Margin='0,0,8,6';$button.Tag=Get-HdzCard $ui[$entry[1]];$button.Add_Click({param($sender) if($sender.Tag){$sender.Tag.BringIntoView()}});[void]$jumps.Children.Add($button)
 }
 $ui.panAjustes.Children.Insert(0,$jumps)
 $script:productReady=$true;Update-HdzProductState
}
function Update-HdzProductState {
 if(-not $script:productReady){return}
 $project=$ui.panCrear.Visibility -eq 'Visible';$upload=$ui.panSubida.Visibility -eq 'Visible'
 $ui.btnConsola.Visibility=if($project -and $ui.btnConsola.IsEnabled){'Visible'}else{'Collapsed'}
 $script:productTitle.Text=if($project){'Proyecto'}elseif($upload){'Torrent y subida'}else{'Ajustes'}
 $script:productKicker.Text=if($project){'ESPACIO DE TRABAJO'}elseif($upload){'PUBLICACIÓN'}else{'CONFIGURACIÓN'}
 $script:productSubtitle.Text=if($project){'Prepara tus fuentes, revisa las pistas y define el resultado.'}elseif($upload){'Revisa la ficha, la descripción y los recursos antes de publicar.'}else{'Gestiona tus conexiones, preferencias y carpetas predeterminadas.'}
 $count=@($script:ultimoScan).Count;$sources=if($ui.swRemezcla.IsChecked -and $script:remixScanCrudo){@($script:remixScanCrudo).Count}else{$count}
 $script:productBadge.Text=if($script:networkBusy){'Petición en curso'}elseif($project){if($count){"$count archivo(s) analizados"}else{'Sin archivos analizados'}}elseif($upload){if($ui.txtTorrentSubir.Text){'Torrent cargado'}else{'Sin torrent cargado'}}else{'Preferencias conservadas'}
 $script:productMetrics[0].Text=if($sources){"$sources archivo(s) fuente"}else{'Selecciona tus vídeos'}
 $script:productMetrics[1].Text=if($ui.txtTitulo.Text){$ui.txtTitulo.Text}else{'Identificación pendiente'}
 $script:productMetrics[2].Text=if($ui.txtSalidaArchivo.Text){$ui.txtSalidaArchivo.Text}else{'Carpeta de origen'}
 foreach($value in $script:productMetrics){$value.ToolTip=$value.Text}
 if(-not $count){foreach($text in @(Get-HdzUiTexts $ui.panListado)){if($text.Text -like 'No hay vídeos*'){$text.Text='Todavía no hay vídeos en el análisis. Elige una carpeta o archivos concretos para comenzar.';$text.FontSize=14;$text.TextWrapping='Wrap';$text.Margin='0,10,0,0'}}}
 if($script:workspaceReady){
  foreach($key in @('audio','subs')){
   $panel=if($key -eq 'audio'){$ui.panAudio}else{$ui.panSubs};$wrap=$panel.Children[0];$available=@($wrap.Children|Where-Object Visibility -eq 'Visible').Count -gt 0
   $script:workspaceEmpty[$key].Visibility=if($available){'Collapsed'}else{'Visible'}
  }
  $script:workspaceNav.Visibility=if($project){'Visible'}else{'Collapsed'}
  $script:workspaceHeading.Visibility=if($project){'Visible'}else{'Collapsed'}
  $script:barraEntrada.Visibility=if($project -and $script:workspaceStage -eq 'general'){'Visible'}else{'Collapsed'}
 }
}

# A task-oriented workspace: one inspector at a time, with the same authoritative controls.
function Set-HdzWorkspaceStage($name) {
 if($name -eq 'salida'){$name='entrega'}
 if($name -eq 'subs'){$name='audio'}
 if(-not $script:workspaceStages.Contains($name)){return}
 $script:workspaceStage=$name
 foreach($key in $script:workspaceStages.Keys){
  $stage=$script:workspaceStages[$key];$active=$key -eq $name
  $stage.body.Visibility=if($active){'Visible'}else{'Collapsed'}
  if($stage.body -is [Windows.Controls.Expander]){$stage.body.IsExpanded=$active}
  $stage.button.Background=if($active){$win.Resources['AccentSoftBrush']}else{[Windows.Media.Brushes]::Transparent}
  $stage.button.BorderBrush=if($active){$win.Resources['AccentHoverBrush']}else{[Windows.Media.Brushes]::Transparent}
  $stage.button.Foreground=if($active){$win.Resources['TextBrush']}else{$win.Resources['SubBrush']}
 }
 $script:workspaceHeadingTitle.Text=$script:workspaceStages[$name].title
 $script:workspaceHeadingNote.Text=$script:workspaceStages[$name].note
 Update-HdzProductState
 if($script:workspaceScroll){$script:workspaceScroll.ScrollToTop()}
}
function New-HdzWorkspaceColumns($owner,$wideCards=@()) {
 $wrap=[Windows.Controls.WrapPanel]::new();$wrap.HorizontalAlignment='Stretch'
 $wrap.Tag=@{Width=-1;WideCards=(@($wideCards)+@((Get-HdzCard $ui.panListado),(Get-HdzCard $ui.panRemezcla),$ui.cardAudioTracks,$ui.cardConvAudio,$ui.cardUndAudio,$ui.cardUndSub))}
 $children=@($owner.Children);$owner.Children.Clear()
 foreach($child in $children){$child.VerticalAlignment='Top';[void]$wrap.Children.Add($child)}
 [void]$owner.Children.Add($wrap)
 $wrap.Add_SizeChanged({param($sender,$eventArgs)
  if(-not $eventArgs.WidthChanged){return}
  $available=$sender.ActualWidth;if($available -le 0){return}
  if([Math]::Abs($sender.Tag.Width-$available) -lt .5){return};$sender.Tag.Width=$available
  $columns=if($available -ge 1050){2}else{1};$half=[Math]::Floor(($available-20)/2)
  $index=0
  foreach($child in $sender.Children){
   $wide=$columns -eq 1 -or $child -isnot [Windows.Controls.Border] -or $sender.Tag.WideCards -contains $child
   $width=if($wide){$available}else{$half};if($child.Width -ne $width){$child.Width=$width}
   $margin=if(-not $wide -and $index%2 -eq 0){[Windows.Thickness]::new(0,0,16,16)}else{[Windows.Thickness]::new(0,0,0,16)}
   if($child.Margin -ne $margin){$child.Margin=$margin}
   if($wide){$index=0}else{$index++}
  }
 })
 return $wrap
}
function Initialize-HdzWorkspace {
 $stageStyle=[Windows.Markup.XamlReader]::Parse(@'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
 <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Name="frame" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="#EF4444"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="#EF4444"/><Setter TargetName="frame" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
</Style>
'@)
 foreach($pair in @(@('BgBrush','#101318'),@('SidebarBrush','#0B0E12'),@('CardBrush','#181D24'),@('CardBorderBrush','#303844'),@('FieldBrush','#11161D'),@('FieldBorderBrush','#36404D'),@('ChipBrush','#222A34'),@('ChipBorderBrush','#36404D'),@('SubBrush','#ABB7C6'),@('MutedBrush','#8491A2'),@('AccentSoftBrush','#322029'))){
  $brush=$win.Resources[$pair[0]];if($brush -and -not $brush.IsFrozen){$brush.Color=[Windows.Media.ColorConverter]::ConvertFromString($pair[1])}
 }
 foreach($key in @('CardBgGrad','CardBorderGrad')){foreach($stop in $win.Resources[$key].GradientStops){if(-not $stop.IsFrozen){$stop.Color=[Windows.Media.ColorConverter]::ConvertFromString($(if($key -eq 'CardBgGrad'){'#181D24'}else{'#303844'}))}}}
 function Style-HdzWorkspaceCards($node){
  if($node -is [Windows.Controls.Border] -and $node.Style -eq $win.Resources['Card']){$node.CornerRadius='12';$node.Padding='20,18';$node.Background=$win.Resources['CardBrush'];$node.BorderBrush=$win.Resources['CardBorderBrush']}
  foreach($child in [Windows.LogicalTreeHelper]::GetChildren($node)){if($child -is [Windows.DependencyObject]){Style-HdzWorkspaceCards $child}}
 }
 Style-HdzWorkspaceCards $win.Content
 $script:productTitle.FontSize=26;$script:productTitle.FontWeight='SemiBold';$script:productTitle.Margin='0,0,0,8'
 $ui.lblSecMontaje.Text='ESPACIO DE TRABAJO';$ui.lblSecTorrent.Text='PUBLICACIÓN';$ui.lblSecMontaje.Foreground=$win.Resources['SubBrush'];$ui.lblSecTorrent.Foreground=$win.Resources['SubBrush']
 $top=[Windows.LogicalTreeHelper]::GetParent($script:barraEntrada)
 $script:workspaceNav=[Windows.Controls.WrapPanel]::new();$script:workspaceNav.Margin='0'
 $script:workspaceStages=[ordered]@{}
 $output=@($script:designedExpanders|Where-Object { [Windows.Automation.AutomationProperties]::GetName($_) -eq 'Salida y originales' })[0]
 $delivery=@($script:designedExpanders|Where-Object { [Windows.Automation.AutomationProperties]::GetName($_) -eq 'Torrent y capturas del montaje' })[0]
 foreach($entry in @(
  @('general','Fuentes','entrada',$ui.panGeneral,'Fuentes',''),
  @('proyecto','Identidad','proyecto',$ui.panProyecto,'Identificación y origen',''),
  @('audio','Audio y subtítulos','audio',$ui.panAudio,'Audio y subtítulos',''),
  @('entrega','Entrega y salida','torrent',$delivery,'Entrega y salida','')
 )){
  $button=[Windows.Controls.Button]::new();$button.Style=$stageStyle;$button.Padding='14,10';$button.Margin='0,0,8,6';$button.MinHeight=46;$button.Tag=$entry[0]
  $row=[Windows.Controls.StackPanel]::new();$row.Orientation='Horizontal';[void]$row.Children.Add((New-HdzOutlineIcon $entry[2]));$label=New-HdzProductText $entry[1] 14 'TextBrush';$label.Margin='9,0,0,0';$label.VerticalAlignment='Center';[void]$row.Children.Add($label);$button.Content=$row
  $button.Add_Click({param($sender) Set-HdzWorkspaceStage $sender.Tag});[Windows.Automation.AutomationProperties]::SetName($button,$entry[1]);[void]$script:workspaceNav.Children.Add($button)
  $script:workspaceStages[$entry[0]]=@{body=$entry[3];button=$button;title=$entry[4];note=$entry[5]}
 }
 $navFrame=[Windows.Controls.Border]::new();$navFrame.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#141920');$navFrame.BorderBrush=$win.Resources['CardBorderBrush'];$navFrame.BorderThickness='1';$navFrame.CornerRadius='12';$navFrame.Padding='6';$navFrame.Margin='0,0,0,20';$navFrame.Child=$script:workspaceNav
 $visibility=[Windows.Data.Binding]::new('Visibility');$visibility.Source=$script:workspaceNav;[void]$navFrame.SetBinding([Windows.UIElement]::VisibilityProperty,$visibility)
 $script:workspaceNav.Add_SizeChanged({param($sender,$eventArgs) if(-not $eventArgs.WidthChanged){return};if($sender.ActualWidth -ge 750){foreach($button in $sender.Children){$button.Width=[Math]::Floor(($sender.ActualWidth-($sender.Children.Count*10))/$sender.Children.Count)}}else{foreach($button in $sender.Children){$button.Width=[double]::NaN}}})
 $top.Children.Insert(1,$navFrame)
 $script:workspaceHeading=[Windows.Controls.StackPanel]::new();$script:workspaceHeading.Margin='0,0,0,18'
 $script:workspaceHeadingTitle=New-HdzProductText '' 20 'TextBrush';$script:workspaceHeadingTitle.FontWeight='SemiBold';$script:workspaceHeadingNote=New-HdzProductText '' 13 'SubBrush';$script:workspaceHeadingNote.Visibility='Collapsed'
 [void]$script:workspaceHeading.Children.Add($script:workspaceHeadingTitle);[void]$script:workspaceHeading.Children.Add($script:workspaceHeadingNote);$top.Children.Insert(2,$script:workspaceHeading)
 foreach($name in @('secHdrGeneral','secHdrProyecto','secHdrAudio','secHdrSubs')){$ui[$name].Visibility='Collapsed'}
 # Output/delivery become plain inspector bodies, not nested accordion controls.
 $deliveryHeading=New-HdzProductText 'Entrega' 17 'TextBrush';$deliveryHeading.FontWeight='SemiBold';$deliveryHeading.Margin='0,0,0,12';$delivery.Content.Children.Insert(0,$deliveryHeading)
 $outputHeading=New-HdzProductText 'Salida y originales' 17 'TextBrush';$outputHeading.FontWeight='SemiBold';$outputHeading.Margin='0,10,0,12';[void]$delivery.Content.Children.Add($outputHeading)
 foreach($child in @($output.Content.Children)){[void]$output.Content.Children.Remove($child);[void]$delivery.Content.Children.Add($child)}
 foreach($section in @($output,$delivery)){
  $body=$section.Content;$section.Content=$null;$position=$ui.panCrear.Children.IndexOf($section);[void]$ui.panCrear.Children.Remove($section)
  if($section -eq $delivery){$ui.panCrear.Children.Insert($position,$body);$script:workspaceStages.entrega.body=$body}
 }
 $tracks=[Windows.Controls.StackPanel]::new();$position=$ui.panCrear.Children.IndexOf($ui.panAudio);[void]$ui.panCrear.Children.Remove($ui.panAudio);[void]$ui.panCrear.Children.Remove($ui.panSubs);$ui.panCrear.Children.Insert($position,$tracks)
 foreach($entry in @(@('Audio',$ui.panAudio),@('Subtítulos',$ui.panSubs))){$label=New-HdzProductText $entry[0] 17 'TextBrush';$label.FontWeight='SemiBold';$label.Margin='0,8,0,12';[void]$tracks.Children.Add($label);$entry[1].Visibility='Visible';[void]$tracks.Children.Add($entry[1]);[void](New-HdzWorkspaceColumns $entry[1])}
 $script:workspaceStages.audio.body=$tracks
 foreach($stage in $script:workspaceStages.Values){[void](New-HdzWorkspaceColumns $stage.body)}
 # The publishing desk and preferences use the same responsive card grid.
 [void](New-HdzWorkspaceColumns $ui.panSubidaBody.Child @($ui.panSubidaBody.Child.Children))
 $settings=[Windows.Controls.StackPanel]::new();foreach($child in @($ui.panAjustes.Children|Select-Object -Skip 1)){[void]$ui.panAjustes.Children.Remove($child);[void]$settings.Children.Add($child)};[void](New-HdzWorkspaceColumns $settings);[void]$ui.panAjustes.Children.Add($settings)
 $script:workspaceEmpty=@{}
 foreach($key in @('audio','subs')){
  $card=[Windows.Controls.Border]::new();$card.Style=$win.Resources['Card'];$card.Background=$win.Resources['CardBrush'];$card.BorderBrush=$win.Resources['CardBorderBrush'];$card.CornerRadius='12';$card.Padding='22'
  $text=New-HdzProductText 'Las opciones aparecerán cuando analices vídeos con estas pistas. Vuelve a Fuentes para elegir los archivos.' 14 'SubBrush';$card.Child=$text;$script:workspaceEmpty[$key]=$card;$panel=if($key -eq 'audio'){$ui.panAudio}else{$ui.panSubs};[void]$panel.Children.Add($card)
 }
 $script:workspaceScroll=[Windows.LogicalTreeHelper]::GetParent([Windows.LogicalTreeHelper]::GetParent($ui.panCrear))
 $script:workspaceReady=$true;Set-HdzWorkspaceStage 'general'
}
