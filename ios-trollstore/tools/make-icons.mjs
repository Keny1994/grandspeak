// Đồng bộ hoặc sinh bộ icon ứng dụng GrandSpeak (iOS TrollStore + PWA Web).
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const iosRoot = path.join(here, '..');
const outDir = path.join(iosRoot, 'Resources');
const publicDir = path.join(iosRoot, '..', 'public');
fs.mkdirSync(outDir, { recursive: true });

// Nếu bộ icon chính thức của GrandSpeak đã có sẵn trong Resources/, giữ nguyên không ghi đè.
if (
  fs.existsSync(path.join(outDir, 'AppIcon60x60@3x.png')) &&
  fs.existsSync(path.join(outDir, 'AppIcon60x60@2x.png')) &&
  fs.existsSync(path.join(outDir, 'AppIcon76x76@2x.png'))
) {
  console.log('Đã có sẵn bộ icon chính thức của GrandSpeak trong Resources/, giữ nguyên.');
  process.exit(0);
}

const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));

function starPolygon(cx, cy, outer, inner) {
  const pts = [];
  for (let i = 0; i < 10; i++) {
    const angle = -Math.PI / 2 + (i * Math.PI) / 5;
    const r = i % 2 === 0 ? outer : inner;
    pts.push([cx + Math.cos(angle) * r, cy + Math.sin(angle) * r]);
  }
  return pts;
}

function inPolygon(x, y, pts) {
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i];
    const [xj, yj] = pts[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

function pixel(size, x, y) {
  const v = y / size;
  let color = mix([16, 66, 49], [8, 30, 22], v);
  const dx = x - size / 2;
  const dy = y - size / 2;
  const dist = Math.sqrt(dx * dx + dy * dy) / size;
  if (dist < 0.3) color = mix(color, [26, 92, 68], (1 - dist / 0.3) * 0.55);
  if (dist >= 0.4 && dist <= 0.426) color = mix([246, 216, 138], [185, 135, 40], v);
  const star = starPolygon(size / 2, size / 2 + size * 0.014, size * 0.295, size * 0.295 * 0.382);
  if (inPolygon(x, y, star)) color = mix([252, 228, 156], [201, 154, 59], v);
  return color;
}

function crcTable() {
  const table = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
}
const TABLE = crcTable();
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

function png(size) {
  const raw = Buffer.alloc((size * 3 + 1) * size);
  const ss = size >= 512 ? 2 : 3;
  for (let y = 0; y < size; y++) {
    raw[y * (size * 3 + 1)] = 0;
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0;
      for (let sy = 0; sy < ss; sy++) {
        for (let sx = 0; sx < ss; sx++) {
          const c = pixel(size, x + (sx + 0.5) / ss, y + (sy + 0.5) / ss);
          r += c[0]; g += c[1]; b += c[2];
        }
      }
      const o = y * (size * 3 + 1) + 1 + x * 3;
      raw[o] = Math.round(r / (ss * ss));
      raw[o + 1] = Math.round(g / (ss * ss));
      raw[o + 2] = Math.round(b / (ss * ss));
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const iosTargets = [
  ['AppIcon60x60@2x.png', 120],
  ['AppIcon60x60@3x.png', 180],
  ['AppIcon76x76@2x.png', 152],
];
for (const [name, size] of iosTargets) {
  const buf = png(size);
  fs.writeFileSync(path.join(outDir, name), buf);
  console.log('Đã tạo iOS icon:', name, size + 'px');
}

const icon180 = fs.readFileSync(path.join(outDir, 'AppIcon60x60@3x.png'));
if (fs.existsSync(publicDir)) {
  fs.writeFileSync(path.join(publicDir, 'apple-touch-icon.png'), icon180);
  fs.writeFileSync(path.join(publicDir, 'icon-192.png'), png(192));
  fs.writeFileSync(path.join(publicDir, 'icon-512.png'), png(512));
  console.log('Đã tạo PWA/Safari icons: apple-touch-icon.png, icon-192.png, icon-512.png');
}

fs.writeFileSync(path.join(iosRoot, 'icon-1024-preview.png'), png(1024));
console.log('Đã tạo icon-1024-preview.png');
