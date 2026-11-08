// Contract tests with a minimal DOM double, no network or live PC mutations.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync(path.join(__dirname,'../../web/index.html'),'utf8');
for(const m of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))new vm.Script(m[1]);
const render=html.slice(html.indexOf('function renderLogos('),html.indexOf('/* ===== Explorador'));
const commands=html.slice(html.indexOf('function cmd(c)'),html.indexOf('async function getState()'));
const elements={cardLogos:{style:{}},logosBox:{innerHTML:''},logoPersonalizado:{value:'',disabled:false,title:''},btnUsarLogoPersonalizado:{disabled:false,title:''},btnActualizarLogos:{disabled:false,title:''},estadoTxt:{textContent:''}};
const sent=[];
const context={document:{getElementById:id=>elements[id]},esc:s=>String(s),crypto:{getRandomValues:a=>a.fill(171)}/* sin randomUUID: en http://IP-del-PC no existe */,
 remoteData:{session:'test-session',tabSubidaActual:2,busy:false,customLogo:true},remoteResponsive:true,
 commandPending:0,commandChain:Promise.resolve(),API:'https://test.invalid/api',AbortSignal,
 lock:{},subLock:0,getState:async()=>({}),render:()=>{},toast:msg=>{throw Error(msg)},
 fetch:async(url,opts)=>{if(opts?.method==='POST'){sent.push(JSON.parse(opts.body));return {ok:true,json:async()=>({id:'logo-command'})};}return {ok:true,json:async()=>({status:'done'})};}
};
vm.createContext(context);vm.runInContext('let lastLogos="";'+render+commands,context);
(async()=>{
 assert(html.includes('id="btnActualizarLogos" onclick="cmd({type:\'click\',name:\'btnActualizarLogos\'})"'));
 assert(html.includes('id="logoPersonalizado"')&&html.includes("type:'set_custom_logo'"));
 assert(html.includes('refreshLogos.disabled=!d.logoRefresh||!remoteResponsive||!!d.busy'));
 context.renderLogos([]);assert.notEqual(elements.cardLogos.style.display,'none');
 context.renderLogos([{url:'https://image.tmdb.org/t/p/original/logo.png',w:500,h:200,lang:'es',sel:true}]);
 assert(elements.logosBox.innerHTML.includes('logo on'));
 context.renderLogos([]);assert.equal(elements.logosBox.innerHTML,'');
 await context.cmd({type:'click',name:'btnActualizarLogos'});
 await context.cmd({type:'set_custom_logo',url:'https://image.tmdb.org/t/p/original/logo.png'});
 assert.equal(sent.length,2);assert.equal(sent[0].name,'btnActualizarLogos');
 assert.match(sent[0].requestId,/^[A-Za-z0-9_-]{16,80}$/);
 assert.equal(sent[0].session,'test-session');assert.equal(sent[0].subidaTab,2);
 assert.equal(sent[1].type,'set_custom_logo');assert.equal(sent[1].subidaTab,2);
 assert.equal(context.commandPending,0);
 console.log('WEB_LOGOS_OK: syntax, button, empty list, selection, session/tab guard and confirmation.');
})().catch(e=>{console.error(e);process.exitCode=1});
