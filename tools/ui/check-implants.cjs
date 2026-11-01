// Browser smoke test with a mocked Open77 transport. Never contacts the game server.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '../..');
const webRoot = path.join(root, 'resources/rp/rp_inventory_ui/web');
const out = path.resolve(process.env.UI_CHECK_OUTPUT || path.join(root, 'output/implants-check'));
const html = fs.readFileSync(path.join(webRoot, 'index.html'), 'utf8');
const baseline = execFileSync('git', ['show', 'HEAD:resources/rp/rp_inventory_ui/web/index.html'], { cwd: root, encoding: 'utf8' });
for (const script of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
const eventNames = text => [...text.matchAll(/Open77\.on\("([^"]+)"/g)].map(m => m[1]).sort();
assert.deepEqual(eventNames(html), eventNames(baseline), 'Existing game listeners must remain');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
assert.equal(new Set(ids).size, ids.length, 'Static DOM IDs must be unique');
const manifest = fs.readFileSync(path.join(webRoot, '../open77.lua'), 'utf8');
for (const asset of ['implants.css', 'inventory.css', 'assets/implants/body-v1.png', 'assets/implants/icons-v1.png']) {
  assert(manifest.includes(`"web/${asset}"`), `Asset missing from manifest: ${asset}`);
  assert(fs.statSync(path.join(webRoot, asset)).size > 0);
}
const slotDefs = [['eyes','Оптика'],['os','Операционная система'],['arms','Руки'],['skeleton','Скелет'],['tendons','Сухожилия'],['skin','Кожа'],['heart','Сердце'],['blood','Кровь'],['metabolism','Метаболизм'],['ice','Защита (ICE)'],['purge','Очистка'],['legs','Ноги']];
const scriptA = { id: 'qh_short', label: 'Скрипт: Короткое замыкание', description: 'Наносит электрический урон.', ram: 3 };
const scriptB = { id: 'qh_breach', label: 'Скрипт: Взлом данных', description: 'Временно раскрывает сведения о цели.', ram: 2, count: 1 };
const cyber = {
  humanity: 77, humanityMax: 100, threshold: 50, psychosis: 0, episodeFrom: 40, severeFrom: 75,
  slots: slotDefs.map(([id, label]) => ({ id, label, implant: id === 'eyes'
    ? { id: 'implant_kiroshi', label: 'Имплант: Оптика Kiroshi', humanity: 3, description: 'Сканер: удерживайте TAB.' }
    : id === 'os' ? { id: 'implant_deck_pro', label: 'Имплант: Кибердека Netwatch', humanity: 20, description: '5 слотов скриптов, 12 RAM. Повышенная скорость восстановления RAM.' } : null })),
  deck: { label: 'Имплант: Кибердека Netwatch', size: 5, ram: 12, kiroshi: true, scripts: [scriptA], pocket: [scriptA, scriptB] }
};
const inventory = { cols: 10, rows: 6, weightG: 1500, capacityG: 30000, nearby: [], stacks: [
  { i: 'water', n: 2, x: 1, y: 1 }, { i: 'pistol', n: 1, c: 'w1' }
], catalog: {
  water: { label: 'Вода', w: 1, h: 2, stack: 10, weightG: 500, color: '#41a0ac' },
  pistol: { label: 'Пистолет', w: 2, h: 1, stack: 1, weightG: 500, weapon: true, color: '#a99c80' }
} };
const mime = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  if (pathname === '/baseline.html') { res.setHeader('Content-Type', mime['.html']); res.end(baseline); return; }
  const file = path.resolve(webRoot, '.' + (pathname === '/' ? '/index.html' : pathname));
  if (!file.startsWith(webRoot + path.sep) || !mime[path.extname(file)] || !fs.existsSync(file)) { res.writeHead(404).end(); return; }
  res.setHeader('Content-Type', mime[path.extname(file)]); res.end(fs.readFileSync(file));
});
async function send(page, name, payload) { await page.evaluate(({ name, payload }) => window.__deliver(name, payload), { name, payload }); }
async function settle(page) { await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))); }
async function load(page, url, implants = true) {
  await page.goto(url);
  await send(page, 'inv:state', structuredClone(inventory));
  await send(page, 'inv:cyber', structuredClone(cyber));
  await send(page, 'inv:open');
  if (implants) await page.locator('[data-tab="cyber"]').click();
  await page.mouse.move(0, 0); await settle(page);
}
async function checkBounds(page) {
  const problems = await page.evaluate(() => {
    const errors = [];
    for (const el of document.querySelectorAll('.cyTile, .vTitle, .vValue, .cyFoot, #hudTitle')) {
      const r = el.getBoundingClientRect();
      if (r.left < 0 || r.top < 0 || r.right > innerWidth + 1 || r.bottom > innerHeight + 1) errors.push(`${el.className || el.id} outside viewport`);
      if (el.matches('.cyTile')) {
        const col = el.closest('.cyCol').getBoundingClientRect();
        if (r.top < col.top - 1 || r.bottom > col.bottom + 1 || r.right > col.right + 1) errors.push(`${el.dataset.slot} clipped by column`);
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        if (!el.contains(hit)) errors.push(`${el.dataset.slot} occluded`);
      }
    }
    return errors;
  });
  assert.deepEqual(problems, []);
}
(async () => {
  fs.mkdirSync(out, { recursive: true });
  fs.rmSync(path.join(out, 'result.json'), { force: true });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ channel: process.env.BROWSER_CHANNEL || 'chrome', headless: true });
  const errors = [];
  try {
    const context = await browser.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
    await context.addInitScript(() => {
      const handlers = {};
      window.__emitted = [];
      window.__deliver = (name, payload) => (handlers[name] || []).forEach(fn => fn(payload));
      window.Open77 = { on: (name, fn) => (handlers[name] ||= []).push(fn), emit: (name, payload) => window.__emitted.push({ name, payload }), ready: () => {} };
    });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
    for (const [width, height] of [[1920,1080],[2560,1440],[1600,900],[1366,768],[1280,720],[2560,1080]]) {
      await page.setViewportSize({ width, height });
      await load(page, base);
      assert.equal(await page.locator('.cyTile').count(), 12);
      assert.equal(await page.locator('.cyTile.filled').count(), 2);
      assert.equal(await page.locator('.implantArt').count(), 2);
      assert.equal(await page.locator('#humValue').textContent(), '77 / 100');
      assert.equal(await page.locator('#sanityValue').textContent(), '100 / 100');
      await checkBounds(page);
      assert.equal(await page.locator('.cyConnectors path').count(), 8);
      await page.screenshot({ path: path.join(out, `implants-${width}x${height}.png`) });
      console.log(`PASS layout ${width}x${height}`);
    }
    await page.setViewportSize({ width: 1920, height: 1080 });
    await load(page, base);
    await page.locator('[data-slot="eyes"]').hover();
    assert(await page.locator('#cyTip').isVisible());
    assert.equal(await page.locator('#cyTip .tipCost').textContent(), '−3 человечности');
    assert(await page.locator('#r-head').evaluate(el => el.classList.contains('lit')));
    await page.screenshot({ path: path.join(out, 'implants-hover.png') });
    await page.locator('[data-slot="os"]').click();
    assert(await page.locator('#deckBox').isVisible());
    assert.equal(await page.locator('.dSlot').count(), 5);
    assert(await page.locator('.dRow button').first().isDisabled());
    assert(await page.locator('#deckBackdrop').isVisible());
    await send(page, 'inv:cyber', structuredClone(cyber));
    assert(await page.locator('#deckBox').evaluate(el => el.contains(document.activeElement)), 'Live update must preserve dialog focus');
    await page.screenshot({ path: path.join(out, 'implants-deck.png') });
    await page.locator('.dRow button').last().click();
    await page.locator('.dSlot:not(.empty)').click();
    const emitted = await page.evaluate(() => window.__emitted);
    assert(emitted.some(e => e.name === 'inv:deckInsert' && e.payload.id === scriptB.id));
    assert(emitted.some(e => e.name === 'inv:deckEject' && e.payload.index === 1));
    await page.keyboard.press('Escape');
    assert(!(await page.locator('#deckBox').isVisible()));
    assert(!(await page.evaluate(() => window.__emitted.some(e => e.name === 'inv:close'))));
    await page.keyboard.press('Enter');
    assert(await page.locator('#deckBox').isVisible());
    await page.keyboard.press('Shift+Tab');
    assert(await page.locator('#deckBox').evaluate(el => el.contains(document.activeElement)));
    await page.keyboard.press('Escape');
    assert(!(await page.locator('#deckBackdrop').isVisible()));
    const fullDeck = structuredClone(cyber);
    fullDeck.deck.scripts = Array.from({ length: 5 }, (_, i) => ({ ...scriptA, id: `test_${i}` }));
    fullDeck.deck.kiroshi = false;
    await send(page, 'inv:cyber', fullDeck);
    await page.locator('.deckTile').click();
    assert.match(await page.locator('.dWarn').textContent(), /Нет оптики/);
    for (const button of await page.locator('.dRow button').all()) assert(await button.isDisabled());
    await page.locator('#deckBackdrop').click({ position: { x: 30, y: 30 } });
    assert(!(await page.locator('#deckBox').isVisible()));
    await send(page, 'inv:cyber', { ...structuredClone(cyber), humanity: 35, psychosis: 85 });
    await page.mouse.move(0,0); await page.waitForTimeout(450);
    assert.equal(await page.locator('#sanityValue').textContent(), '15 / 100');
    assert.match(await page.locator('#humNote').textContent(), /Ниже порога/);
    assert.match(await page.locator('#sanityNote').textContent(), /тяжёлые/);
    await page.screenshot({ path: path.join(out, 'implants-warning.png') });
    const full = structuredClone(cyber);
    full.slots.forEach(s => { s.implant ||= { id: `test_${s.id}`, label: s.label, humanity: 5, description: 'Тестовый имплант' }; });
    await send(page, 'inv:cyber', full);
    assert.equal(await page.locator('.implantArt').count(), 12);
    await page.screenshot({ path: path.join(out, 'implants-all-slots.png') });
    const empty = structuredClone(cyber);
    empty.slots.forEach(s => { s.implant = null; }); empty.deck = null;
    await send(page, 'inv:cyber', empty);
    assert.equal(await page.locator('.cyTile.empty').count(), 12);
    assert.equal(await page.locator('.deckTile').count(), 0);
    const unknown = structuredClone(cyber);
    unknown.slots.push({ id: 'future', label: 'Дополнительный слот', implant: null });
    await send(page, 'inv:cyber', unknown);
    assert.equal(await page.locator('.cyTile').count(), 13);
    await page.locator('[data-slot="future"]').scrollIntoViewIfNeeded();
    await page.locator('[data-slot="future"]').hover();
    assert.match(await page.locator('#cyTip .tipSlot').textContent(), /Дополнительный/);
    await send(page, 'inv:close');
    assert(!(await page.locator('#cyTip').isVisible()));
    assert(!(await page.locator('#deckBox').isVisible()));
    console.log('PASS hover, live values, deck actions, keyboard, empty/full/unknown slots, close cleanup');

    for (const [width, height] of [[1920,1080],[1280,720]]) {
      await page.setViewportSize({ width, height });
      await load(page, base, false);
      const before = await page.screenshot({ animations: 'disabled' });
      await load(page, base, false);
      const after = await page.screenshot({ animations: 'disabled', path: path.join(out, `inventory-${width}x${height}.png`) });
      assert(before.equals(after), `Inventory reload regression ${width}x${height}`);
      await page.locator('[data-tab="cyber"]').click();
      await page.locator('[data-tab="inv"]').click();
      await page.mouse.move(0,0); await settle(page);
      assert(before.equals(await page.screenshot({ animations: 'disabled' })), `Inventory changed after tab switch ${width}x${height}`);
    }
    console.log('PASS inventory screenshots stable after reload and tab switch');
    assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify({ passed: true, browser: await browser.version(), resolutions: 6, inventoryRoundTrip: true, errors }, null, 2));
    console.log(`PASS all checks. Screenshots: ${out}`);
  } finally { await browser.close(); server.close(); }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
