// Точки дорог для такси (rp_taxi/server/roads.lua) из каталога полос open77_traffic
// (resources/system/open77_traffic/server/spans-generated.lua, MIT, open77-resources).
// Читать файлы другого ресурса платформа не даёт, поэтому берём копию: только x, y, z и
// курс каждой точки, по ячейкам 100×100 м. Перезапустить после обновления open77_traffic:
//   node tools/taxi/build-roads.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = readFileSync(join(root, "resources/system/open77_traffic/server/spans-generated.lua"), "utf8");
const at = src.indexOf("cells = {");
if (at < 0) throw new Error("в каталоге нет cells");
const grid = Number((src.match(/gridSizeM = (\d+)/) || [])[1] || 100);
const dataset = (src.match(/datasetId = "([^"]+)"/) || [])[1] || "?";

const cells = new Map();
let current = null, count = 0;
for (const line of src.slice(at).split("\n")) {
  const key = line.match(/^\s*\["(-?\d+:-?\d+)"\]\s*=\s*\{/);
  if (key) { current = []; cells.set(key[1], current); continue; }
  const row = line.match(/^\s*\{([^{}]+)\},?\s*$/);
  if (row && current) {
    const v = row[1].split(",").map(Number); // id, lane, arcMm, x, y, z, yaw, span
    if (v.length >= 7 && v.slice(3, 7).every(Number.isFinite)) {
      current.push(v[3].toFixed(1), v[4].toFixed(1), v[5].toFixed(2), v[6].toFixed(1));
      count++;
    }
  }
}

const out = [
  "-- Сгенерировано tools/taxi/build-roads.mjs из каталога полос open77_traffic (MIT,",
  `-- open77-resources, датасет ${dataset}). Не править руками.`,
  "-- cells[\"cx:cy\"] — плоский список x, y, z, yaw точек полос в ячейке grid×grid м",
  "-- (cx = floor(x / grid)); yaw — курс машины по полосе, как его принимает vehicles.create.",
  `TaxiRoads = { grid = ${grid}, cells = {`,
];
for (const [key, list] of cells) if (list.length) out.push(`["${key}"]={${list.join(",")}},`);
out.push("} }", "");
writeFileSync(join(root, "resources/rp/rp_taxi/server/roads.lua"), out.join("\n"));
console.log(`точек: ${count}, ячеек: ${cells.size}`);
