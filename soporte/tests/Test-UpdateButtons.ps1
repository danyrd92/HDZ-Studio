param([string]$AppRoot)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($AppRoot){$root=[IO.Path]::GetFullPath($AppRoot)}
function Assert($condition,$message){if(-not $condition){throw $message}}
function Must-Throw([scriptblock]$work){$failed=$false;try{& $work}catch{$failed=$true};Assert $failed 'Se aceptó una actualización no disponible/segura'}
$env:HDZ_GUI_TEST='1'
try{
    . (Join-Path $root 'HDZ-GUI.ps1')
    $script:HDZVersion='1.17.10'
    foreach($version in @('','no-version','1.17.9','1.17.10')){
        Set-HdzUpdateVersion @{version=$version}
        Assert ($ui.btnActualizar.Visibility -eq 'Collapsed') "Botón visible sin actualización: $version"
        Assert (-not (Componer-EstadoAgente | ConvertFrom-Json).update.available) 'Estado remoto incorrecto'
        Must-Throw {Request-HdzUpdate}
    }
    $script:ajusteVerDescartada='1.17.11'
    Set-HdzUpdateVersion @{version='1.17.11'}
    Assert ($ui.btnActualizar.Visibility -eq 'Visible' -and $ui.btnActualizar.IsEnabled) 'Botón nuevo ausente'
    # Visibility=Visible no basta: un botón puede estar tapado o fuera de la columna.
    $updateButton=$ui.btnActualizar
    foreach($collapsed in @($false,$true)){
        $script:sidebarColapsado=$collapsed;Aplicar-Sidebar
        foreach($size in @(@(960,640),@(1300,850),@(1920,1080))){
            $content=$win.Content;$content.Measure([Windows.Size]::new($size[0],$size[1]));$content.Arrange([Windows.Rect]::new(0,0,$size[0],$size[1]));$content.UpdateLayout()
            $buttonRect=$ui.btnActualizar.TransformToAncestor($content).TransformBounds([Windows.Rect]::new(0,0,$ui.btnActualizar.ActualWidth,$ui.btnActualizar.ActualHeight))
            $menuRect=$ui.btnColapsar.TransformToAncestor($content).TransformBounds([Windows.Rect]::new(0,0,$ui.btnColapsar.ActualWidth,$ui.btnColapsar.ActualHeight))
            $sideRect=$ui.sidebar.TransformToAncestor($content).TransformBounds([Windows.Rect]::new(0,0,$ui.sidebar.ActualWidth,$ui.sidebar.ActualHeight))
            Assert ($buttonRect.Width -ge 36 -and $buttonRect.Height -ge 36) 'La actualización no tiene área pulsable'
            Assert ($buttonRect.Left -ge $sideRect.Left -and $buttonRect.Right -le $sideRect.Right -and $buttonRect.Top -ge $sideRect.Top -and $buttonRect.Bottom -le $sideRect.Bottom) "Actualización fuera del menú: compacto=$collapsed, $($size -join 'x')"
            Assert (-not $buttonRect.IntersectsWith($menuRect)) 'El botón del menú tapa la actualización'
            $parent=$ui.btnActualizar
            # La ventana de test no se muestra; sí deben ser visibles todos sus controles.
            while($parent -and $parent -is [Windows.FrameworkElement] -and $parent -isnot [Windows.Window]){Assert ($parent.Visibility -eq 'Visible') "Un ancestro oculta la actualización: $($parent.Name)";$parent=[Windows.LogicalTreeHelper]::GetParent($parent)}
            if($collapsed){Assert ($buttonRect.Bottom -le $menuRect.Top) 'La actualización compacta no está encima del menú'}else{
                $versionRect=$ui.lblVersion.TransformToAncestor($content).TransformBounds([Windows.Rect]::new(0,0,$ui.lblVersion.ActualWidth,$ui.lblVersion.ActualHeight))
                Assert ($buttonRect.Left -ge $versionRect.Right) 'Actualización separada del número de versión'
            }
        }
        Assert ([object]::ReferenceEquals($updateButton,$ui.btnActualizar)) 'Plegar crea otro botón y pierde su manejador'
        Assert ($ui.btnActualizar.Content -is [Windows.Controls.Viewbox]) 'Actualización sin icono vectorial'
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$ui.sidebar.ActualWidth,[int]$ui.sidebar.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($ui.sidebar)
        $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $imagePath=Join-Path $env:TEMP "hdz_update_sidebar_$collapsed.png";$stream=[IO.File]::Create($imagePath);try{$encoder.Save($stream)}finally{$stream.Dispose()}
        Set-HdzUpdateVersion $null;Assert ($ui.btnActualizar.Visibility -eq 'Collapsed') 'Actualización compacta visible sin nueva versión'
        Set-HdzUpdateVersion @{version='1.17.11'}
    }
    foreach($kind in @('montaje','torrent','capturas','imagenes','red','scan')){
        switch($kind){
            montaje{$script:procMontaje=[pscustomobject]@{HasExited=$false}}
            torrent{$script:torSync=@{Fin=$false}}
            capturas{$script:capSync=@{Fin=$false}}
            imagenes{$script:subSync=@{Fin=$false}}
            red{$script:networkBusy=$true}
            scan{$script:scanAsync=[pscustomobject]@{IsCompleted=$false}}
        }
        Update-HdzUpdateButton
        Assert ($ui.btnActualizar.Visibility -eq 'Visible' -and -not $ui.btnActualizar.IsEnabled) "No protege $kind"
        Must-Throw {Request-HdzUpdate}
        $script:procMontaje=$null;$script:torSync=$null;$script:capSync=$null;$script:subSync=$null;$script:networkBusy=$false;$script:scanAsync=$null
    }
    $script:launched=0;$script:closed=0
    Set-Item Function:Start-HdzUpdateInstaller {$script:launched++}
    Set-Item Function:Close-HdzForUpdate {$script:closed++}
    $script:agSync=[hashtable]::Synchronized(@{LastAckIds=@()})
    Aplicar-ComandoAgente ([pscustomobject]@{type='actualizar';_id='update-test';session=$script:agSession})
    Assert ($script:agCompleted['update-test'].ok -and $script:updRequested) 'Orden remota sin confirmar'
    Complete-HdzUpdateRequest
    Assert ($script:launched -eq 0 -and $script:closed -eq 0) 'Cierra antes de confirmar al relay'
    $script:agSync.LastAckIds=@('update-test')
    Complete-HdzUpdateRequest
    Assert ($script:launched -eq 1 -and $script:closed -eq 1) 'No lanza/reabre tras confirmar'
    $script:updRequested=$false;$win.IsEnabled=$true
    Request-HdzUpdate 'lost-ack'
    $script:updRequestedAt=[datetime]::UtcNow.AddSeconds(-31)
    Complete-HdzUpdateRequest
    Assert (-not $script:updRequested -and $win.IsEnabled -and $script:closed -eq 1) 'Pierde la confirmación y cierra el PC'
    Set-Item Function:Start-HdzUpdateInstaller {throw 'Synthetic install launch failure'}
    Request-HdzUpdate
    Complete-HdzUpdateRequest
    Assert (-not $script:updRequested -and $win.IsEnabled -and $script:closed -eq 1) 'Cierra el PC aunque no arrancó el instalador'
    Set-Item Function:Start-HdzUpdateInstaller {throw [ComponentModel.Win32Exception]::new(1223)}
    Request-HdzUpdate
    Complete-HdzUpdateRequest
    Assert (-not $script:updRequested -and $win.IsEnabled -and $script:closed -eq 1) 'Cancelar UAC cierra el programa'
    Set-HdzUpdateVersion $null
    Assert ($ui.btnActualizar.Visibility -eq 'Collapsed') 'Error de comprobación conserva un botón obsoleto'
    Write-Host 'UPDATE_BUTTONS_OK: versiones, botón visible sin solaparse con menú compacto/expandido en tres tamaños, icono vectorial, trabajos activos, confirmación y reintento.'
}finally{Remove-Item Env:HDZ_GUI_TEST -ErrorAction SilentlyContinue}
