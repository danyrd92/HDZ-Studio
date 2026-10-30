// Presentation-only fixtures: all requests stay inside this browser test.
const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844}}),errors=[],commands=[];
  const state={online:true,responsive:true,data:{protocol:2,session:'layout',v:'fixture',uiTs:Date.now()/1000,inputs:{upDescripcion:'Primera línea\n\nSegunda línea'},opciones:{modoLote:'HOMOGENEO',origen:'WEB'},customLogo:true,logoRefresh:true,torrentRuta:'C:\\Fixture\\ultimo.torrent',tabsProy:[],tabsSubida:[],interfaz:{schema:1,sections:{modoLote:false,subFiltro:false},actions:{iniciar:{enabled:true},subir:{enabled:false},send_log:{enabled:true}},credentials:{cfgTrackerToken:true,cfgTmdbKey:true},salidas:{mkv:'C:\\Resultados',torrent:'C:\\Torrents'},seleccion:'Un vídeo concreto',remezcla:[]}}};
  page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
  await page.route('**/*',r=>{const u=new URL(r.request().url());if(u.pathname==='/')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8')});if(u.pathname==='/api/state')return r.fulfill({json:state});if(u.pathname==='/api/cmd/status')return r.fulfill({json:{status:'done'}});if(u.pathname==='/api/cmd'){commands.push(r.request().postDataJSON());return r.fulfill({json:{id:'fixture-'+commands.length}})}return r.fulfill({status:404,body:''})});
  await page.goto('https://interface-test.local/');await page.waitForFunction(()=>remoteResponsive);await page.evaluate(()=>window.HDZ_TEST_NO_POLL=true);
  assert(await page.locator('#grp-general .grpbody').isVisible(),'Entry section must start open');
  assert.equal(await page.locator('#sec-crear h1').innerText(),'Proyecto');assert.equal(await page.locator('#workOverview .metric').count(),3);
  assert(await page.locator('#workOverview').isHidden(),'Duplicated overview still consumes space');assert.equal(await page.locator('#sec-crear h1').evaluate(el=>getComputedStyle(el).fontSize),'24px');
  assert.equal(await page.locator('.workspace-tab').count(),4);
  for(const stage of ['general','proyecto','audio','entrega']){await page.locator('[data-stage="'+stage+'"]').click();assert.equal(await page.locator('#sec-crear>.workspace-active').count(),1);assert.equal(await page.locator('[data-stage="'+stage+'"]').getAttribute('aria-pressed'),'true');}
  assert.deepEqual(await page.locator('#grp-audio>.grpbody>h3').allTextContents(),['Audio','Subtítulos']);
  assert.deepEqual(await page.locator('#grp-entrega>.grpbody>h3').allTextContents(),['Entrega','Salida y originales']);
  for(const mode of ['NO','INDIVIDUAL','PACK','AMBOS','NO']){await page.evaluate(mode=>{render({online:true,responsive:true,data:{...remoteData,opciones:{...remoteData.opciones,torrent:mode}}})},mode);assert.equal(await page.locator('[data-in="salidaTorrent"]').isVisible(),mode!=='NO');}
  await page.locator('[data-stage="general"]').click();
  assert.equal(await page.locator('.settingsjumps button').count(),5);assert.equal(await page.locator('.settingsgrid [data-in="cfgTrackerToken"]').count(),1);
  assert.equal(await page.locator('.dock #btnUploadWeb').count(),1,'Upload action is not in the global dock');
  assert.equal(await page.locator('[data-sw="proyecto"]').count(),0);assert.equal(await page.locator('[data-sw="aplicarTodos"]').count(),0);
  assert.equal(await page.locator('.grphd .hdzicon').count(),7,'Not all headers have the shared outline icon');
  assert.equal(await page.locator('.bbmore').count(),1,'Advanced editor formats are not grouped');
  await page.evaluate(()=>go('torrent'));await page.locator('.bbmore summary').click();assert(await page.getByRole('button',{name:'Tabla',exact:true}).isVisible());await page.locator('.bbmore summary').click();await page.evaluate(()=>go('crear'));
  const headerStyles=await page.locator('#sec-crear .grphd').evaluateAll(headers=>headers.map(h=>{const s=getComputedStyle(h);return[s.borderRadius,s.backgroundColor,s.padding].join('|')}));assert.equal(new Set(headerStyles).size,1,'New headers differ from existing headers');
  assert(await page.locator('#cardModoLoteWeb').isHidden());assert(await page.locator('#cardSubFilterWeb').isHidden());
  for(const section of ['crear','torrent','ajustes']){
   await page.evaluate(s=>go(s),section);
   assert.equal(await page.locator('#btnIni').isVisible(),section==='crear');
   assert.equal(await page.locator('#btnUploadWeb').isVisible(),section==='torrent');
  }
  await page.locator('#btnSendLogWeb').click();await page.waitForFunction(()=>commandPending===0);
  assert(commands.some(c=>c.type==='send_log'&&c.confirmed));
  assert((await page.locator('[data-credential="cfgTrackerToken"]').innerText()).includes('Configurada'));
  const secret=page.locator('[data-in="cfgTrackerToken"]');await secret.focus();await secret.blur();await page.waitForTimeout(100);
  assert(!commands.some(c=>c.type==='set_input'&&c.name==='cfgTrackerToken'),'Empty masked field overwrites key');
  await page.evaluate(()=>go('torrent'));assert(await page.locator('#btnUploadWeb').isDisabled());
  assert((await page.locator('#loadedTorrent').innerText()).endsWith('ultimo.torrent'));
  assert.equal(await page.locator('[data-combo="numCapturas"]').count(),1);
  assert(await page.locator('#grp-recursos #capsBox').count()===1);
  const input=page.locator('[data-in="upDescripcion"]');await input.fill('[b]Título[/b]\n\n<img src=x onerror=alert(1)>\n[img=350]javascript:alert(1)[/img]');
  await page.locator('#btnDescriptionPreview').click();
  assert.equal(await page.locator('#descriptionPreview strong').innerText(),'Título');
  assert.equal(await page.locator('#descriptionPreview img').count(),0,'Unsafe image rendered');
  assert((await page.locator('#descriptionPreview').innerText()).includes('<img src=x'));
  await page.locator('#btnDescriptionPreview').click();
  assert((await input.inputValue()).includes('\n\n'),'Preview changes manual newlines');
  for(const viewport of [{width:320,height:640},{width:390,height:844},{width:844,height:390},{width:768,height:1024},{width:1280,height:850},{width:2560,height:1100}]){
   await page.setViewportSize(viewport);
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1)),'Layout overflows');
   const width=await page.locator('#logoPersonalizado').evaluate(e=>e.getBoundingClientRect().width);assert(width>=180,'Custom logo URL too narrow');
   if(viewport.width>=1280)assert((await page.locator('main').boundingBox()).width>=viewport.width-270,'Content does not fill available desktop width');
  }
  state.data.busy=true;await page.evaluate(s=>render(s),state);assert(await page.locator('#btnUploadWeb').isDisabled());
  await page.evaluate(s=>render({...s,online:false}),state);assert(await page.locator('#btnIni').isDisabled());
  delete state.data.interfaz;state.data.busy=false;await page.evaluate(s=>render(s),state);await page.evaluate(()=>go('ajustes'));assert(await page.locator('#btnSendLogWeb').isDisabled(),'Legacy agent accepts unsupported support command');
  assert.deepEqual(errors,[]);
  await page.setViewportSize({width:390,height:844});await page.evaluate(()=>go('torrent'));await page.waitForTimeout(250);await page.screenshot({path:path.join(process.env.TEMP,'hdz_interface_mobile.png'),fullPage:true});
  console.log('WEB_INTERFACE_OK: navigation, capabilities, credentials, support confirmation, safe BBCode, newlines, mobile widths and legacy compatibility.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
