// Browser regression against synthetic state. All requests are intercepted locally.
const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
const html=fs.readFileSync(process.env.HDZ_WEB_HTML || path.join(__dirname,'../../web/index.html'),'utf8');
const state={online:true,responsive:true,data:{protocol:2,session:'synthetic-session',version:'test',uiTs:Date.now()/1000,carpeta:'C:\\Pruebas\\Temporada 1',inputs:{ano:'2026',titulo:'Serie de prueba'},estado:'Aviso visible en el móvil',estadoTipo:'warn',opciones:{modoLote:'HOMOGENEO'},montaje:{visible:true,activo:true,pct:72,fase:'Ensamblando MKV 7/9',pct2:54,fase2:'Episodio 7'},tareas:[{titulo:'Torrent',fase:'Calculando piezas',pct:42}],carpetas:['C:\\Pruebas\\Temporada 1','C:\\Pruebas\\Temporada 2'],tmdbResults:[{id:123,titulo:'Documental de prueba',fecha:'2026'}],history:[],firmas:[],tabsProy:[],tabsSubida:[]}};
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});
 try {
  const page=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.route('**/*',route=>{
    const url=new URL(route.request().url());
    if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:html});
    if(url.pathname==='/api/state')return route.fulfill({contentType:'application/json',body:JSON.stringify(state)});
    return route.fulfill({status:404,body:''});
  });
  await page.goto('http://hdz-test.local/');
  await page.waitForTimeout(800);
  await page.evaluate(()=>{window.HDZ_TEST_NO_POLL=true;}); // Isolate assertions from the polling fixture.
  assert.deepEqual(errors,[],'JavaScript errors');
  const status=await page.locator('.destado').evaluate(el=>({display:getComputedStyle(el).display,text:el.textContent}));
  assert(await page.locator('#estadoSummary').isVisible(),'Mobile status summary is hidden');
  await page.locator('#estadoSummary').click();
  assert(await page.locator('#auxProg').isVisible(),'Direct torrent progress is hidden');
  assert((await page.locator('#progTxt').innerText()).includes('7/9'),'Batch count not visible');
  const hybridState=structuredClone(state);
  for(const step of [1,2,3]){
    hybridState.data.montaje={activo:true,visible:true,pct:15+step*7,
      fase:'Fusión Dolby Vision + HDR10 1/1',pct2:step*25,fase2:'Paso '+step+'/3: fusión sintética'};
    await page.evaluate(s=>render(s),hybridState);
    assert((await page.locator('#progTxt').innerText()).includes('Fusión Dolby Vision'),'Hybrid phase not visible');
    assert.equal(await page.locator('#progPct').innerText(),(15+step*7)+'%');
    assert.equal(await page.locator('#prog2Pct').innerText(),step*25+'%');
    assert((await page.locator('#prog2Txt').innerText()).includes('Paso '+step+'/3'),'Hybrid detail not visible');
  }
  await page.evaluate(s=>render(s),state);
  assert(await page.locator('#seasonFolders').innerText().then(x=>x.includes('Temporada 2')),'Extra season is missing');
  const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1);
  assert(!overflow,'Mobile layout overflows');
  assert.equal(await page.locator('[data-group="hostImg"] [data-v="PIXHOST"]').count(),1,'Missing alternate host setting');
  // "Ver" must open the active torrent in THIS browser, never send ver_web to the PC.
  const pcCommands=[];
  page.on('request',r=>{if(new URL(r.url()).pathname==='/api/cmd')pcCommands.push(r.postData())});
  await page.context().route('https://tracker.test/**',r=>r.fulfill({contentType:'text/html',body:'Synthetic tracker page'}));
  await page.evaluate(()=>go('torrent'));
  const trackerLink=page.locator('#btnVerTracker');
  await trackerLink.click();
  assert((await page.locator('#toast').innerText()).includes('1.17.8'),'Old agent update hint missing');
  for(const id of [123,456]){
    state.data.torrentWebUrl='https://tracker.test/torrents/'+id;
    await page.evaluate(s=>render(s),state);
    const [popup]=await Promise.all([page.context().waitForEvent('page'),trackerLink.click()]);
    await popup.waitForURL(state.data.torrentWebUrl);
    assert.equal(await popup.evaluate(()=>window.opener),null,'Tracker page retains access to panel');
    await popup.close();
  }
  for(const url of ['', 'javascript:alert(1)', 'https://tracker.test/torrent/download/123.secret',
    'https://tracker.test/torrents/123?passkey=secret', 'https://user:secret@tracker.test/torrents/123']){
    state.data.torrentWebUrl=url;
    await page.evaluate(s=>render(s),state);
    assert.equal(await trackerLink.getAttribute('href'),null,'Invalid/stale tracker link accepted');
    assert.equal(await trackerLink.getAttribute('aria-disabled'),'true');
  }
  state.data.torrentWebUrl='https://tracker.test/torrents/789';
  await page.evaluate(s=>render({...s,online:false}),state);
  assert.equal(await trackerLink.getAttribute('href'),null,'Disconnected panel retains stale link');
  assert.equal(pcCommands.length,0,'Ver sent a command to the PC');
  state.data.torrentWebUrl='';
  await page.evaluate(s=>{render(s);go('crear')},state);
  console.log('TRACKER_LINK_OK — local browser, active upload, no PC command, reset and URL validation.');
  const uploadState=structuredClone(state);
  uploadState.data.tareas=[{titulo:'Imágenes',fase:'Subiendo 2/20 · PIXHOST (intento 1/2)',pct:5}];
  await page.evaluate(s=>render(s),uploadState);
  assert((await page.locator('#auxProg').innerText()).includes('PIXHOST'),'Fallback provider/progress missing on mobile');
  const png=path.join(process.env.TEMP,'hdz_web_mobile_audit.png');await page.screenshot({path:png,fullPage:true});
  await page.setViewportSize({width:1280,height:850});await page.waitForTimeout(100);
  for(const width of [390,1280]){
    await page.setViewportSize({width,height:850});
    for(const suffix of ['', '  (3 en cola)']){
      const sample=structuredClone(state);
      sample.data.estado='✓  Montaje lanzado en segundo plano.'+suffix+' Pulsa «Mostrar consola» si el script pide algo.';
      await page.evaluate(s=>render(s),sample);
      assert(await page.locator('#estadoTxt').isHidden(),'Desktop-only console notice takes space at '+width);
      assert.equal(await page.locator('#estadoTxt').textContent(),'');
      assert(await page.locator('#prog').isVisible(),'Mount progress hidden with console notice');
      assert(await page.locator('#auxProg').isVisible(),'Torrent progress hidden with console notice');
    }
    for(const message of ['El montaje falló (código 1)', 'Error al Mostrar consola', 'Montaje terminado', 'Aviso: espacio insuficiente']){
      const sample=structuredClone(state);sample.data.estado=message;
      await page.evaluate(s=>render(s),sample);
      assert(await page.locator('#estadoSummary').isVisible(),'Important status summary hidden at '+width);
      assert.equal(await page.locator('#estadoTxt').textContent(),message);
    }
  }
  // Regression: the fixed dock must never hide the end of any page, even when
  // a long tracker reply, extra progress bars or a safe-area inset makes it grow.
  const layouts=[{width:320,height:640},{width:390,height:844},{width:573,height:900},
    {width:844,height:390},{width:390,height:430},{width:1280,height:850}];
  const messages=['',
    '✓ Subido. Torrent para sembrar disponible en el PC y en la web remota: [HDZ]Chompoo.La.Niña.Desaparecida.y.Olvidada.(2026).2160p.NF.WEB-DL.DD+.5.1.DV.HDR10.H.265-HDZ.torrent',
    ('Error al subir las capturas. Comprueba la conexión y vuelve a intentarlo. ').repeat(25)];
  for(const viewport of layouts){
    await page.setViewportSize(viewport);
    await page.evaluate(()=>document.documentElement.style.setProperty('--safe-b','34px'));
    for(const message of messages){
      state.data.estado=message;
      state.data.montaje.visible=!!message;
      state.data.tareas=message?[{titulo:'Torrent',fase:'Calculando piezas',pct:42},
        {titulo:'Imágenes',fase:'Subiendo capturas',pct:35}]:[];
      await page.evaluate(s=>render(s),state);
      for(const section of ['crear','torrent','ajustes']){
        await page.evaluate(section=>{
          go(section);
          const marker=document.createElement('div');
          marker.id='bottom-test-marker';marker.style.height='24px';marker.textContent='Fin del contenido';
          document.getElementById('sec-'+section).appendChild(marker);
        },section);
        await page.waitForTimeout(200); // Finish the section's 160 ms entrance animation.
        await page.evaluate(()=>window.scrollTo(0,document.documentElement.scrollHeight));
        const layout=await page.evaluate(()=>({
          marker:document.getElementById('bottom-test-marker').getBoundingClientRect().bottom,
          dock:document.querySelector('.dock').getBoundingClientRect().top,
          dockHeight:document.querySelector('.dock').getBoundingClientRect().height,
          padding:parseFloat(getComputedStyle(document.querySelector('main')).paddingBottom),
          cover:innerHeight-document.querySelector('.dock').getBoundingClientRect().top,
          overflow:document.documentElement.scrollWidth>innerWidth+1
        }));
        const label=viewport.width+'x'+viewport.height+' '+section+' message='+message.length;
        assert(layout.marker<=layout.dock-20,'End of content hidden by dock: '+label+' '+JSON.stringify(layout));
        assert(layout.padding>=layout.cover+21,'Dock height not reserved: '+label);
        assert(layout.dockHeight<=viewport.height/2+1,'Dock takes over the screen: '+label);
        assert(!layout.overflow,'Horizontal overflow: '+label);
        await page.locator('#bottom-test-marker').evaluate(el=>el.remove());
      }
    }
  }
  // Return to the screenshot scenario, showing the actual final subtitle controls.
  await page.setViewportSize({width:390,height:844});
  state.data.estado=messages[1];state.data.montaje.visible=false;state.data.tareas=[];
  await page.evaluate(s=>{render(s);go('crear');document.querySelectorAll('.grp').forEach(el=>el.classList.remove('closed'));},state);
  await page.waitForTimeout(100);
  await page.evaluate(()=>window.scrollTo(0,document.documentElement.scrollHeight));
  await page.screenshot({path:path.join(process.env.TEMP,'hdz_web_mobile_dock_fixed.png')});
  assert.deepEqual(errors,[],'Desktop JavaScript errors');
  console.log('DOCK_LAYOUT_OK — all 3 tabs, 6 viewports, long/empty notices, progress changes and safe area.');
  console.log('WEB_REGRESSION_OK — 390px/1280px, status, torrent progress, batch count, season list. Screenshot: '+png);
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
