#!/usr/bin/env node
// Статические проверки проекта одной командой (без игры и без сервера):
//
//   node tools/ops/check-static.cjs                 — основные проверки
//   node tools/ops/check-static.cjs --config        — плюс Open77.Server --check-config
//   node tools/ops/check-static.cjs --ui            — плюс tools/ui (нужен Playwright, см. tools/ui/README.md)
//
// 1. Пути с учётом регистра (Linux-хостинг): файлы из манифестов open77.lua, ресурсы из
//    server.jsonc (resources.load), зависимости rp_* и ассеты, на которые ссылаются
//    HTML/CSS страниц, — и что эти ассеты объявлены в web_file(s) манифеста.
// 2. Синтаксис Lua (luaparse; ищется в node_modules или %LOCALAPPDATA%/open77-ui-check,
//    путь можно задать LUAPARSE_MODULE) и встроенного JS страниц (компиляция Node).
// 3. Скрипты эксплуатации: .sh — LF и без BOM, .ps1 — с BOM (Windows PowerShell 5.1).
// 4. git diff --check (пробелы в конце строк, маркеры конфликтов).
// Код выхода 0 — всё чисто, 1 — есть ошибки. Синтаксическая проверка не заменяет игру.

'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const args = new Set(process.argv.slice(2));
const errors = [];
const notes = [];
const err = (where, text) => errors.push(`${where}: ${text}`);

// Существует ли путь с ТОЧНО таким регистром (Windows сам регистр не различает).
function existsExact(rel) {
  let dir = root;
  for (const part of rel.split('/').filter(Boolean)) {
    if (part === '.') continue;
    if (part === '..') { dir = path.dirname(dir); continue; }
    let names;
    try { names = fs.readdirSync(dir); } catch { return false; }
    if (!names.includes(part)) return false;
    dir = path.join(dir, part);
  }
  return true;
}
const rel = (p) => path.relative(root, p).split(path.sep).join('/');
function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'node_modules' && e.name !== 'dist') walk(p, out); } else out.push(p);
  }
  return out;
}
function stripLuaComments(text) { return text.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/--[^\n]*/g, ''); }

// -- 1. манифесты и пути -----------------------------------------------------------------

const rpDir = path.join(root, 'resources/rp');
const resources = fs.readdirSync(rpDir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
const manifests = {};
for (const name of resources) {
  const file = path.join(rpDir, name, 'open77.lua');
  if (!fs.existsSync(file)) continue;
  const text = stripLuaComments(fs.readFileSync(file, 'utf8'));
  const m = { name, files: [], web: [], deps: [] };
  const declared = text.match(/^\s*resource\s+"([^"]+)"/m);
  if (declared && declared[1] !== name) err(`resources/rp/${name}/open77.lua`, `resource "${declared[1]}" не совпадает с папкой ${name}`);
  const re = /^\s*(server_script|client_script|shared_script|web_file|web_files|files|dependency)\s*(\{[\s\S]*?\}|"[^"]*")/gm;
  let x;
  while ((x = re.exec(text))) {
    const values = [...x[2].matchAll(/"([^"]*)"/g)].map((v) => v[1]);
    for (const v of values) {
      if (x[1] === 'dependency') m.deps.push(v.split(/\s/)[0]);
      else { m.files.push(v); if (x[1].startsWith('web_file') || x[1] === 'files') m.web.push(v); }
    }
  }
  manifests[name] = m;
  for (const f of m.files) {
    if (/[*?]/.test(f)) continue; // шаблоны — без проверки
    if (!existsExact(`resources/rp/${name}/${f}`)) err(`resources/rp/${name}/open77.lua`, `нет файла "${f}" (с учётом регистра)`);
  }
}
for (const m of Object.values(manifests)) {
  for (const d of m.deps) {
    if (d.startsWith('rp_') && !manifests[d]) err(`resources/rp/${m.name}/open77.lua`, `зависимость "${d}" — нет такого ресурса rp_*`);
  }
}

// server.jsonc: resources.load — "rp/<имя>" с точным регистром.
try {
  const jsonc = fs.readFileSync(path.join(root, 'server.jsonc'), 'utf8')
    .replace(/("(?:[^"\\]|\\.)*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g, (s, str) => str || '');
  const cfg = JSON.parse(jsonc.replace(/,(\s*[}\]])/g, '$1'));
  for (const entry of (cfg.resources && cfg.resources.load) || []) {
    if (typeof entry === 'string' && entry.startsWith('rp/') && !existsExact(`resources/${entry}`)) {
      err('server.jsonc', `resources.load "${entry}" — нет папки resources/${entry} (с учётом регистра)`);
    }
  }
} catch (e) { err('server.jsonc', `не разобран: ${e.message}`); }

// Ссылки страниц на свои файлы: src/href/url(...) — существуют и объявлены в манифесте.
for (const m of Object.values(manifests)) {
  const declared = new Set(m.web.map((f) => f.replace(/^\.\//, '')));
  const webPages = m.web.filter((f) => /\.(html|css)$/i.test(f));
  for (const page of webPages) {
    const full = path.join(rpDir, m.name, page);
    if (!fs.existsSync(full)) continue;
    const text = fs.readFileSync(full, 'utf8');
    const refs = [...text.matchAll(/(?:src|href)\s*=\s*["']([^"'#?]+)["']|url\(\s*["']?([^"')#?]+)["']?\s*\)/g)].map((r) => r[1] || r[2]);
    for (const ref of refs) {
      if (/^(?:[a-z]+:|\/\/|data:|#|\$\{)/i.test(ref) || ref.includes('${') || ref.includes('+')) continue;
      const target = path.posix.normalize(path.posix.join(path.posix.dirname(page), ref));
      if (!existsExact(`resources/rp/${m.name}/${target}`)) err(`resources/rp/${m.name}/${page}`, `ссылка "${ref}" — нет файла ${target} (с учётом регистра)`);
      else if (!declared.has(target)) err(`resources/rp/${m.name}/${page}`, `файл ${target} не объявлен в web_file(s) манифеста — в игре не загрузится`);
    }
  }
}

// -- 2. синтаксис Lua и JS ---------------------------------------------------------------

let luaparse = null;
for (const candidate of [process.env.LUAPARSE_MODULE, 'luaparse',
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'open77-ui-check/node_modules/luaparse')]) {
  if (!candidate) continue;
  try { luaparse = require(candidate); break; } catch { /* дальше */ }
}
const luaFiles = walk(rpDir).filter((f) => f.endsWith('.lua') && path.basename(f) !== 'open77.lua');
if (!luaparse) {
  notes.push('Lua: luaparse не найден — синтаксис Lua не проверен (npm install --prefix "%LOCALAPPDATA%\\open77-ui-check" luaparse@0.3.1)');
} else {
  for (const f of luaFiles) {
    try { luaparse.parse(fs.readFileSync(f, 'utf8'), { luaVersion: '5.3' }); } catch (e) { err(rel(f), `Lua: ${e.message}`); }
  }
}
const htmlFiles = walk(rpDir).filter((f) => f.endsWith('.html'));
const jsFiles = walk(rpDir).filter((f) => f.endsWith('.js'));
for (const f of htmlFiles) {
  const text = fs.readFileSync(f, 'utf8');
  let i = 0;
  for (const s of text.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/gi)) {
    i++;
    const attrs = s[1] || '';
    if (/\bsrc\s*=/.test(attrs) || /type\s*=\s*["'](?!text\/javascript|module)/i.test(attrs)) continue;
    try { new vm.Script(s[2], { filename: `${rel(f)}#script${i}` }); }
    catch (e) {
      if (/type\s*=\s*["']module/i.test(attrs) && /import|export/.test(e.message + s[2])) continue; // модуль — без проверки
      err(rel(f), `JS (script #${i}): ${e.message}`);
    }
  }
}
for (const f of jsFiles) {
  try { new vm.Script(fs.readFileSync(f, 'utf8'), { filename: rel(f) }); } catch (e) { err(rel(f), `JS: ${e.message}`); }
}

// -- 3. скрипты эксплуатации -------------------------------------------------------------

for (const f of walk(path.join(root, 'tools'))) {
  const buf = fs.readFileSync(f);
  const bom = buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf;
  if (f.endsWith('.sh')) {
    if (bom) err(rel(f), 'BOM в начале .sh — bash его не поймёт');
    if (buf.includes(Buffer.from('\r\n'))) err(rel(f), 'CRLF в .sh — на Linux не запустится (нужен LF)');
    // lib.sh подключается через «.», остальные запускаются — им нужна строка #!.
    if (path.basename(f) !== 'lib.sh' && !buf.toString('utf8', 0, 20).startsWith('#!')) err(rel(f), 'нет строки #! в начале .sh');
  }
  if (f.endsWith('.ps1') && !bom && /[^\x00-\x7f]/.test(buf.toString('utf8'))) {
    err(rel(f), '.ps1 с кириллицей без BOM — Windows PowerShell 5.1 прочитает её как ANSI');
  }
}

// -- 4. git diff --check -----------------------------------------------------------------

const diff = spawnSync('git', ['diff', '--check'], { cwd: root, encoding: 'utf8' });
if (diff.status !== 0 && diff.stdout.trim()) err('git diff --check', '\n' + diff.stdout.trim());

// -- по флагам -----------------------------------------------------------------------------

if (args.has('--config')) {
  const exe = fs.existsSync(path.join(root, 'Open77.Server.exe')) ? 'Open77.Server.exe' : './Open77.Server';
  const r = spawnSync(path.join(root, exe), ['--check-config'], { cwd: root, encoding: 'utf8' });
  if (r.status !== 0) err('--check-config', (r.stdout + r.stderr).trim().split('\n').slice(-5).join('\n'));
  else notes.push('--check-config: конфигурация валидна');
}
if (args.has('--ui')) {
  for (const t of ['check-implants.cjs', 'check-inventory.cjs']) {
    const r = spawnSync(process.execPath, [path.join(root, 'tools/ui', t)], { cwd: root, encoding: 'utf8' });
    if (r.status !== 0) err(`tools/ui/${t}`, (r.stdout + r.stderr).trim().split('\n').slice(-6).join('\n'));
    else notes.push(`tools/ui/${t}: PASS`);
  }
}

// -- итог ----------------------------------------------------------------------------------

const counted = `ресурсов ${Object.keys(manifests).length}, Lua ${luaparse ? luaFiles.length : 0}, HTML ${htmlFiles.length}, JS ${jsFiles.length}`;
for (const n of notes) console.log(`note  ${n}`);
if (errors.length) {
  for (const e of errors) console.log(`FAIL  ${e}`);
  console.log(`\nИтого ошибок: ${errors.length} (${counted})`);
  process.exit(1);
}
console.log(`OK  статические проверки пройдены (${counted})`);
