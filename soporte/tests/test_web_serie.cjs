// Serie (episodios) en la web: misma pestaña única que en el PC (lista de episodios, capturas por
// episodio, subir todos, abrir todos, descargas) y nombres de los modos de torrent en series.
const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
(async()=>{const browser=await chromium.launch({channel:'msedge',headless:true});try{
 const page=await browser.newPage(),commands=[],errors=[];page.on('pageerror',e=>errors.push(e.message));await page.addInitScript(()=>window.HDZ_TEST_NO_POLL=true);
 const id='a'.repeat(64);
 const eps=[1,2,3].map(n=>({i:n-1,ep:'S01E0'+n,titulo:'Serie (2022) S01E0'+n+' 1080p NF WEB-DL DD+ 5.1 H.264-HDZ',estado:n===1?'subido':'pendiente',error:'',urlWeb:n===1?'https://tracker.invalid/torrents/1':'',descarga:{disponible:n===1,id:n===1?id:'',nombre:n===1?'E01.torrent':''}}));
 const caps=[];let ci=0;for(const e of eps)for(const k of [1,2])caps.push({i:ci++,nombre:e.ep+'_cap_'+k+'.png',sel:k===1,thumb:'',subida:'',ep:e.ep});
 const state={online:true,responsive:true,data:{session:'fixture',inputs:{},opciones:{torrent:'INDIVIDUAL'},esSerieProyecto:true,capturas:caps,capturasVisible:true,
   serie:{activa:true,titulo:'Serie (2022) S01',total:3,subidos:1,subiendo:false,abribles:1,episodios:eps}}};
 await page.route('**/*',r=>{const u=new URL(r.request().url());if(u.pathname==='/')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8')});if(u.pathname==='/api/cmd'){commands.push(r.request().postDataJSON());return r.fulfill({json:{id:'serie-fixture'}})}if(u.pathname==='/api/cmd/status')return r.fulfill({json:{status:'done'}});return r.fulfill({status:404,body:''})});
 await page.goto('https://serie.local/');await page.evaluate(s=>{render(s);go('torrent')},state);
 assert(await page.locator('#cardSerieWeb').isVisible(),'Falta la tarjeta de episodios');
 assert.equal(await page.locator('#serieRows .epTitulo').count(),3);
 assert(await page.locator('#serieRows .epTitulo').first().isDisabled(),'Un episodio subido no debe poder editarse');
 assert.equal(await page.locator('#serieCount').textContent(),'1 de 3 subidos');
 assert(await page.locator('#rowTituloWeb').isHidden()&&await page.locator('#rowMediainfoWeb').isHidden()&&await page.locator('#rowTempEpWeb').isHidden(),'Se ven campos de una subida suelta');
 assert.match(await page.locator('#btnUploadWeb').textContent(),/Subir los que faltan/);
 assert.deepEqual(await page.locator('#capsBox .capep').allTextContents(),['S01E01','S01E02','S01E03']);
 assert.equal(await page.locator('#serieRows a[data-dl]').count(),1);
 // Editar el título de un episodio pendiente
 await page.locator('#serieRows .epTitulo').nth(1).fill('Título corregido');await page.waitForTimeout(700);
 assert(commands.some(c=>c.type==='set_ep_titulo'&&c.idx===1&&c.value==='Título corregido'),'No se envía el título');
 await page.locator('#btnUploadWeb').click();await page.locator('#btnAbrirTodosWeb').click();await page.waitForTimeout(100);
 assert(commands.some(c=>c.type==='subir')&&commands.some(c=>c.type==='abrir_todos'),'Faltan subir/abrir todos');
 // Chips de torrent con nombre de serie
 await page.evaluate(()=>go('crear'));
 assert.equal(await page.locator('[data-group="torrent"] .chip[data-v="INDIVIDUAL"]').textContent(),'Serie (episodios)');
 // Sin serie: todo vuelve a la subida suelta
 await page.evaluate(([s,cs])=>{lastSerie='';render({...s,data:{...s.data,esSerieProyecto:false,serie:{activa:false},capturas:cs.map(c=>({...c,ep:''}))}});go('torrent')},[state,caps]);
 assert(await page.locator('#cardSerieWeb').isHidden()&&await page.locator('#rowTituloWeb').isVisible(),'La vista de serie no se retira');
 assert.equal(await page.locator('#btnUploadWeb').textContent(),'⬆ Subir al tracker');
 for(const width of [320,390,768,1920]){await page.setViewportSize({width,height:850});assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1)),'Scroll horizontal a '+width)}
 assert.deepEqual(errors,[]);console.log('WEB_SERIE_OK: episodios, capturas por episodio, títulos, subir/abrir todos, descargas, chips y anchos');
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
