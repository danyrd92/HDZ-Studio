const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>window.HDZ_TEST_NO_POLL=true);
  await page.route('**/*',r=>new URL(r.request().url()).pathname==='/'?r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8')}):r.fulfill({status:404,body:''}));
  await page.goto('http://hdz.fixture/');
  const result=await page.evaluate(async()=>{
   const options=[{v:'AUTO',t:'Automático'},{v:'eng',t:'Inglés'},{v:'spa',t:'Castellano'}];
   const d={session:'fixture',protocol:2,v:'fixture',uiTs:Date.now()/1000,interfaz:{schema:1,actions:{},credentials:{},remezcla:[]},opciones:{modoLote:'HOMOGENEO',origen:'WEB'},inputs:{},tmdbResults:[{id:'123',titulo:'Ficha de prueba',fecha:'2026'}],
     undAudioVisible:true,idiomasPistaOpciones:options,undAudioSubs:Array.from({length:40},(_,i)=>({tipo:'Audio',archivo:'fixture.mkv',id:i,etiqueta:'Pista '+i,valor:'AUTO'})),
     history:Array.from({length:20},(_,i)=>({id:'h'+i,status:'Terminado',date:'2026',video:'Fixture '+i,torrent:''})),
     pistasConversionAudio:[{v:'1',t:'Pista 1',destinos:[{v:'aac',t:'AAC'}]}],conversionesAudioVisible:true,conversionesAudio:[{Index:'1',Dest:'aac',MantenerOriginal:true}],
     lote:Array.from({length:60},(_,i)=>({nombre:'Fixture.S01E'+i+'.mkv',sel:true,badges:[{t:'HEVC',s:'gris'}]})),capturas:[],logos:[]};
   window.performanceFixture=d;render({online:true,responsive:true,data:d});go('crear');window.hdzWorkspaceSelect('audio');
   document.querySelector('#undAudioRows').closest('details').open=true;const select=document.querySelector('#undAudioRows select');select.focus();select.value='eng';
   let mutations=0;const observer=new MutationObserver(records=>mutations+=records.length);
   for(const id of ['historyResults','tmdbResults','seasonFolders','firmasList','undAudioRows','convAudioRows','remixPairs'])observer.observe(document.getElementById(id),{childList:true,subtree:true});
   const started=performance.now();for(let i=0;i<12;i++)render({online:true,responsive:true,data:{...d,uiTs:d.uiTs+i,montaje:{activo:true,pct:i}}});
   await Promise.resolve();observer.disconnect();
   return{ms:performance.now()-started,mutations,keptFocus:document.activeElement===select,keptNode:document.querySelector('#undAudioRows select')===select,keptValue:select.value==='eng'};
  });
  console.log('WEB_REFRESH_BASELINE',JSON.stringify(result));
  if(process.argv.includes('--baseline'))return;
  assert.equal(result.mutations,0,'Datos sin cambios vuelven a crear las listas');assert(result.keptFocus&&result.keptNode&&result.keptValue,'Refrescar progreso interrumpe una edición');
  await page.evaluate(()=>{document.activeElement.blur();render({online:true,responsive:true,data:{...performanceFixture,tmdbResults:[{},null,{id:'456',i:2,titulo:'Resultado nuevo',fecha:'2025'}]}})});
  assert.equal(await page.locator('#tmdbResults button').count(),1);assert.equal(await page.locator('#tmdbResults button').getAttribute('data-idx'),'2');assert((await page.locator('#tmdbResults').innerText()).includes('Resultado nuevo'));
  assert.deepEqual(errors,[]);console.log('WEB_RESPONSIVENESS_OK: stable nodes, focus and draft value during progress, valid indexed TMDB results.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
