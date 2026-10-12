# Visual design only; keep all existing media/torrent handlers and values.
$script:hdzIcons=@{
 entrada='M2,7 L9,7 L11,10 L22,10 L22,21 L2,21 Z M2,7 L2,4 L9,4 L11,7 L22,7 L22,10'
 proyecto='M4,3 L20,3 L20,21 L4,21 Z M4,8 L20,8 M8,3 L8,8 M14,3 L14,8 M9,12 L16,12 M9,16 L16,16'
 audio='M3,9 L7,9 L12,5 L12,19 L7,15 L3,15 Z M16,8 Q21,12 16,16 M18,4 Q27,12 18,20'
 subs='M3,4 L21,4 L21,17 L9,17 L4,21 L4,17 L3,17 Z M7,9 L11,9 M14,9 L17,9 M7,13 L17,13'
 salida='M4,4 L4,20 L20,20 L20,4 M12,2 L12,14 M7,9 L12,14 L17,9'
 torrent='M4,4 L15,4 L20,9 L20,20 L4,20 Z M15,4 L15,9 L20,9 M12,11 L12,17 M9,14 L12,17 L15,14'
 ajustes='M12,2 L15,5 L19,5 L19,9 L22,12 L19,15 L19,19 L15,19 L12,22 L9,19 L5,19 L5,15 L2,12 L5,9 L5,5 L9,5 Z M16,12 A4,4 0 1 1 8,12 A4,4 0 1 1 16,12'
 recursos='M3,5 L21,5 L21,20 L3,20 Z M3,16 L8,11 L13,16 L17,12 L21,16 M17,9 A1,1 0 1 1 15,9 A1,1 0 1 1 17,9'
 info='M22,12 A10,10 0 1 1 2,12 A10,10 0 1 1 22,12 M12,11 L12,17 M12,7 L12,8'
}
function New-HdzOutlineIcon($key) {
 if(-not $script:hdzIcons.ContainsKey($key)){$key='info'}
 $p=[Windows.Shapes.Path]::new();$p.Data=[Windows.Media.Geometry]::Parse($script:hdzIcons[$key]);$p.Width=18;$p.Height=18;$p.Stretch='Uniform';$p.Stroke=$win.Resources['SubBrush'];$p.StrokeThickness=1.7;$p.StrokeStartLineCap='Round';$p.StrokeEndLineCap='Round';$p.StrokeLineJoin='Round';$p.VerticalAlignment='Center';return $p
}
function New-HdzSectionHeader($title,$icon,$summary,$chevron) {
 $grid=[Windows.Controls.Grid]::new();$grid.MinHeight=54
 foreach($width in @('40','*','Auto','28')){$c=[Windows.Controls.ColumnDefinition]::new();$c.Width=[Windows.GridLengthConverter]::new().ConvertFromString($width);[void]$grid.ColumnDefinitions.Add($c)}
 [void]$grid.Children.Add((New-HdzOutlineIcon $icon))
 $title.FontSize=15;$title.FontWeight='SemiBold';$title.Foreground=$win.Resources['TextBrush'];$title.VerticalAlignment='Center';$title.TextTrimming='CharacterEllipsis';[Windows.Controls.Grid]::SetColumn($title,1);[void]$grid.Children.Add($title)
 if($summary){$summary.FontSize=12;$summary.MaxWidth=260;$summary.Margin='16,0,16,0';$summary.Foreground=$win.Resources['SubBrush'];$summary.VerticalAlignment='Center';$summary.TextTrimming='CharacterEllipsis';[Windows.Controls.Grid]::SetColumn($summary,2);[void]$grid.Children.Add($summary)}
 $chevron.FontSize=20;$chevron.FontWeight='Normal';$chevron.Foreground=$win.Resources['SubBrush'];$chevron.VerticalAlignment='Center';$chevron.HorizontalAlignment='Center';$chevron.Margin='0';[Windows.Controls.Grid]::SetColumn($chevron,3);[void]$grid.Children.Add($chevron)
 return $grid
}
function Set-HdzNavigationDesign {
 foreach($entry in @(@('navProyecto','proyecto','Proyecto'),@('navSubida','torrent','Torrent y subida'),@('navAjustes','ajustes','Ajustes'))) {
  $nav=$ui[$entry[0]];$row=[Windows.Controls.StackPanel]::new();$row.Orientation='Horizontal';$row.VerticalAlignment='Center';$icon=New-HdzOutlineIcon $entry[1];$binding=[Windows.Data.Binding]::new('Foreground');$binding.Source=$nav;[void]$icon.SetBinding([Windows.Shapes.Shape]::StrokeProperty,$binding);[void]$row.Children.Add($icon)
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
}
function Initialize-HdzDesign {
 $resources=@'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
 <Style x:Key="HdzSectionHeader" TargetType="Border">
  <Setter Property="Background" Value="#131316"/><Setter Property="BorderBrush" Value="#303038"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="10"/><Setter Property="Padding" Value="14,0"/><Setter Property="Margin" Value="0,6,0,12"/>
  <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1A1A20"/><Setter Property="BorderBrush" Value="#52525E"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="BorderBrush" Value="#EF4444"/><Setter Property="BorderThickness" Value="2"/></Trigger></Style.Triggers>
 </Style>
 <Style x:Key="HdzSection" TargetType="Expander">
  <Setter Property="Margin" Value="0,6,0,12"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Expander"><StackPanel>
   <ToggleButton Content="{TemplateBinding Header}" IsChecked="{Binding IsExpanded,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}" HorizontalContentAlignment="Stretch">
    <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border x:Name="outline" Background="#131316" BorderBrush="#303038" BorderThickness="1" CornerRadius="10" Padding="14,0"><ContentPresenter HorizontalAlignment="Stretch"/></Border>
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
 $main=[Windows.LogicalTreeHelper]::GetParent($script:barraEntrada);$main.MaxWidth=1320;$main.HorizontalAlignment='Stretch'
 Set-HdzNavigationDesign;$script:hdzDesignReady=$true;Update-HdzDesignState
}
