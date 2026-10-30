// Synthetic update state only. Does not start any installer or contact the real PC.
const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844}});
  const state={online:true,responsive:true,data:{session:'update-test',equipo:'DANIEL',v:'1.17.10',uiTs:Date.now()/1000,inputs:{},opciones:{},montaje:{},lote:[],tabsProy:[],tabsSubida:[]}};
  const errors=[],commands=[];page.on('pageerror',e=>errors.push(e.message));
  page.on('dialog',d=>d.accept());
  await page.route('**/*',route=>{
   const u=new URL(route.request().url());
   if(u.pathname==='/')return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8')});
   if(u.pathname==='/api/state')return route.fulfill({json:state});
   if(u.pathname==='/api/cmd/status')return route.fulfill({json:{status:'done'}});
   if(u.pathname==='/api/cmd'){
    commands.push(route.request().postDataJSON());
    state.data.update.requested=true;state.data.update.canInstall=false;
    return route.fulfill({json:{ok:true,id:'update-1'}});
   }
   return route.fulfill({status:404,body:''});
  });
  await page.goto('https://hdz-test.local/');await page.waitForFunction(()=>remoteResponsive);
  for(const width of [320,390,573,1280]){
   await page.setViewportSize({width,height:844});
   const id=width>=920?'btnActualizarSide':'btnActualizarWeb';
   const version=width>=920?'whoSide':'versionWeb';
   const button=page.locator('#'+id);
   for(const update of [undefined,{available:false,canInstall:false,version:''}]){
    state.data.update=update;await page.evaluate(s=>render(s),state);
    assert(await button.isHidden(),'Button visible without confirmed update');
   }
   state.data.update={available:true,canInstall:true,version:'1.17.11'};
   await page.evaluate(s=>render(s),state);
   assert(await button.isVisible());assert(await button.isEnabled());
   const b=await button.boundingBox(),v=await page.locator('#'+version).boundingBox();
   assert(b.x>=v.x+v.width-1,'Update button is not to the right of version');
   assert(Math.abs((b.y+b.height/2)-(v.y+v.height/2))<3,'Version/update not aligned');
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1)),'Update button overflows mobile header');
   state.data.update.canInstall=false;await page.evaluate(s=>render(s),state);
   assert(await button.isVisible());assert(await button.isDisabled(),'Busy PC can be updated');
   await page.evaluate(s=>render({...s,online:false}),state);assert(await button.isHidden());
  }
  await page.setViewportSize({width:390,height:844});
  state.data.update={available:true,canInstall:true,version:'1.17.11'};await page.evaluate(s=>render(s),state);
  await page.screenshot({path:path.join(process.env.TEMP,'hdz_update_button_mobile.png')});
  await page.locator('#btnActualizarWeb').click();
  await page.waitForFunction(()=>commandPending===0&&remoteData.update.requested);
  assert.equal(commands.length,1);assert.equal(commands[0].type,'actualizar');
  assert.equal(commands[0].session,'update-test');assert(await page.locator('#btnActualizarWeb').isDisabled());
  assert.deepEqual(errors,[]);
  console.log('WEB_UPDATE_OK: hidden without new version, right-hand position, busy/offline guard and remote update command.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
