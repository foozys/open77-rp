// Декодировать MP3, разрезать по паузам на фразы, сохранить моно WAV 22050 Гц (v1.wav, v2.wav…).
import fs from 'fs';
import path from 'path';
import { MPEGDecoder } from 'mpg123-decoder';

// Аргументы: вход.mp3 папка [analyze] [join=5+6,9+10] — join склеивает отрезки в одну фразу
// (пауза на точке внутри фразы не отличается от паузы между фразами).
const args = process.argv.slice(2);
const [input, outDir] = args;
const analyzeOnly = args.includes("analyze");
const joinArg = (args.find(a => a.startsWith("join=")) || "join=").slice(5);
const decoder = new MPEGDecoder();
await decoder.ready;
const { channelData, sampleRate } = decoder.decode(new Uint8Array(fs.readFileSync(input)));
decoder.free();

// Моно.
const len = channelData[0].length;
const mono = new Float32Array(len);
for (const ch of channelData) for (let i = 0; i < len; i++) mono[i] += ch[i] / channelData.length;

// Громкость окнами по 20 мс.
const win = Math.floor(sampleRate * 0.02);
const rms = [];
for (let i = 0; i < len; i += win) {
  let s = 0;
  for (let j = i; j < Math.min(len, i + win); j++) s += mono[j] * mono[j];
  rms.push(Math.sqrt(s / win));
}
const peak = Math.max(...rms);
const sorted = [...rms].sort((a, b) => a - b);
const floor = sorted[Math.floor(sorted.length * 0.1)];
const threshold = Math.max(floor * 3, peak * 0.06);
console.log(`длина ${(len / sampleRate).toFixed(2)} с, ${sampleRate} Гц, каналов ${channelData.length}, пик ${peak.toFixed(3)}, шум ${floor.toFixed(4)}, порог ${threshold.toFixed(4)}`);

// Отрезки речи: громче порога; паузы короче minGap склеиваем.
const minGap = Math.round(0.22 / 0.02), minLen = Math.round(0.3 / 0.02), pad = Math.round(0.12 / 0.02);
const segs = [];
let start = -1, quiet = 0;
for (let k = 0; k < rms.length; k++) {
  if (rms[k] > threshold) {
    if (start < 0) start = k;
    quiet = 0;
  } else if (start >= 0) {
    quiet++;
    if (quiet >= minGap) { segs.push([start, k - quiet + 1]); start = -1; quiet = 0; }
  }
}
if (start >= 0) segs.push([start, rms.length]);
let phrases = segs.filter(([a, b]) => b - a >= minLen);
if (joinArg) {
  const groups = joinArg.split(",").map(g => g.split("+").map(Number));
  const merged = [], used = new Set();
  phrases.forEach((seg, i) => {
    if (used.has(i + 1)) return;
    const g = groups.find(g => g[0] === i + 1);
    if (g) { g.forEach(n => used.add(n)); merged.push([phrases[g[0] - 1][0], phrases[g[g.length - 1] - 1][1]]); }
    else merged.push(seg);
  });
  phrases = merged;
}
phrases.forEach(([a, b], i) => console.log(`фраза ${i + 1}: ${(a * 0.02).toFixed(2)}–${(b * 0.02).toFixed(2)} с`));
if (analyzeOnly) process.exit(0);

// Сохранить: с запасом по краям, ресемплинг к 22050, выравнивание громкости.
const SR = 22050;
fs.mkdirSync(outDir, { recursive: true });
phrases.forEach(([a, b], i) => {
  const from = Math.max(0, (a - pad) * win), to = Math.min(len, (b + pad) * win);
  const factor = sampleRate / SR, n = Math.floor((to - from) / factor);
  const y = new Float32Array(n);
  let p = 0;
  for (let k = 0; k < n; k++) {
    const t = from + k * factor, i0 = Math.floor(t), f = t - i0;
    y[k] = (mono[i0] || 0) * (1 - f) + (mono[i0 + 1] || 0) * f;
    p = Math.max(p, Math.abs(y[k]));
  }
  const g = 0.9 / (p || 1);
  const out = Buffer.alloc(44 + n * 2);
  out.write('RIFF', 0); out.writeUInt32LE(36 + n * 2, 4); out.write('WAVE', 8);
  out.write('fmt ', 12); out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20); out.writeUInt16LE(1, 22);
  out.writeUInt32LE(SR, 24); out.writeUInt32LE(SR * 2, 28); out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34);
  out.write('data', 36); out.writeUInt32LE(n * 2, 40);
  for (let k = 0; k < n; k++) out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, y[k] * g)) * 32767), 44 + k * 2);
  fs.writeFileSync(path.join(outDir, `v${i + 1}.wav`), out);
});
console.log(`сохранено ${phrases.length}`);
