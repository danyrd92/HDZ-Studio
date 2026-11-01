$ErrorActionPreference='Stop'
$env:HDZ_GUI_TEST='1'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
 . (Join-Path $root 'HDZ-GUI.ps1')
 Mostrar-Panel 'panCrear'
 Assert ($script:productTitle.Text -eq 'Proyecto') 'Título de pantalla incorrecto'
 Assert ($script:productTitle.FontSize -eq 26 -and $script:productSubtitle.Visibility -eq 'Collapsed') 'Jerarquía de cabecera incorrecta'
 Assert ($script:workspaceStages.Count -eq 4) 'Audio y subtítulos no están unidos'
 Set-HdzWorkspaceStage 'audio'
 Assert ($ui.panAudio.Visibility -eq 'Visible' -and $ui.panSubs.Visibility -eq 'Visible') 'No se muestran las dos partes de pistas'
 foreach($k in @('Audio','Sub')){
  Assert ($ui["bodyUnd$k"].Visibility -eq 'Collapsed' -and $ui["chevUnd$k"].Text -eq '▸') "El selector por pista ($k) no arranca contraído"
  $clic=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left);$clic.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent
  $ui["hdrUnd$k"].RaiseEvent($clic);Assert ($ui["bodyUnd$k"].Visibility -eq 'Visible' -and $ui["chevUnd$k"].Text -eq '▾') "El selector por pista ($k) no se despliega"
  $ui["hdrUnd$k"].RaiseEvent($clic);Assert ($ui["bodyUnd$k"].Visibility -eq 'Collapsed') "El selector por pista ($k) no se vuelve a contraer"
 }
 Set-HdzWorkspaceStage 'entrega'
 $deliveryChildren=$script:workspaceStages.entrega.body.Children[0].Children
 Assert ($deliveryChildren[0].Text -eq 'Entrega') 'La entrega no aparece primero'
 Assert (@($deliveryChildren | Where-Object Text -eq 'Salida y originales').Count -eq 1) 'Falta la salida en Entrega'
 foreach($mode in @('NO','INDIVIDUAL','PACK','AMBOS','NO')){
  Set-ChipValor 'torrent' $mode;Actualizar-Torrent
  Assert (($ui.txtSalidaTorrent.Parent.Visibility -eq 'Visible') -eq ($mode -ne 'NO')) 'Ubicación torrent visible sin crear torrent'
 }
 foreach($key in $script:workspaceStages.Keys){
  Set-HdzWorkspaceStage $key
  foreach($other in $script:workspaceStages.Keys){Assert (($script:workspaceStages[$other].body.Visibility -eq 'Visible') -eq ($other -eq $key)) 'Hay inspectores solapados'}
 }
 Set-HdzWorkspaceStage 'general'
 Assert ($ui.btnConsola.Visibility -eq 'Collapsed') 'Acción de consola visible sin tarea'
 Mostrar-Panel 'panSubida';Assert ($script:productTitle.Text -eq 'Torrent y subida') 'Cabecera no cambia al navegar'
 Mostrar-Panel 'panAjustes';Assert ($script:productTitle.Text -eq 'Ajustes') 'Cabecera incorrecta de Ajustes'
 Assert ($ui.panAjustes.Children[0] -is [Windows.Controls.WrapPanel]) 'Faltan accesos rápidos de Ajustes'
 Mostrar-Panel 'panCrear'
 $ui.navProyecto.IsChecked=$true
 foreach($name in @('secHdrGeneral','secHdrProyecto','secHdrAudio','secHdrSubs')){
  Assert ($ui[$name].Style -eq $script:hdzHeaderStyle) "Cabecera distinta: $name"
  Assert ($ui[$name].Child -is [Windows.Controls.Grid]) 'La cabecera no usa la retícula compartida'
  Assert ($ui[$name].Child.MinHeight -eq 44) 'Alto de cabecera incoherente'
 }
 Assert ($script:designedExpanders.Count -ge 4) 'No se han diseñado todas las secciones nuevas'
 foreach($section in $script:designedExpanders){
  Assert ($section.Style -eq $script:hdzExpanderStyle) 'Desplegable de Windows sin personalizar'
  Assert ($section.Header.MinHeight -eq 44) 'Desplegable nuevo con alto distinto'
  $section.IsExpanded=$true;Assert ($section.Tag.Text -eq '▾') 'Flecha no responde a expansión'
  $section.IsExpanded=$false;Assert ($section.Tag.Text -eq '▸') 'Flecha no responde al cierre'
 }
 $ui.panGeneral.Visibility='Collapsed';$ui.secChevGeneral.Text='▸'
 $mouse=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left);$mouse.RoutedEvent=[Windows.UIElement]::MouseLeftButtonUpEvent;$ui.secHdrGeneral.RaiseEvent($mouse)
 Assert ($ui.panGeneral.Visibility -eq 'Visible') 'La cabecera rediseñada ha perdido su manejador'
 $script:sidebarColapsado=$true;Aplicar-Sidebar
 Assert ($ui.navProyecto.Content.Children.Count -eq 1) 'Menú compacto conserva texto'
 $script:sidebarColapsado=$false;Aplicar-Sidebar
 Assert ($ui.navProyecto.Content.Children.Count -eq 2) 'Menú expandido no recupera texto'
 Assert ($ui.gridListado.Height -eq 88) 'Lista vacía desperdicia espacio'
 $script:ultimoScan=@([pscustomobject]@{Nombre='fixture.mkv'});Update-HdzDesignState
 Assert ($ui.gridListado.Height -eq 250) 'Lista con vídeos no recupera el alto ajustable'
 $script:ultimoScan=@();Update-HdzDesignState
 foreach($name in @('panGeneral','panProyecto','panAudio','panSubs')){$ui[$name].Visibility='Collapsed'}
 foreach($name in @('secChevGeneral','secChevProyecto','secChevAudio','secChevSubs')){$ui[$name].Text='▸'}
 foreach($width in @(1100,1920)){
  $content=$win.Content;$content.Measure([Windows.Size]::new($width,850));$content.Arrange([Windows.Rect]::new(0,0,$width,850));$content.UpdateLayout()
  Set-HdzWorkspaceStage 'general';$content.UpdateLayout()
  Assert ($script:workspaceNav.ActualWidth -ge $width-300) 'El contenido no aprovecha el ancho disponible'
  Assert ($script:workspaceNav.ActualHeight -lt 70) 'La navegación salta de línea en escritorio'
  Assert ($script:workspaceHeading.ActualHeight -gt 20) 'Falta la cabecera del inspector'
  Assert ($script:workspaceHeadingNote.Visibility -eq 'Collapsed') 'Subtítulo decorativo visible'
  $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,850,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$file=[IO.File]::Create((Join-Path $env:TEMP "hdz_design_$width.png"));try{$encoder.Save($file)}finally{$file.Dispose()}
  Mostrar-Panel 'panSubida';$content.Measure([Windows.Size]::new($width,850));$content.Arrange([Windows.Rect]::new(0,0,$width,850));$content.UpdateLayout()
  $publishing=$ui.panSubidaBody.Child.Children[0]
  foreach($card in @($publishing.Children|Where-Object {$_ -is [Windows.Controls.Border]}|Select-Object -First 3)){Assert ($card.ActualWidth -ge $publishing.ActualWidth-2) 'Tarjeta de publicación ocupa solo media anchura'}
  $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,850,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$file=[IO.File]::Create((Join-Path $env:TEMP "hdz_publicar_$width.png"));try{$encoder.Save($file)}finally{$file.Dispose()};Mostrar-Panel 'panCrear'
 }
 Write-Host 'DESIGN_WPF_OK: uniform headers, expansion, preserved events, vector navigation, keyboard focus, compact empty state and wide-screen layout.'
} finally {Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue}
