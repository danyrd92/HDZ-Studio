// Local fixtures only. No connection to the PC, tracker or relay.
const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require(process.env.HDZ_PLAYWRIGHT||'playwright');
const html=fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844}});
  const commands=[],errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const folder='C:\\Vídeos & pruebas';
  const files=['Uno.mkv','Dos.mkv','Tres.mkv'].map(name=>({name,path:folder+'\\'+name}));
  const state={online:true,responsive:true,data:{session:'test',selectVideos:true,tabProyActual:0,carpeta:'',inputs:{},opciones:{},montaje:{},lote:[],tabsProy:[],tabsSubida:[]}};
  await page.route('**/*',async route=>{
   const u=new URL(route.request().url());
   if(u.pathname==='/')return route.fulfill({contentType:'text/html',body:html});
   if(u.pathname==='/api/state')return route.fulfill({json:state});
   if(u.pathname==='/api/cmd/status')return route.fulfill({json:{status:'done'}});
   if(u.pathname==='/api/cmd'){
    const c=route.request().postDataJSON();commands.push(c);
    if(c.type==='browse')state.data.browse=c.close?null:c.path?{path:folder,up:'',dirs:[],files}:{path:'',dirs:[{name:'Vídeos & pruebas',path:folder}],files:[]};
    if(c.type==='set_videos'){
     state.data.carpeta=folder;
     state.data.lote=files.map(f=>({nombre:f.name,sel:c.paths.includes(f.path)}));
    }
    return route.fulfill({json:{ok:true,id:'test-'+commands.length}});
   }
   return route.fulfill({status:404,body:''});
  });
  await page.goto('https://hdz-test.local/');
  await page.waitForFunction(()=>remoteResponsive);
  assert(await page.getByRole('heading',{name:'Fuentes',exact:true}).isVisible());
  const button=page.locator('#btnElegirVideosMovil');
  for(const width of [320,390,768]){
   await page.setViewportSize({width,height:844});
   assert(await button.isVisible(),'Mobile picker missing at '+width);
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1)),'Mobile overflow');
  }
  await page.setViewportSize({width:390,height:844});
  await button.click();
  await page.locator('#brBody .diritem').click();
  await page.locator('[data-mpath]').first().waitFor();
  await page.locator('#brUseBtn').click();
  assert((await page.locator('#toast').innerText()).includes('al menos'),'Empty selection accepted');
  await page.locator('[data-mpath]').nth(0).click();
  await page.locator('[data-mpath]').nth(2).click();
  await page.screenshot({path:path.join(process.env.TEMP,'hdz_mobile_file_picker.png')});
  await page.locator('#brUseBtn').click();
  await page.waitForFunction(()=>!browseOpen&&commandPending===0);
  const picks=commands.filter(c=>c.type==='set_videos');
  assert.equal(picks.length,1,'Selection split/duplicated');
  assert.deepEqual(picks[0].paths,[files[0].path,files[2].path]);
  assert.equal(picks[0].projectTab,0,'Project context missing');
  assert(!commands.some(c=>['set_carpeta','sel_todos','sel'].includes(c.type)),'Unsafe deferred selection used');
  assert.equal(await page.locator('#listado .cb.on').count(),2,'Wrong selected videos');
  // An older PC must never silently process the complete folder.
  delete state.data.selectVideos;
  await page.evaluate(s=>render(s),state);
  await button.click();await page.locator('#brBody .diritem').click();
  await page.locator('[data-mpath]').first().click();await page.locator('#brUseBtn').click();
  assert((await page.locator('#toast').innerText()).includes('1.17.10'),'Old agent not explained');
  assert.equal(commands.filter(c=>c.type==='set_videos').length,1,'Selection sent to unsupported agent');
  assert.deepEqual(errors,[]);
  console.log('WEB_FILE_PICKER_OK: mobile button, multiselect, exact paths, single command and old-agent guard.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
