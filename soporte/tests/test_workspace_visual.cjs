// Synthetic content only: no real processing, tracker access or uploads.
const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
const out=path.join(process.env.TEMP,'hdz-workspace');fs.mkdirSync(out,{recursive:true});
const opts=[{t:'Automático',v:'AUTO'},{t:'Castellano',v:'es'},{t:'Inglés',v:'en'}];
const state={online:true,responsive:true,data:{protocol:2,session:'visual-fixture',v:'1.17.26',equipo:'ESTUDIO',uiTs:Date.now()/1000,carpeta:'D:\\Series\\Horizonte\\Temporada 1',resumen:'3 vídeos · Temporada 1',logoRefresh:true,customLogo:true,inputs:{titulo:'Horizonte',ano:'2026',upTitulo:'Horizonte (2026) Temporada 1 · 2160p WEB-DL',upDescripcion:'[b]Horizonte[/b]\n\nTres episodios. Dos idiomas. Una historia.\n\n[center]Capturas del resultado[/center]'},switches:{serie:true},opciones:{modoLote:'HOMOGENEO',origen:'WEB',filtro:'TODOS',originales:'INTACTO',torrent:'PACK',capturasProy:'10'},lote:[1,2,3].map(n=>({nombre:`Horizonte.S01E0${n}.2160p.WEB-DL.mkv`,ep:`S01E0${n}`,sel:true,badges:[{t:'2160p'},{t:'HEVC'},{t:'Dolby Vision',s:'accent'},{t:'HDR10'},{t:'DD+ es · DD+ en'},{t:'4 subtítulos'}]})),tabsProy:[],tabsSubida:[],audioIdiomasVisible:true,audioIdiomas:[{t:'Castellano',v:'es',sel:true},{t:'Inglés',v:'en',sel:true},{t:'Francés',v:'fr',sel:false}],undAudioVisible:true,undSubsVisible:true,undAudioSubs:[{archivo:'D:\\Series\\Horizonte\\S01E01.mkv',id:'1',tipo:'Audio',etiqueta:'Pista 1 · Castellano · DD+ 5.1',valor:'AUTO',opciones:opts},{archivo:'D:\\Series\\Horizonte\\S01E01.mkv',id:'2',tipo:'Audio',etiqueta:'Pista 2 · Inglés · DD+ 5.1',valor:'AUTO',opciones:opts},{archivo:'D:\\Series\\Horizonte\\S01E01.mkv',id:'3',tipo:'Sub',etiqueta:'Pista 3 · Castellano · Completo',valor:'AUTO',opciones:opts}],torrentRuta:'D:\\Resultados\\Horizonte.S01.2160p.torrent',firmas:[],interfaz:{schema:1,sections:{modoLote:true,subFiltro:true},credentials:{cfgTrackerToken:true,cfgTmdbKey:true,cfgImgbbKey:true},actions:{iniciar:{enabled:true},subir:{enabled:true},send_log:{enabled:true}},salidas:{mkv:'D:\\Resultados\\Horizonte',torrent:'D:\\Torrents'},seleccion:'3 vídeos elegidos explícitamente',remezcla:[]}}};
(async()=>{const browser=await chromium.launch({channel:'msedge',headless:true});try{
 const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>window.HDZ_TEST_NO_POLL=true);
 await page.route('**/*',r=>{const u=new URL(r.request().url());if(u.pathname==='/')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8')});if(u.pathname.endsWith('logo.png'))return r.fulfill({contentType:'image/png',body:fs.readFileSync(path.join(__dirname,'../../hdz_logo_r.png'))});return r.fulfill({status:404,body:''})});
 for(const width of [320,390,768,1280,1920,2560]){
  await page.setViewportSize({width,height:width<768?844:1000});await page.goto('https://workspace-fixture.local/');await page.evaluate(s=>render(s),state);
  for(const stage of ['general','proyecto','audio','entrega']){
   await page.evaluate(()=>go('crear'));await page.locator('[data-stage="'+stage+'"]').click();
   assert.equal(await page.locator('.workspace-tab[aria-pressed=true]').count(),1);
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1)),`Overflow ${stage} ${width}`);
  }
  for(const section of ['torrent','ajustes']){await page.evaluate(s=>go(s),section);assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1)),`Overflow ${section} ${width}`)}
  if([390,1920].includes(width)){
   await page.evaluate(()=>{go('crear');toggleGrp('general')});await page.waitForTimeout(200);await page.screenshot({path:path.join(out,`fuentes-${width}.png`)});
   await page.locator('[data-stage=audio]').click();await page.waitForTimeout(200);await page.screenshot({path:path.join(out,`audio-${width}.png`)});
   await page.locator('[data-stage=entrega]').click();await page.waitForTimeout(200);await page.screenshot({path:path.join(out,`entrega-${width}.png`)});
   await page.evaluate(()=>go('torrent'));await page.waitForTimeout(200);await page.screenshot({path:path.join(out,`publicar-${width}.png`)});
  }
 }
 // A refresh must not change the inspector or clobber an active text edit.
 await page.evaluate(()=>{go('crear');toggleGrp('proyecto')});const field=page.locator('[data-in="titulo"]');await field.fill('Edición pendiente');await page.evaluate(s=>render(s),state);assert.equal(await field.inputValue(),'Edición pendiente');assert.equal(await page.locator('[data-stage=proyecto]').getAttribute('aria-pressed'),'true');
 assert.deepEqual(errors,[]);console.log('WORKSPACE_VISUAL_OK: four inspectors, populated fixtures, six viewport sizes, all screens and edit preservation. '+out);
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
