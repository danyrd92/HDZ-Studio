# =========================================================================
# HDZ-CapturasContexto.ps1 — selección y subida desde el menú contextual
# =========================================================================
# La captura la genera Capturas-MenuContextual.ps1 con HDZ-Capturas.ps1. Este
# módulo aporta la segunda mitad del flujo de HDZ Studio: miniaturas,
# selección, subida asíncrona y copia de BBCode con miniaturas enlazadas.

function Get-HdzContextUploadSettings {
    $r = [ordered]@{
        HostImg    = 'FREEIMAGE'
        ImgbbKey   = ''
        ImgboxUser = ''
        ImgboxPass = ''
    }
    try {
        if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { return [pscustomobject]$r }
        $ruta = Join-Path $env:APPDATA 'HDZ-GUI.settings.json'
        if (-not (Test-Path -LiteralPath $ruta -PathType Leaf)) { return [pscustomobject]$r }
        $aj = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8 | ConvertFrom-Json
        $tipoHost = "$($aj.HostImg)".Trim().ToUpperInvariant()
        if ($tipoHost -in @('FREEIMAGE','IMGBB','IMGBOX','PIXHOST')) { $r.HostImg = $tipoHost }
        $r.ImgbbKey = "$($aj.ImgbbKey)".Trim()
        $r.ImgboxUser = "$($aj.ImgboxUser)".Trim()
        if (-not [string]::IsNullOrWhiteSpace("$($aj.ImgboxPass)")) {
            try { $r.ImgboxPass = [System.Net.NetworkCredential]::new('', (ConvertTo-SecureString "$($aj.ImgboxPass)")).Password } catch {}
        }
    } catch {}
    return [pscustomobject]$r
}

function Write-HdzContextJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Data)
    try {
        $tmp = "$Path.$PID.tmp"
        $json = $Data | ConvertTo-Json -Depth 12 -Compress
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8)
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Read-HdzContextJson {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-HdzContextScreenshotBbcode {
    param([string]$Full)
    if ([string]::IsNullOrWhiteSpace($Full)) { return $null }
    return "[img=350]$Full[/img]"
}
function Join-HdzContextScreenshotRows($Tags) {
    $Tags=@($Tags);$lines=@()
    for($i=0;$i -lt $Tags.Count;$i+=5){$lines+=($Tags[$i..([Math]::Min($i+4,$Tags.Count-1))] -join '   ')}
    return $lines -join ([Environment]::NewLine)
}

# Mismo motor de subida y respaldo que la GUI.
$script:hdzContextImageModule = Join-Path $PSScriptRoot 'HDZ-ImageHosts.ps1'
$script:hdzContextUploadWorker = {
    param($Rutas,$HostType,$ImgbbKey,$ImgboxUser,$ImgboxPass,$GalleryTitle,$ModulePath,$Sync)
    try {
        . $ModulePath
        $settings=@{ImgbbKey=$ImgbbKey;ImgboxUser=$ImgboxUser;ImgboxPass=$ImgboxPass}
        $result=Invoke-HdzImageUploadBatch -Paths $Rutas -Preferred $HostType -Settings $settings -Title $GalleryTitle -Sync $Sync
        $Sync.Items=$result.Items; $Sync.Error=$result.Error; $Sync.Aviso=$result.Aviso; $Sync.Gal=$result.Gal
        $Sync.Fase=if($result.Error){'Subida con capturas pendientes.'}else{'Subida verificada.'}
    } catch {$Sync.Error=$_.Exception.Message}
    finally {$Sync.Fin=$true}
}

function Start-HdzContextUpload {
    param(
        [Parameter(Mandatory)][string[]]$Rutas,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][object]$Settings,
        [string]$GalleryTitle = ''
    )

    $rutasLimpias = @($Rutas | ForEach-Object { "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($rutasLimpias.Count -eq 0) { throw 'No hay capturas seleccionadas para subir.' }
    $sync = [hashtable]::Synchronized(@{
        Done = 0; Total = $rutasLimpias.Count; Fase = 'Preparando subida…'; Fin = $false
        Error = $null; Items = @(); Aviso = $null; Gal = $null
    })
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($script:hdzContextUploadWorker.ToString())
        [void]$ps.AddArgument($rutasLimpias)
        [void]$ps.AddArgument("$HostType")
        [void]$ps.AddArgument("$($Settings.ImgbbKey)")
        [void]$ps.AddArgument("$($Settings.ImgboxUser)")
        [void]$ps.AddArgument("$($Settings.ImgboxPass)")
        [void]$ps.AddArgument("$GalleryTitle")
        [void]$ps.AddArgument($script:hdzContextImageModule)
        [void]$ps.AddArgument($sync)
        $async = $ps.BeginInvoke()
        return [pscustomobject]@{ PowerShell=$ps; Async=$async; Sync=$sync }
    } catch {
        try { $ps.Dispose() } catch {}
        throw
    }
}

# El DispatcherTimer de la cuadricula se ejecuta fuera del ambito local del
# evento Click que inicia la subida. Mantener el estado activo a nivel de
# script replica el patron estable usado por HDZ-GUI.ps1 y evita que una
# clausura local se quede viendo 0/N aunque el runspace ya este trabajando.
$global:HDZ_ContextCaptureUploadState = $null
$script:hdzContextUploadLogPath = Join-Path $env:TEMP 'HDZ-CapturasContexto.log'

function Write-HdzContextUploadLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss.fff} PID={1} {2}{3}' -f (Get-Date), $PID, $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($script:hdzContextUploadLogPath, $line, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

function Complete-HdzContextUploadUi {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [object]$Result,
        [string]$FallbackError
    )

    if (-not $Context.Busy) { return }
    try { if ($Context.Timer) { $Context.Timer.Stop() } } catch {}
    try {
        if ($Context.PowerShell -and $Context.Async) { [void]$Context.PowerShell.EndInvoke($Context.Async) }
    } catch {
        if (-not $FallbackError) { $FallbackError = "La subida se interrumpio: $($_.Exception.Message)" }
    }
    try { if ($Context.PowerShell) { $Context.PowerShell.Dispose() } } catch {}

    $Context.UiState.Busy = $false
    $Context.Busy = $false
    $Context.Started = $null
    $Context.PanProgreso.Visibility = 'Collapsed'
    foreach ($button in @($Context.HostButtons.Values)) { $button.IsEnabled = $true }

    $resultItems = if ($Result -and $Result.Items) { @($Result.Items) } else { @() }
    foreach ($item in $resultItems) {
        if (-not $item.Full -or -not $item.Thumb -or -not $item.Page) { continue }
        $rowFound = @($Context.Rows | Where-Object { "$($_.Ruta)" -eq "$($item.Ruta)" } | Select-Object -First 1)
        if ($rowFound.Count -gt 0) {
            $rowFound[0].Subida = "$($item.Full)"
            $rowFound[0].Thumb = "$($item.Thumb)"
            $rowFound[0].Page = "$($item.Page)"
            $rowFound[0].Bbcode = Get-HdzContextScreenshotBbcode -Full $rowFound[0].Subida
            $rowFound[0].Estado.Text = '✓ PNG subida · miniatura rectangular 350 px'
        }
    }

    $allBbcodes = @($Context.Rows | Where-Object { $_.Bbcode } | ForEach-Object { "$($_.Bbcode)" })
    if ($allBbcodes.Count -gt 0) {
        $Context.TxtResultados.Text = Join-HdzContextScreenshotRows $allBbcodes
        $Context.TxtResultados.Visibility = 'Visible'
        $Context.BtnCopiar.Visibility = 'Visible'
    }

    $errorText = if ($Result -and $Result.Error) { "$($Result.Error)" } else { $FallbackError }
    $ok = @($resultItems | Where-Object { $_.Full -and $_.Thumb -and $_.Page }).Count
    if ($errorText) {
        $Context.LblEstado.Text = "Subidas $ok de $($Context.Total). $errorText"
        Write-HdzContextUploadLog "FIN ERROR ok=$ok total=$($Context.Total) detalle=$errorText"
    } elseif ($Result -and $Result.Aviso) {
        $Context.LblEstado.Text = "✓ $ok PNG subidas; BBCode listo. $($Result.Aviso)"
        Write-HdzContextUploadLog "FIN AVISO ok=$ok total=$($Context.Total)"
    } else {
        $Context.LblEstado.Text = "✓ $ok PNG subidas a $($Context.UiState.Host); BBCode con miniaturas listo."
        Write-HdzContextUploadLog "FIN OK ok=$ok total=$($Context.Total)"
    }

    $Context.PowerShell = $null
    $Context.Async = $null
    $Context.Sync = $null
    $Context.Timer = $null
    if ($Context.UpdateUi) { & $Context.UpdateUi }
}

function Stop-HdzContextUploadOperation {
    param([Parameter(Mandatory)][hashtable]$Context)
    try { if ($Context.Timer) { $Context.Timer.Stop() } } catch {}
    try {
        if ($Context.PowerShell -and $Context.Async -and -not $Context.Async.IsCompleted) {
            $Context.PowerShell.Stop()
        }
    } catch {}
    try {
        if ($Context.PowerShell -and $Context.Async) { [void]$Context.PowerShell.EndInvoke($Context.Async) }
    } catch {}
    try { if ($Context.PowerShell) { $Context.PowerShell.Dispose() } } catch {}
    $Context.Busy = $false
    $Context.PowerShell = $null
    $Context.Async = $null
    $Context.Sync = $null
    $Context.Timer = $null
}

function Update-HdzContextUploadUi {
    # $startUpload se ejecuta dentro de un GetNewClosure(). En PowerShell esa
    # clausura tiene su propio ambito de script; por eso una variable $script:
    # escrita alli no era visible desde este manejador y el contador quedaba
    # eternamente en 0/N. El proceso es exclusivo para esta ventana, de modo
    # que un nombre global y especifico comparte la misma referencia sin riesgo.
    $context = $global:HDZ_ContextCaptureUploadState
    if (-not $context) { return }
    try {
        if (-not $context.Busy) {
            if ($context.Timer) { $context.Timer.Stop() }
            return
        }

        $state = $context.Sync
        if ($state) {
            $done = [int]$state.Done
            $total = [int]$state.Total
            $context.BarProgreso.Value = if ($total -gt 0) { [int](100 * $done / $total) } else { 0 }
            $context.LblProgresoPct.Text = "$done/$total"
            if ($state.Fase) { $context.LblProgreso.Text = "$($state.Fase)" }
            if ($done -ne $context.LastDone) {
                $context.LastDone = $done
                Write-HdzContextUploadLog "PROGRESO done=$done total=$total fase=$($state.Fase)"
            }
        }

        $ended = $false
        try { if ($context.Async) { $ended = $context.Async.IsCompleted } } catch { $ended = $true }
        if (($state -and $state.Fin) -or $ended) {
            $result = if ($state) {
                [pscustomobject]@{
                    Items=@($state.Items); Error="$($state.Error)"; Aviso="$($state.Aviso)"; Gal=$state.Gal
                }
            } else {
                [pscustomobject]@{ Items=@(); Error='La subida termino sin estado.'; Aviso=$null; Gal=$null }
            }
            $fallback = if ($state -and $state.Error) { "$($state.Error)" } else { $null }
            Complete-HdzContextUploadUi -Context $context -Result $result -FallbackError $fallback
            return
        }

        if ($context.Started -and ((Get-Date) - $context.Started).TotalMinutes -gt 15) {
            try { if ($context.PowerShell) { $context.PowerShell.Stop() } } catch {}
            $result = [pscustomobject]@{ Items=@(); Error='El proceso de subida no respondio en 15 minutos y se cancelo.'; Aviso=$null; Gal=$null }
            Complete-HdzContextUploadUi -Context $context -Result $result -FallbackError $result.Error
        }
    } catch {
        $detail = $_.Exception.ToString()
        Write-HdzContextUploadLog "TICK ERROR $detail"
        try {
            $result = [pscustomobject]@{ Items=@(); Error="Error actualizando la subida: $($_.Exception.Message)"; Aviso=$null; Gal=$null }
            Complete-HdzContextUploadUi -Context $context -Result $result -FallbackError $result.Error
        } catch {
            try {
                if ($context.Timer) { $context.Timer.Stop() }
                $context.LblProgreso.Text = "Error actualizando la subida: $($_.Exception.Message)"
            } catch {}
        }
    }
}

function Show-HdzCaptureGrid {
    param(
        [Parameter(Mandatory)][string]$VideoPath,
        [Parameter(Mandatory)][string[]]$Captures
    )

    $cfg = Get-HdzContextUploadSettings
    $safeCaptures = @($Captures | Where-Object { $_ -and (Test-Path -LiteralPath "$_" -PathType Leaf) } | Select-Object -Unique)
    if ($safeCaptures.Count -eq 0) { return }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HDZ Studio · Capturas" Width="1120" Height="760"
        MinWidth="860" MinHeight="520" WindowStartupLocation="CenterScreen"
        ResizeMode="CanMinimize" Background="#0C0C0F" Foreground="#EDEDEF"
        FontFamily="Segoe UI" FontSize="13" ShowInTaskbar="True"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  $HdzStudioThemeXaml
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="0,0,0,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="{StaticResource AccentBrush}" CornerRadius="2" Height="36" VerticalAlignment="Top"/>
      <StackPanel Grid.Column="1" Margin="12,0,0,0">
        <TextBlock Text="Seleccionar capturas" FontSize="21" FontWeight="Bold"/>
        <TextBlock x:Name="lblVideo" Style="{StaticResource D}"/>
      </StackPanel>
      <TextBlock x:Name="lblTotal" Grid.Column="2" VerticalAlignment="Top" Foreground="{StaticResource SubBrush}" Margin="18,5,0,0"/>
    </Grid>
    <Border Grid.Row="1" Style="{StaticResource Card}" Padding="12" Margin="0">
      <ScrollViewer x:Name="scrCapturas" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <WrapPanel x:Name="panCapturas"/>
      </ScrollViewer>
    </Border>
    <StackPanel Grid.Row="2">
      <Border x:Name="panProgreso" Style="{StaticResource Card}" Visibility="Collapsed" Margin="0,12,0,0">
        <StackPanel>
          <ProgressBar x:Name="barProgreso" Height="12" Minimum="0" Maximum="100" Value="0"/>
          <Grid Margin="0,8,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="lblProgreso" Grid.Column="0" Foreground="{StaticResource SubBrush}" TextWrapping="Wrap"/>
            <TextBlock x:Name="lblProgresoPct" Grid.Column="1" Foreground="{StaticResource SubBrush}" Margin="12,0,0,0"/>
          </Grid>
        </StackPanel>
      </Border>
      <Border Style="{StaticResource Card}" Margin="0,12,0,0">
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="lblSeleccion" Grid.Column="0" Style="{StaticResource H}"/>
            <TextBlock x:Name="lblHost" Grid.Column="1" Foreground="{StaticResource SubBrush}" VerticalAlignment="Center" TextAlignment="Right"/>
          </Grid>
          <WrapPanel x:Name="panHosts" Margin="0,10,0,0"/>
          <TextBlock x:Name="lblEstado" Foreground="{StaticResource SubBrush}" TextWrapping="Wrap" Margin="0,8,0,0"/>
          <TextBox x:Name="txtResultados" Style="{StaticResource Input}" Visibility="Collapsed"
                   Height="82" Margin="0,10,0,0" IsReadOnly="True" AcceptsReturn="True"
                   TextWrapping="Wrap" VerticalContentAlignment="Top"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
          <Grid Margin="0,12,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
              <Button x:Name="btnTodas" Content="Todas" Style="{StaticResource Ghost}" MinWidth="84" Margin="0,0,7,0"/>
              <Button x:Name="btnNinguna" Content="Ninguna" Style="{StaticResource Ghost}" MinWidth="84"/>
              <Button x:Name="btnCopiar" Content="Copiar BBCode" Style="{StaticResource Ghost}" Visibility="Collapsed" Margin="14,0,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <Button x:Name="btnCerrar" Content="Cerrar" Style="{StaticResource Ghost}" MinWidth="100" Margin="0,0,8,0" IsCancel="True"/>
              <Button x:Name="btnSubir" Content="⬆  Subir seleccionadas" Style="{StaticResource Primary}" MinWidth="180"/>
            </StackPanel>
          </Grid>
        </StackPanel>
      </Border>
    </StackPanel>
  </Grid>
</Window>
"@

    $window = ConvertFrom-HdzXaml $xaml
    $lblVideo = $window.FindName('lblVideo')
    $lblTotal = $window.FindName('lblTotal')
    $panCapturas = $window.FindName('panCapturas')
    $panHosts = $window.FindName('panHosts')
    $lblSeleccion = $window.FindName('lblSeleccion')
    $lblHost = $window.FindName('lblHost')
    $lblEstado = $window.FindName('lblEstado')
    $panProgreso = $window.FindName('panProgreso')
    $barProgreso = $window.FindName('barProgreso')
    $lblProgreso = $window.FindName('lblProgreso')
    $lblProgresoPct = $window.FindName('lblProgresoPct')
    $txtResultados = $window.FindName('txtResultados')
    $btnTodas = $window.FindName('btnTodas')
    $btnNinguna = $window.FindName('btnNinguna')
    $btnCopiar = $window.FindName('btnCopiar')
    $btnCerrar = $window.FindName('btnCerrar')
    $btnSubir = $window.FindName('btnSubir')

    $lblVideo.Text = [System.IO.Path]::GetFileName($VideoPath)
    $lblTotal.Text = "$($safeCaptures.Count) imagen(es)"
    $hostOptions = @(
        @{ V = 'FREEIMAGE'; T = 'freeimage.host · rectangular 350 px' },
        @{ V = 'IMGBB';     T = 'imgbb · rectangular 350 px' },
        @{ V = 'IMGBOX';    T = 'imgbox · rectangular 350 px' },
        @{ V = 'PIXHOST';   T = 'Pixhost · 350 px · hasta 10 MB' }
    )
    $uiState = [hashtable]::Synchronized(@{
        Host = $cfg.HostImg
        Busy = $false
        Closed = $false
        Sync = $null
    })
    $hostButtons = @{}

    $rows = @()
    foreach ($ruta in $safeCaptures) {
        $cont = New-Object System.Windows.Controls.StackPanel
        $cont.Width = 252
        $cont.Margin = [System.Windows.Thickness]::new(0,0,12,12)
        $bordeImg = New-Object System.Windows.Controls.Border
        $bordeImg.CornerRadius = [System.Windows.CornerRadius]::new(7)
        $bordeImg.Background = $window.Resources['FieldBrush']
        $bordeImg.BorderThickness = [System.Windows.Thickness]::new(3)
        $bordeImg.Height = 142
        $bordeImg.Cursor = [System.Windows.Input.Cursors]::Hand
        $bordeImg.ClipToBounds = $true
        $bordeImg.ToolTip = 'Clic para marcar/desmarcar · 🔍 para verla a tamaño completo'
        $gridImg = New-Object System.Windows.Controls.Grid
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = [Uri]$ruta
            $bmp.DecodePixelWidth = 504
            $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $img = New-Object System.Windows.Controls.Image
            $img.Source = $bmp
            $img.Stretch = 'UniformToFill'
            [void]$gridImg.Children.Add($img)
        } catch {
            $fallback = New-Object System.Windows.Controls.TextBlock
            $fallback.Text = 'No se pudo cargar la imagen'
            $fallback.Foreground = $window.Resources['SubBrush']
            $fallback.HorizontalAlignment = 'Center'
            $fallback.VerticalAlignment = 'Center'
            [void]$gridImg.Children.Add($fallback)
        }
        $rutaZoom = $ruta
        $btnZoom = New-Object System.Windows.Controls.Button
        $btnZoom.Content = '🔍'
        $btnZoom.FontSize = 13
        $btnZoom.Width = 30
        $btnZoom.Height = 30
        $btnZoom.HorizontalAlignment = 'Right'
        $btnZoom.VerticalAlignment = 'Top'
        $btnZoom.Margin = [System.Windows.Thickness]::new(0,6,6,0)
        $btnZoom.Foreground = $window.Resources['TextBrush']
        $btnZoom.Background = $window.Resources['FieldBrush']
        $btnZoom.BorderBrush = $window.Resources['CardBorderBrush']
        $btnZoom.BorderThickness = [System.Windows.Thickness]::new(1)
        $btnZoom.ToolTip = 'Ver a tamaño completo'
        $btnZoom.Add_Click({ try { Start-Process $rutaZoom } catch {} }.GetNewClosure())
        [void]$gridImg.Children.Add($btnZoom)
        $bordeImg.Child = $gridImg
        [void]$cont.Children.Add($bordeImg)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Foreground = $window.Resources['TextBrush']
        $cb.IsChecked = $true
        $cb.Margin = [System.Windows.Thickness]::new(2,6,0,0)
        $cb.Content = [System.IO.Path]::GetFileName($ruta)
        $cb.ToolTip = 'Seleccionar o quitar esta captura'
        [void]$cont.Children.Add($cb)
        $lblSubida = New-Object System.Windows.Controls.TextBlock
        $lblSubida.Foreground = $window.Resources['OkBrush']
        $lblSubida.FontSize = 10.5
        $lblSubida.TextTrimming = 'CharacterEllipsis'
        $lblSubida.MaxWidth = 246
        $lblSubida.Margin = [System.Windows.Thickness]::new(2,3,0,0)
        [void]$cont.Children.Add($lblSubida)
        $row = [pscustomobject]@{
            Ruta=$ruta; Check=$cb; Borde=$bordeImg; Subida=$null
            Thumb=$null; Page=$null; Bbcode=$null; Estado=$lblSubida
        }
        $rows += $row
        $rowRef = $row
        $pintar = {
            if ($cb.IsChecked -eq $true) {
                $bordeImg.BorderBrush = $window.Resources['AccentBrush']
                $bordeImg.Opacity = 1.0
            } else {
                $bordeImg.BorderBrush = $window.Resources['CardBorderBrush']
                $bordeImg.Opacity = 0.45
            }
            if ($rowRef.Bbcode) { $rowRef.Estado.Text = '✓ PNG subida · miniatura rectangular 350 px' } else { $rowRef.Estado.Text = '' }
        }.GetNewClosure()
        & $pintar
        $bordeImg.Add_MouseLeftButtonUp({ $cb.IsChecked = -not $cb.IsChecked }.GetNewClosure())
        $cb.Add_Checked({ & $pintar; if ($uiState.Update) { & $uiState.Update } }.GetNewClosure())
        $cb.Add_Unchecked({ & $pintar; if ($uiState.Update) { & $uiState.Update } }.GetNewClosure())
        [void]$panCapturas.Children.Add($cont)
    }

    $updateUi = {
        $seleccionadas = @($rows | Where-Object { $_.Check.IsChecked -eq $true })
        $pendientes = @($seleccionadas | Where-Object { -not $_.Subida })
        $hostText = switch ($uiState.Host) {
            'IMGBB'  { if ($cfg.ImgbbKey) { 'imgbb · rectangular 350 px' } else { 'imgbb · falta la clave en Ajustes' } }
            'IMGBOX' { 'imgbox · rectangular 350 px' }
            default  { 'freeimage.host · rectangular 350 px' }
        }
        $lblSeleccion.Text = "$($seleccionadas.Count) de $($rows.Count) seleccionada(s) · $($pendientes.Count) pendiente(s)"
        $lblHost.Text = $hostText
        $lblHost.Foreground = if ($uiState.Host -eq 'IMGBB' -and -not $cfg.ImgbbKey) { $window.Resources['WarnBrush'] } else { $window.Resources['SubBrush'] }
        $btnSubir.IsEnabled = (-not $uiState.Busy) -and ($pendientes.Count -gt 0) -and (-not ($uiState.Host -eq 'IMGBB' -and -not $cfg.ImgbbKey))
        $btnTodas.IsEnabled = -not $uiState.Busy
        $btnNinguna.IsEnabled = -not $uiState.Busy
        $btnCopiar.IsEnabled = (@($rows | Where-Object { $_.Bbcode }).Count -gt 0)
    }.GetNewClosure()
    $uiState.Update = $updateUi

    $pintarHosts = {
        foreach ($key in $hostButtons.Keys) {
            $label = "$($hostOptions | Where-Object V -eq $key | Select-Object -ExpandProperty T)"
            $hostButtons[$key].Content = if ($key -eq $uiState.Host) { "✓  $label" } else { $label }
        }
    }.GetNewClosure()
    foreach ($opt in $hostOptions) {
        $hb = New-Object System.Windows.Controls.Button
        $hb.Content = $opt.T
        $hb.Tag = $opt.V
        $hb.Style = $window.Resources['Ghost']
        $hb.Margin = [System.Windows.Thickness]::new(0,0,7,0)
        $hb.Add_Click({
            param($sender, $e)
            if ($uiState.Busy) { return }
            $uiState.Host = "$($sender.Tag)"
            & $pintarHosts
            & $updateUi
        }.GetNewClosure())
        $hostButtons[$opt.V] = $hb
        [void]$panHosts.Children.Add($hb)
    }
    & $pintarHosts

    $upload = [hashtable]::Synchronized(@{
        Busy            = $false
        PowerShell      = $null
        Async           = $null
        Sync            = $null
        Timer           = $null
        Started         = $null
        Total           = 0
        LastDone        = -1
        UiState         = $uiState
        Rows            = $rows
        HostButtons     = $hostButtons
        PanProgreso     = $panProgreso
        BarProgreso     = $barProgreso
        LblProgreso     = $lblProgreso
        LblProgresoPct  = $lblProgresoPct
        LblEstado       = $lblEstado
        TxtResultados   = $txtResultados
        BtnCopiar       = $btnCopiar
        UpdateUi        = $updateUi
    })
    Write-HdzContextUploadLog "CUADRICULA ABIERTA apartment=$([Threading.Thread]::CurrentThread.ApartmentState) capturas=$($rows.Count) script=$PSCommandPath"
    $startUpload = {
        param($pendingRows)
        if ($uiState.Busy -or @($pendingRows).Count -eq 0) { return }
        if ($uiState.Host -eq 'IMGBB' -and -not $cfg.ImgbbKey) {
            $lblEstado.Text = 'Falta la clave de imgbb en Ajustes / claves.'
            return
        }
        $uiState.Busy = $true
        $upload.Busy = $true
        $upload.Started = Get-Date
        $upload.LastDone = -1
        $routes = @($pendingRows | ForEach-Object { $_.Ruta })
        $upload.Total = $routes.Count
        $panProgreso.Visibility = 'Visible'
        $barProgreso.Value = 0
        $lblProgreso.Text = 'Preparando subida…'
        $lblProgresoPct.Text = "0/$($routes.Count)"
        foreach ($hb in $hostButtons.Values) { $hb.IsEnabled = $false }
        $galTitulo = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath) -replace '(?i)_cap_\d+$',''
        $global:HDZ_ContextCaptureUploadState = $upload
        Write-HdzContextUploadLog "INICIO host=$($uiState.Host) total=$($routes.Count) apartment=$([Threading.Thread]::CurrentThread.ApartmentState)"
        try {
            $operation = Start-HdzContextUpload -Rutas $routes -HostType $uiState.Host -Settings $cfg -GalleryTitle $galTitulo
            $upload.PowerShell = $operation.PowerShell
            $upload.Async = $operation.Async
            $upload.Sync = $operation.Sync
            Write-HdzContextUploadLog 'RUNSPACE INICIADO'
        } catch {
            Complete-HdzContextUploadUi -Context $upload -Result $null -FallbackError "No se pudo iniciar la subida: $($_.Exception.Message)"
            return
        }
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $timer.Add_Tick({ Update-HdzContextUploadUi })
        $upload.Timer = $timer
        $timer.Start()
        Write-HdzContextUploadLog 'TIMER INICIADO'
        & $updateUi
    }.GetNewClosure()

    $btnTodas.Add_Click({
        foreach ($row in $rows) { $row.Check.IsChecked = $true }
        & $updateUi
    }.GetNewClosure())
    $btnNinguna.Add_Click({
        foreach ($row in $rows) { $row.Check.IsChecked = $false }
        & $updateUi
    }.GetNewClosure())
    $btnCopiar.Add_Click({
        $bbcodes = @($rows | Where-Object { $_.Bbcode } | ForEach-Object { "$($_.Bbcode)" })
        if ($bbcodes.Count -gt 0) {
            try {
                [System.Windows.Clipboard]::SetText((Join-HdzContextScreenshotRows $bbcodes))
                $lblEstado.Text = "✓ BBCode de $($bbcodes.Count) captura(s) copiado al portapapeles."
            } catch { $lblEstado.Text = 'No se pudo copiar al portapapeles.' }
        }
    }.GetNewClosure())
    $btnSubir.Add_Click({
        $seleccionadas = @($rows | Where-Object { $_.Check.IsChecked -eq $true })
        if ($seleccionadas.Count -eq 0) { $lblEstado.Text = 'Marca al menos una captura.'; return }
        $pendientes = @($seleccionadas | Where-Object { -not $_.Subida })
        if ($pendientes.Count -eq 0) { $lblEstado.Text = 'Las capturas seleccionadas ya están subidas.'; return }
        & $startUpload $pendientes
    }.GetNewClosure())
    $btnCerrar.Add_Click({ $window.Close() }.GetNewClosure())
    $window.Add_Closing({
        $uiState.Closed = $true
        if ($uiState.Busy) {
            Stop-HdzContextUploadOperation -Context $upload
        }
        if ($global:HDZ_ContextCaptureUploadState -eq $upload) { $global:HDZ_ContextCaptureUploadState = $null }
    }.GetNewClosure())
    & $updateUi
    [void]$window.ShowDialog()
    if ($global:HDZ_ContextCaptureUploadState -eq $upload) { $global:HDZ_ContextCaptureUploadState = $null }
}
