// Обработка синтезированных фраз в «голоса в голове»: стерео WAV 22050 Гц 16 бит.
const fs = require('fs'), path = require('path');
const [inDir, outDir, inDir2] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const SR = 22050;
let seed = 1234567;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };

function readWav(file) {
  const b = fs.readFileSync(file);
  let p = 12, fmt = null, data = null;
  while (p < b.length) {
    const id = b.toString('ascii', p, p + 4), size = b.readUInt32LE(p + 4);
    if (id === 'fmt ') fmt = { ch: b.readUInt16LE(p + 10), sr: b.readUInt32LE(p + 12), bits: b.readUInt16LE(p + 22) };
    if (id === 'data') data = b.subarray(p + 8, p + 8 + size);
    p += 8 + size + (size & 1);
  }
  if (!fmt || fmt.bits !== 16 || fmt.ch !== 1) throw new Error('format ' + JSON.stringify(fmt));
  const x = new Float32Array(data.length / 2);
  for (let i = 0; i < x.length; i++) x[i] = data.readInt16LE(i * 2) / 32768;
  return fmt.sr === SR ? x : resample(x, fmt.sr / SR); // к 22050 Гц
}

function resample(x, factor) { // factor > 1 — выше и короче
  const n = Math.floor(x.length / factor), y = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const t = i * factor, a = Math.floor(t), f = t - a;
    y[i] = (x[a] || 0) * (1 - f) + (x[a + 1] || 0) * f;
  }
  return y;
}

function envelope(x) {
  const e = new Float32Array(x.length);
  let v = 0;
  for (let i = 0; i < x.length; i++) { const a = Math.abs(x[i]); v = a > v ? v + (a - v) * 0.05 : v * 0.9985; e[i] = v; }
  return e;
}

function haunt(x, y, severe) {
  const tail = Math.floor(SR * 1.6);
  const n = x.length + tail + Math.floor(SR * 0.2);
  const L = new Float32Array(n), R = new Float32Array(n);
  const add = (src, delaySec, gain, panL, panR, wobble) => {
    const d = Math.floor(delaySec * SR);
    for (let i = 0; i < src.length && i + d < n; i++) {
      // Медленно «плавающая» панорама — голос ходит вокруг головы.
      const w = wobble ? 0.5 + 0.5 * Math.sin(2 * Math.PI * wobble * i / SR) : 0.5;
      L[i + d] += src[i] * gain * (panL * (1 - w) + panR * w);
      R[i + d] += src[i] * gain * (panR * (1 - w) + panL * w);
    }
  };
  // Три слоя одной фразы: обычный, ниже и медленнее, выше и тише.
  // Основной голос, он же ниже (мягкий сдвиг), и второй голос тихо сверху.
  add(x, 0, 0.6, 0.8, 0.8, 0);
  add(resample(x, severe ? 0.8 : 0.9), 0.11, 0.42, 1.0, 0.25, 0.35);
  if (y) add(y, 0.06, severe ? 0.32 : 0.24, 0.25, 1.0, 0.5);
  // Шёпот: шум, повторяющий огибающую речи.
  const env = envelope(x);
  const breath = new Float32Array(x.length);
  let prev = 0;
  for (let i = 0; i < x.length; i++) { const nz = rnd() * 2 - 1; prev += (nz - prev) * 0.18; breath[i] = prev * env[i] * 1.6; }
  add(breath, 0.02, severe ? 0.16 : 0.1, 0.6, 0.9, 0.2);
  // Роботизация: кольцевая модуляция.
  for (let i = 0; i < n; i++) {
    const m = 0.9 + 0.1 * Math.sin(2 * Math.PI * (severe ? 7 : 5) * i / SR);
    L[i] *= m; R[i] *= m;
  }
  // Эхо между ушами.
  const d1 = Math.floor(0.23 * SR), d2 = Math.floor(0.37 * SR), fb = severe ? 0.42 : 0.33;
  for (let i = 0; i < n; i++) {
    if (i >= d1) L[i] += R[i - d1] * fb;
    if (i >= d2) R[i] += L[i - d2] * fb;
  }
  // Помехи: тихое шипение и редкие щелчки.
  for (let i = 0; i < n; i++) {
    let s = 0;
    L[i] += s; R[i] += s * 0.8;
  }
  // Срез низов, мягкое ограничение, подъём и затухание, нормализация.
  let hl = 0, hr = 0, pl = 0, pr = 0;
  const a = 0.94;
  for (let i = 0; i < n; i++) {
    const yl = a * (hl + L[i] - pl), yr = a * (hr + R[i] - pr);
    pl = L[i]; pr = R[i]; hl = yl; hr = yr;
    L[i] = Math.tanh(yl * 1.1); R[i] = Math.tanh(yr * 1.1);
  }
  // Срез резких верхов (однополюсный НЧ-фильтр, ~4 кГц).
  let ll = 0, lr = 0;
  for (let i = 0; i < n; i++) { ll += (L[i] - ll) * 0.55; lr += (R[i] - lr) * 0.55; L[i] = ll; R[i] = lr; }
  const fadeIn = Math.floor(0.15 * SR), fadeOut = Math.floor(0.8 * SR);
  let peak = 0;
  for (let i = 0; i < n; i++) {
    let g = 1;
    if (i < fadeIn) g = i / fadeIn;
    if (i > n - fadeOut) g = (n - i) / fadeOut;
    L[i] *= g; R[i] *= g;
    peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
  }
  const k = 0.85 / (peak || 1);
  const out = Buffer.alloc(44 + n * 4);
  out.write('RIFF', 0); out.writeUInt32LE(36 + n * 4, 4); out.write('WAVE', 8);
  out.write('fmt ', 12); out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20); out.writeUInt16LE(2, 22);
  out.writeUInt32LE(SR, 24); out.writeUInt32LE(SR * 4, 28); out.writeUInt16LE(4, 32); out.writeUInt16LE(16, 34);
  out.write('data', 36); out.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) {
    out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L[i] * k)) * 32767), 44 + i * 4);
    out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R[i] * k)) * 32767), 46 + i * 4);
  }
  return out;
}

const files = fs.readdirSync(inDir).filter(f => /^v\d+\.wav$/.test(f)).sort();
for (const f of files) {
  const x = readWav(path.join(inDir, f));
  const y = inDir2 && fs.existsSync(path.join(inDir2, f)) ? readWav(path.join(inDir2, f)) : null;
  const base = f.replace('.wav', '');
  fs.writeFileSync(path.join(outDir, `voice_${base.slice(1)}.wav`), haunt(x, y, false));
  fs.writeFileSync(path.join(outDir, `voice_${base.slice(1)}_severe.wav`), haunt(x, y, true));
}
console.log('done', files.length);
