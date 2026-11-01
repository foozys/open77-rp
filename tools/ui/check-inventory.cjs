// Actual inventory HTML + mocked Open77 messages. No server, accounts or live items.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '../..');
const webRoot = path.join(root, 'resources/rp/rp_inventory_ui/web');
const out = path.resolve(process.env.INVENTORY_CHECK_OUTPUT || path.join(root, 'output/inventory-check'));
const current = fs.readFileSync(path.join(webRoot, 'index.html'), 'utf8');
const baseline = fs.readFileSync(process.env.UI_BASELINE_HTML || path.join(webRoot, 'index.html'), 'utf8');
const upstream = execFileSync('git', ['show', 'HEAD:resources/rp/rp_inventory_ui/web/index.html'], { cwd: root, encoding: 'utf8' });
const dragCode = html => html.slice(html.indexOf('  function startDrag('), html.indexOf('  function closeMenu(')).replace(/\r\n/g,'\n');
assert.equal(dragCode(current), dragCode(upstream), 'Inventory drag/drop rules must remain unchanged');
const item = (label,w,h,extra={}) => ({label,w,h,weightG:100,stack:1,color:'#507780',...extra});
const catalog = {
  qh_short_circuit:item('Скрипт: короткое замыкание',1,1,{stack:5}),
  target_shard:item('Досье цели',1,1,{usable:true,useLabel:'Прочитать досье'}),
  water:item('Бутылка воды',1,2,{usable:true,belt:true}),
  wpn_copperhead:item('Штурмовая винтовка Copperhead (5,56)',4,2,{weapon:true}),
  wpn_katana:item('Катана',1,4,{weapon:true,melee:true}),
  ammo_556:item('Патроны 5,56 мм',1,1,{belt:true,stack:60}),
  medkit:item('Аптечка',2,2,{usable:true}),
  implant_kiroshi:item('Имплант: оптика Kiroshi',1,1),
  sandwich:item('Сэндвич',1,1,{usable:true,belt:true})
};
const state = {cols:10,rows:6,weightG:5600,capacityG:30000,nearby:[{id:42,name:'Тестовый персонаж'}],catalog,stacks:[
  {i:'qh_short_circuit',n:3,x:1,y:1}, {i:'target_shard',n:1,x:2,y:1},
  {i:'water',n:1,x:8,y:1}, {i:'wpn_copperhead',n:1,x:7,y:5,wr:0},
  {i:'wpn_katana',n:1,c:'w1'}, {i:'ammo_556',n:40,c:'b1'},
  {i:'medkit',n:1,x:1,y:4}, {i:'implant_kiroshi',n:1,x:4,y:1}
]};
const cyber = {humanity:77,humanityMax:100,threshold:50,psychosis:0,episodeFrom:40,severeFrom:75,
  slots:[['eyes','Оптика'],['os','Операционная система'],['arms','Руки'],['skeleton','Скелет'],['tendons','Сухожилия'],['skin','Кожа'],['heart','Сердце'],['blood','Кровь'],['metabolism','Метаболизм'],['ice','Защита (ICE)'],['purge','Очистка'],['legs','Ноги']].map(([id,label])=>({id,label,implant:id==='eyes'?{id:'implant_kiroshi',label:'Имплант: Оптика Kiroshi',humanity:3,description:'Сканер: удерживайте TAB.'}:id==='os'?{id:'implant_deck_pro',label:'Имплант: Кибердека Netwatch',humanity:20,description:'5 слотов скриптов, 12 RAM.'}:null})),
  deck:{label:'Имплант: Кибердека Netwatch',size:5,ram:12,kiroshi:true,scripts:[],pocket:[]}};
const mime={'.html':'text/html; charset=utf-8','.css':'text/css','.png':'image/png','.svg':'image/svg+xml'};
const server=http.createServer((req,res)=>{
  const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
  if(pathname==='/baseline.html'){res.setHeader('Content-Type',mime['.html']);res.end(baseline);return;}
  const file=path.resolve(webRoot,'.'+(pathname==='/'?'/index.html':pathname));
  if(!file.startsWith(webRoot+path.sep)||!mime[path.extname(file)]||!fs.existsSync(file)){res.writeHead(404).end();return;}
  res.setHeader('Content-Type',mime[path.extname(file)]);res.end(fs.readFileSync(file));
});
const clone = value => structuredClone(value);
const send=(page,name,payload)=>page.evaluate(({name,payload})=>window.__deliver(name,payload),{name,payload});
const clear=page=>page.evaluate(()=>{window.__emitted=[];});
const events=page=>page.evaluate(()=>window.__emitted);
async function settle(page){await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));}
async function load(page,url){await page.goto(url);await send(page,'inv:state',clone(state));await send(page,'inv:cyber',clone(cyber));await send(page,'inv:open');await page.mouse.move(0,0);await settle(page);}
async function cell(page,x,y,id='grid') {return page.locator('#'+id).evaluate((el,{x,y})=>{const r=el.getBoundingClientRect();return {x:r.left+(x-.5)*76,y:r.top+(y-.5)*76};},{x,y});}
async function start(page,x,y,id='grid'){const p=await cell(page,x,y,id);await page.mouse.move(p.x,p.y);await page.mouse.down();}
async function finish(page,x,y,id='grid'){const p=await cell(page,x,y,id);await page.mouse.move(p.x,p.y,{steps:4});await page.mouse.up();}
async function assertPopup(page,selector){assert.deepEqual(await page.locator(selector).evaluate(el=>{const r=el.getBoundingClientRect();return [r.left>=0,r.top>=0,r.right<=innerWidth,r.bottom<=innerHeight];}),[true,true,true,true]);}
(async()=>{
  fs.mkdirSync(out,{recursive:true});fs.rmSync(path.join(out,'result.json'),{force:true});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  const browser=await chromium.launch({channel:process.env.BROWSER_CHANNEL||'chrome',headless:true});
  const errors=[];
  try {
    const context=await browser.newContext({viewport:{width:1920,height:1080},deviceScaleFactor:1});
    await context.addInitScript(()=>{const handlers={};window.__emitted=[];window.__deliver=(name,payload)=>(handlers[name]||[]).forEach(fn=>fn(payload));window.Open77={on:(name,fn)=>(handlers[name]||=[]).push(fn),emit:(name,payload)=>window.__emitted.push({name,payload}),ready:()=>{}};});
    const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
    page.on('response',response=>{if(response.status()>=400)errors.push(`${response.status()} ${response.url()}`);});
    for(const [width,height] of [[1920,1080],[2560,1440],[1600,900],[1366,768],[1280,720],[2560,1080]]){
      await page.setViewportSize({width,height});await load(page,base);
      assert.equal(await page.locator('#gridSize').textContent(),'10 × 6');
      assert.equal(await page.locator('#grid').evaluate(el=>el.getBoundingClientRect().width),761);
      const problems=await page.evaluate(()=>{
        const errors=[];const viewport=document.querySelector('#grids').getBoundingClientRect();
        for(const el of document.querySelectorAll('#grid, #gearBox [data-target]')){
          const r=el.getBoundingClientRect();
          if(r.left<viewport.left||r.right>viewport.right+1||r.top<viewport.top||r.bottom>viewport.bottom+1)errors.push(el.id||el.dataset.target);
        }
        for(const el of document.querySelectorAll('#grid .item')){const r=el.getBoundingClientRect();if(!el.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)))errors.push('item obscured');}
        return errors;
      });assert.deepEqual(problems,[],`layout ${width}x${height}`);
      await page.screenshot({path:path.join(out,`inventory-${width}x${height}.png`),animations:'disabled'});
      // Verify the real geometry calculation at each viewport, including return from implants.
      await page.locator('[data-tab="cyber"]').click();await page.locator('[data-tab="inv"]').click();
      await clear(page);await start(page,8,1);await finish(page,5,2);
      assert.deepEqual((await events(page)).at(-1),{name:'inv:move',payload:{index:3,item:'water',a:5,b:2,c:false}});
      console.log(`PASS inventory ${width}x${height}: cells, gear, pointer mapping, tab round trip`);
    }
    await page.setViewportSize({width:1920,height:1080});await load(page,base);
    await clear(page);await start(page,8,1);await page.keyboard.press('r');await finish(page,5,2);
    assert.deepEqual((await events(page)).at(-1),{name:'inv:move',payload:{index:3,item:'water',a:5,b:2,c:true}});
    await clear(page);await start(page,8,1);const occupied=await cell(page,1,1);await page.mouse.move(occupied.x,occupied.y);
    assert(await page.locator('#ghost').evaluate(el=>el.classList.contains('bad')));await page.mouse.up();
    await clear(page);await start(page,7,5);const weapon=await page.locator('[data-target="w2"]').boundingBox();
    await page.mouse.move(weapon.x+weapon.width/2,weapon.y+weapon.height/2);await page.mouse.up();
    assert.deepEqual((await events(page)).at(-1),{name:'inv:gear',payload:{index:4,item:'wpn_copperhead',target:'w2'}});
    await clear(page);await start(page,8,1);const belt=await page.locator('[data-target="b2"]').boundingBox();
    await page.mouse.move(belt.x+belt.width/2,belt.y+belt.height/2);await page.mouse.up();
    assert.deepEqual((await events(page)).at(-1),{name:'inv:gear',payload:{index:3,item:'water',target:'b2'}});
    await clear(page);const equipped=await page.locator('[data-target="w1"]').boundingBox();
    await page.mouse.move(equipped.x+30,equipped.y+30);await page.mouse.down();await finish(page,5,2);
    assert.deepEqual((await events(page)).at(-1),{name:'inv:gear',payload:{index:5,item:'wpn_katana',target:'grid',a:5,b:2,c:false}});
    const first=await cell(page,1,1);await page.mouse.click(first.x,first.y,{button:'right'});await assertPopup(page,'#menu');
    await page.screenshot({path:path.join(out,'inventory-context-menu.png'),animations:'disabled'});
    await page.getByRole('button',{name:'Разделить',exact:true}).click();await page.locator('#dialogInput').fill('1');
    await clear(page);await page.locator('#dialogOk').click();assert.deepEqual((await events(page)).at(-1),{name:'inv:split',payload:{index:1,item:'qh_short_circuit',a:1}});
    await page.mouse.click(first.x,first.y,{button:'right'});await page.getByRole('button',{name:'Тестовый персонаж [42]',exact:true}).click();
    await page.locator('#dialogInput').fill('2');await clear(page);await page.locator('#dialogOk').click();
    assert.deepEqual((await events(page)).at(-1),{name:'inv:give',payload:{index:1,item:'qh_short_circuit',a:2,b:42}});
    const water=await cell(page,8,1);await page.mouse.click(water.x,water.y,{button:'right'});await clear(page);await page.getByRole('button',{name:'Использовать',exact:true}).click();
    assert.deepEqual((await events(page)).at(-1),{name:'inv:use',payload:{index:3,item:'water'}});
    await page.mouse.click(water.x,water.y,{button:'right'});await clear(page);await page.getByRole('button',{name:'Выбросить',exact:true}).click();
    assert.deepEqual((await events(page)).at(-1),{name:'inv:drop',payload:{index:3,item:'water',a:1}});
    console.log('PASS rotate, collision highlight, equip, belt, unequip, context use/split/give/drop');

    const lootState=clone(state);lootState.loot={name:'Тестовый персонаж',target:42,started:false,done:false,stacks:[{hidden:true,x:1,y:1,w:2,h:2}]};
    await send(page,'inv:state',lootState);assert.equal(await page.locator('#lootGrid .item.hidden').count(),1);
    assert.equal(await page.locator('#lootGrid .itemArt').count(),0);
    await clear(page);await page.locator('#lootSearch').click();assert.deepEqual((await events(page)).at(-1),{name:'inv:lootSearch',payload:{}});
    lootState.loot={name:'Тестовый персонаж',target:42,started:true,done:true,stacks:[{i:'sandwich',n:1,x:1,y:1},{i:'wpn_katana',n:1,c:'w1'}]};
    await send(page,'inv:state',lootState);await page.mouse.move(0,0);await settle(page);
    await page.screenshot({path:path.join(out,'inventory-loot-1920x1080.png'),animations:'disabled'});
    await clear(page);await start(page,1,1,'lootGrid');await finish(page,5,2);
    assert.deepEqual((await events(page)).at(-1),{name:'inv:loot',payload:{from:'loot',index:1,item:'sandwich',a:5,b:2,c:false}});
    await clear(page);await start(page,8,1);await finish(page,3,1,'lootGrid');
    assert.deepEqual((await events(page)).at(-1),{name:'inv:loot',payload:{from:'mine',index:3,item:'water',a:3,b:1,c:false}});
    // Scroll the stacked search view while dragging; coordinates must remain cell-based.
    await page.setViewportSize({width:1280,height:720});await send(page,'inv:state',clone(lootState));
    await page.locator('#grids').evaluate(el=>{el.scrollTop=0;});await start(page,8,1);
    await page.locator('#lootGrid').scrollIntoViewIfNeeded();await finish(page,3,1,'lootGrid');
    assert.deepEqual((await events(page)).at(-1),{name:'inv:loot',payload:{from:'mine',index:3,item:'water',a:3,b:1,c:false}});
    await page.screenshot({path:path.join(out,'inventory-loot-1280x720.png'),animations:'disabled'});
    console.log('PASS hidden search items, search command, bidirectional looting, drag after scroll');

    await load(page,base);const overflow=clone(state);overflow.stacks.push({i:'medkit',n:1});overflow.weightG=31000;
    await send(page,'inv:state',overflow);await page.locator('#overflowList .item').scrollIntoViewIfNeeded();
    assert(await page.locator('#overflow').isVisible());assert.equal(await page.locator('#weightText').textContent(),'31.0 / 30.0 кг');
    await page.locator('#overflowList .item').hover();await assertPopup(page,'#tooltip');
    await page.locator('#overflowList .item').click({button:'right'});await assertPopup(page,'#menu');
    await send(page,'inv:state',{...clone(state),stacks:[]});assert.equal(await page.locator('#grid .item').count(),0);
    await send(page,'inv:close');assert(!(await page.locator('#menu').isVisible()));assert(!(await page.locator('#tooltip').isVisible()));
    await send(page,'inv:open');await clear(page);await page.keyboard.press('i');assert.equal((await events(page)).at(-1).name,'inv:close');

    if(process.env.UI_BASELINE_HTML){
      for(const [width,height] of [[1920,1080],[1280,720]]){
        await page.setViewportSize({width,height});await load(page,`${base}/baseline.html`);await page.locator('[data-tab="cyber"]').click();await page.mouse.move(0,0);
        const before=await page.screenshot({animations:'disabled'});
        await load(page,base);await page.locator('[data-tab="cyber"]').click();await page.mouse.move(0,0);
        assert(before.equals(await page.screenshot({animations:'disabled'})),`Implants visual regression ${width}x${height}`);
      }
      console.log('PASS implants screenshots identical to pre-inventory snapshot');
    }
    assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'result.json'),JSON.stringify({passed:true,resolutions:6,cellSize:76,dragRulesUnchanged:true,implantsCompared:!!process.env.UI_BASELINE_HTML,errors},null,2));
    console.log(`PASS all inventory checks. Screenshots: ${out}`);
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
