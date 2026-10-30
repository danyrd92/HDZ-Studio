const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
(async()=>{const browser=await chromium.launch({channel:'msedge',headless:true});try{
 const page=await browser.newPage(),commands=[],errors=[];page.on('pageerror',e=>errors.push(e.message));await page.addInitScript(()=>window.HDZ_TEST_NO_POLL=true);
 const state={online:true,responsive:true,data:{session:'fixture',inputs:{},opciones:{},audioTracksSupported:true,tabProyActual:3,audioTracks:[1,2].map(id=>({archivo:'C:\\Videos\\Título muy largo '+('prueba '.repeat(15))+'.mkv',id,index:id,etiqueta:'Título '+('largo '.repeat(15))+' · Castellano · '+(id===1?'DD+ 5.1':'DTS 5.1'),sel:true}))}};
 await page.route('**/*',r=>{const u=new URL(r.request().url());if(u.pathname==='/')return r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8')});if(u.pathname==='/api/cmd'){commands.push(r.request().postDataJSON());return r.fulfill({json:{id:'track-fixture'}})}if(u.pathname==='/api/cmd/status')return r.fulfill({json:{status:'done'}});return r.fulfill({status:404,body:''})});
 await page.goto('https://audio-tracks.local/');await page.evaluate(s=>{render(s);go('crear');toggleGrp('audio')},state);
 assert.equal(await page.locator('#audioTrackRows input').count(),2);
 await page.locator('#audioTrackRows input').nth(1).uncheck();await page.waitForTimeout(100);
 assert(commands.some(c=>c.type==='set_audio_track'&&c.id===2&&c.value===false&&c.projectTab===3));
 assert(await page.locator('#audioTrackRows input').first().isChecked());
 await page.evaluate(s=>render(s),state);assert(!(await page.locator('#audioTrackRows input').nth(1).isChecked()),'Refresh overwrites edit');
 for(const width of [320,390,768,1920]){await page.setViewportSize({width,height:850});assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1)))}
 await page.evaluate(s=>{audioTracksLock=0;render({...s,data:{...s.data,audioTracksSupported:false}})},state);assert(await page.locator('#cardAudioTracksWeb').isHidden());
 assert.deepEqual(errors,[]);console.log('WEB_AUDIO_TRACKS_OK: exact track, same language, project context, refresh lock, widths and legacy agent');
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
