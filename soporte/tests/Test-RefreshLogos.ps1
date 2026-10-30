$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:HDZ_GUI_TEST='1'
$env:HDZ_GUI_TEST_DIR=Join-Path $env:TEMP ('hdz_test_refresh_logos_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($env:HDZ_GUI_TEST_DIR)
function Assert($ok,$msg){if(-not $ok){throw $msg}}
try {
    . (Join-Path $repo 'HDZ-GUI.ps1')
    $ui.cfgTmdbKey.Text='fixture-key'
    function Invoke-HdzRestMethod {param($Uri,$Method,$Headers,$TimeoutSec)
        $script:request=@{Uri=$Uri;Headers=$Headers}
        return @{logos=@(@{file_path='/fixture.png';width=200;height=100;iso_639_1='es';vote_average=1})}
    }
    $fetched=@(Get-TmdbLogos '54478' 'tv' -Fresh)
    Assert ($fetched.Count -eq 1 -and $request.Uri -match 'language=es-ES') 'Falta la consulta de imágenes en español'
    Assert ($request.Headers['Cache-Control'] -eq 'no-cache') 'No pide refresco de caché'
    # Sin red: imágenes locales y catálogo controlado para comprobar que no se pisan campos.
    $script:fixtureLogos=@(1..13|ForEach-Object {[pscustomobject]@{Url=([uri](Join-Path $repo 'hdz_logo_r.png')).AbsoluteUri;Width=200;Height=100;Lang='es';Voto=1}})
    function Get-TmdbLogos($id,$tipo,[switch]$Fresh){
        $script:lastLogoRequest=@{Id=$id;Tipo=$tipo;Fresh=[bool]$Fresh}
        if($script:failLogos){throw 'Fallo simulado'}
        if($script:switchLogos){$script:subidaTabId='otra-ficha'}
        return $script:fixtureLogos
    }
    $script:tmdbTipo='tv';$ui.upTmdb.Text='54478';$script:ultimoTmdbAplicado='54478'
    $ui.upDescripcion.Text='[center]Texto editado [img=700]https://example.test/logo.png[/img][/center]'
    $ui.upTitulo.Text='Mi título';$ui.upKeywords.Text='mis palabras';$ui.upImdb.Text='tt123'
    $script:logoSel='https://example.test/logo.png'
    $before=Snapshot-Subida
    $ui.btnActualizarLogos.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($lastLogoRequest.Id -eq '54478' -and $lastLogoRequest.Tipo -eq 'tv' -and $lastLogoRequest.Fresh) 'Consulta otra ficha o sin refrescar'
    Assert ($ui.panLogos.Children.Count -eq 13) 'Recorta los logos después del duodécimo'
    Assert ($ui.upDescripcion.Text -eq $before.Descripcion -and $script:logoSel -eq $before.LogoSel) 'Cambió descripción o selección'
    Assert ($ui.upTitulo.Text -eq $before.Titulo -and $ui.upKeywords.Text -eq $before.Keywords -and $ui.upImdb.Text -eq $before.Imdb) 'Reaplicó metadatos'
    $ui.txtLogoPersonalizado.Text='https://image.tmdb.org/t/p/original/logo-personalizado.png'
    $ui.btnUsarLogoPersonalizado.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert ($ui.upDescripcion.Text.Contains('[img=700]https://image.tmdb.org/t/p/original/logo-personalizado.png[/img]')) 'No añade un logo personalizado de TMDB'
    Assert (-not $ui.txtLogoPersonalizado.Text) 'No limpia el campo del logo personalizado tras añadirlo'
    $script:agSync=[hashtable]::Synchronized(@{Estado=$null;PushNow=$false})
    Aplicar-ComandoAgente ([pscustomobject]@{type='click';name='btnActualizarLogos';_id='logos-web-ok';session=$script:agSession;subidaTab=$script:tabActual})
    Assert ($script:agCompleted['logos-web-ok'].ok) 'Falló la orden de la web'
    Aplicar-ComandoAgente ([pscustomobject]@{type='set_custom_logo';url='https://image.tmdb.org/t/p/original/logo-web.png';_id='logo-personalizado-web';session=$script:agSession;subidaTab=$script:tabActual})
    Assert ($script:agCompleted['logo-personalizado-web'].ok -and $ui.upDescripcion.Text.Contains('logo-web.png')) 'La web no añade el logo personalizado'
    $script:failLogos=$true
    Aplicar-ComandoAgente ([pscustomobject]@{type='click';name='btnActualizarLogos';_id='logos-web-fail';session=$script:agSession;subidaTab=$script:tabActual})
    Assert (-not $script:agCompleted['logos-web-fail'].ok) 'La web confirmó un fallo como éxito'
    Assert ($script:logosActuales.Count -eq 13 -and $ui.btnActualizarLogos.IsEnabled) 'El fallo perdió logos o bloqueó el botón'
    $script:failLogos=$false;$script:fixtureLogos=@();$beforeEmpty=Snapshot-Subida
    Update-HdzTmdbLogos
    Assert ($script:logosActuales.Count -eq 0 -and $ui.cardLogos.Visibility -eq 'Visible') 'No permite refrescar un catálogo vacío'
    Assert ($ui.upDescripcion.Text -eq $beforeEmpty.Descripcion -and $script:logoSel -eq $beforeEmpty.LogoSel) 'El catálogo vacío borró la elección anterior'
    $script:switchLogos=$true
    $failed=$false;try{Update-HdzTmdbLogos}catch{$failed=$true}
    Assert $failed 'Actualiza la ficha equivocada tras cambiar de pestaña'
    $script:switchLogos=$false;$ui.upTmdb.Text=''
    $failed=$false;try{Update-HdzTmdbLogos}catch{$failed=$true}
    Assert $failed 'Acepta un ID vacío'
    Write-Host 'REFRESH_LOGOS_OK: desktop/web, fields preserved, empty/error/stale guards, no truncation.'
} finally {
    if($script:agStateTimer){$script:agStateTimer.Stop()}
    Remove-Item Env:HDZ_GUI_TEST,Env:HDZ_GUI_TEST_DIR -ErrorAction SilentlyContinue
}
