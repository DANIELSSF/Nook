/**
 * Checks the website's cat against the app's own: the same frames, drawn the way the app's `PetRender.film` draws them (the same
 * contact sheet, the same scale), and compared with the app's sheet tile by tile.
 *
 *   npm run compare:cat -- wake-header /path/to/wake-header-zoom.png
 *
 * The app writes its sheets when its render tests run with NOOK_RENDER_DIR set (`PetWakeRenderTests`, `PetRenderTests`). The sets
 * here are the ones those tests draw: the waking (`wake-header`, `wake-compact`, and `wake-light-*` for the squint), a stretch
 * (`stretch-header`, `stretch-compact`), a yawn (`yawn-header`, `yawn-compact`), a nap (`nap-compact`) and the sad cat of the question
 * before quitting (`sad-header`, `sad-compact`). The waking and the sad cat are sampled directly, as the app's tests sample them; the
 * stretch, the yawn and the nap are filmed the way the app films them, through its director and player (see `film` below: the
 * clock, the small life, the follow-through and the lengths the director draws all count). For each tile it prints how much the two silhouettes
 * overlap (IoU: 1 is the same cat; about 0.99 is the same cat drawn by two rasterizers) and it writes, to compare/:
 *
 *   <set>-web.png     the website's sheet, in the app's grid
 *   <set>-pairs.png   every tile as app | website | overlay (red: only the app's, green: only the website's)
 *
 * It uses the site's own TypeScript (through Vite) and the Playwright browser (PLAYWRIGHT_CHANNEL=msedge|chrome for one you have).
 */
import { chromium } from 'playwright';
import { createServer } from 'vite';
import sharp from 'sharp';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const [set, appPath] = process.argv.slice(2);
if (!set || !appPath) { console.error('usage: npm run compare:cat -- <set> <the app\'s contact sheet.png>'); process.exit(1); }

// The app's stages (`PetRender`): 7 pixels per point, the cat at 0.5 points per rig unit in the header and 0.6 in the notch's wing.
// Header: 70 x 54 points, home 22 points in, ground 30 up. Notch: cropped to 46 x 40 points, anchor 15.5 in, ground 15 up.
const STAGES = {
  header: { w: 490, h: 378, ax: 154, ay: 168, scale: 3.5, cols: 4 },
  compact: { w: 322, h: 280, ax: 108.5, ay: 175, scale: 4.2, cols: 6 },
};

const vite = await createServer({ root, server: { middlewareMode: true }, appType: 'custom', logLevel: 'silent' });
const A = await vite.ssrLoadModule('/src/cat/anim.ts');
const R = await vite.ssrLoadModule('/src/cat/render.ts');
const P = await vite.ssrLoadModule('/src/cat/pose.ts');
const L = await vite.ssrLoadModule('/src/cat/life.ts');
const S = await vite.ssrLoadModule('/src/cat/secondary.ts');

/*
 * A gesture as the app films it (`PetSim.gesture`): its director starts it at once and its player draws it, at 30 frames a second
 * from the clock's 1000 s, until the gesture ends and 1.2 s after. Each frame is the idle sit with the gesture over it (staged or
 * blended as `PetDirector.pose` does), then the cat's small life (`PetLife`, as much as `PetDirector.lifeWeight` leaves it and as
 * often as an idle Mac allows: `PetPlayer.lifeContext`), then its follow-through (`PetSecondary`), the springs run frame by frame.
 * The seed is the first one for which the gesture goes the way asked (`PetSim.seed`), and it decides what the director draws from
 * it: the nap's length, and whether a stretch is followed by a yawn (`PetDirector.followUp`). Only what a lone gesture with nobody
 * at the Mac goes through is here: no pointer, alert, drag, work or celebration.
 */
const FPS = 30;
const FOLLOW = { stretch: { kind: 'yawn', delay: [0.4, 0.9], chance: 0.35 } };
const lengthOf = (kind, pick, seed) => (kind === 'nap' ? 30 + 30 * A.hash(pick, seed + 47) : kind === 'stretch' ? 7.0 : A.YAWN_LENGTH);
const seedFor = (facing) => { for (let s = 0; s < 2000; s++) if (facing === undefined || (A.hash(0, s + 97) < 0.5 ? 1 : -1) === facing) return s; return 0; };
function film(kind, stage, { facing, idle = 10, extra = 1.2 } = {}) {
  const seed = seedFor(facing);
  const compact = stage === 'compact';
  const scale = compact ? 0.6 : 0.5;
  let picks = 0;
  const begin = (k) => { const pick = picks++; return { kind: k, age: 0, length: lengthOf(k, pick, seed), facing: A.hash(pick, seed + 97) < 0.5 ? 1 : -1 }; };
  let running = begin(kind), follow = null, nextAt = Infinity, clock = 0, last = null;
  const seconds = running.length + extra;
  // Nobody has touched the Mac for a minute and a half: its small movements come a quarter as often and smaller, its breathing too.
  const away = idle >= 90;
  const life = { rate: 1.5 * (away ? 0.25 : 1), quiet: away ? 0.3 : 1, breath: away ? 0.5 : 1 };
  const temperament = L.temperamentOf('curious', 'day');
  const secondary = new S.Secondary();
  const out = [];
  for (let t = 0; t <= seconds + 1e-9; t += 1 / FPS) {
    const now = 1000 + t;
    const dt = last === null ? 0 : Math.min(0.6, Math.max(0, now - last));
    last = now; clock += dt;
    if (running) {
      running.age += dt;
      if (running.age >= running.length) {
        const f = FOLLOW[running.kind];
        running = null;
        if (f && A.hash(picks, seed + 89) < f.chance) { follow = f.kind; nextAt = clock + f.delay[0] + (f.delay[1] - f.delay[0]) * A.hash(picks, seed + 91); }
      }
    }
    if (!running && follow && clock >= nextAt) { running = begin(follow); follow = null; }
    let pose = A.sit(now, 0), restful = 1;
    if (running) {
      const r = running, u = r.age;
      const g = r.kind === 'yawn' ? A.yawn(u, now) : A.perform(r.kind === 'nap' ? 'sleep' : r.kind, u, r.length, now, { facing: r.facing, alert: 0, shift: r.kind === 'stretch' && compact ? -0.5 : 0 });
      pose = r.kind === 'yawn' ? P.blend(pose, g, 1) : P.staged(pose, g, 1, 'headFirst');
      restful = 1 - A.ramp(u, 0, 0.8) * (1 - A.ramp(u, r.length - 0.8, r.length)) * (r.kind === 'nap' ? 1 : 0.65);
    }
    L.applyLife(pose, { time: now, temperament, restful, quiet: life.quiet, rate: life.rate, alert: 0, breath: life.breath });
    secondary.apply(pose, dt, scale);
    out.push({ u: t, pose });
  }
  return out;
}
/** The frames a film's sheet shows: every `every` seconds of it, rounded to whole frames (`PetRender.film`). */
const pick = (all, every) => { const step = Math.max(1, Math.round(every * FPS)); return all.filter((_, i) => i % step === 0); };

// The frames the app's films pick: from the start, every `step` seconds.
const frames = (total, step, pose) => { const out = []; for (let k = 0; k * step <= total + 1e-9; k++) out.push({ u: k * step, pose: pose(k * step) }); return out; };
const SETS = {
  'wake-header': ['header', () => frames(A.wakeLength(0), 8 / 30, (u) => A.waking(Math.min(u, A.wakeLength(0)), 3 + u, 9, 1e9))],
  'wake-compact': ['compact', () => frames(A.wakeLength(0), 8 / 30, (u) => A.waking(Math.min(u, A.wakeLength(0)), 3 + u, 9, 1e9))],
  'wake-light-header': ['header', () => frames(A.wakeLength(1), 8 / 30, (u) => A.waking(Math.min(u, A.wakeLength(1)), 3 + u, 9, 1e9, 1))],
  'wake-light-compact': ['compact', () => frames(A.wakeLength(1), 8 / 30, (u) => A.waking(Math.min(u, A.wakeLength(1)), 3 + u, 9, 1e9, 1))],
  // The gestures the app films through its director (`PetRenderTests.testRenderTheNewGestures`), with the same settings.
  'stretch-header': ['header', () => pick(film('stretch', 'header', { facing: 1 }), 0.3)],
  'stretch-compact': ['compact', () => pick(film('stretch', 'compact', { facing: 1 }), 0.3)],
  'yawn-header': ['header', () => pick(film('yawn', 'header'), 0.12)],
  'yawn-compact': ['compact', () => pick(film('yawn', 'compact'), 0.12)],
  'nap-compact': ['compact', () => pick(film('nap', 'compact', { facing: 1, idle: 400 }), 0.8)],
  // The sad cat of the question before quitting, from the moment the question appears: the entrance, the tear, a sigh, a long blink.
  'sad-header': ['header', () => frames(9, 0.5, (u) => A.sad(u, A.sadAmount(u)))],
  'sad-compact': ['compact', () => frames(9, 0.5, (u) => A.sad(u, A.sadAmount(u)))],
};
if (!SETS[set]) { console.error(`unknown set "${set}": ${Object.keys(SETS).join(', ')}`); await vite.close(); process.exit(1); }
const [stage, make] = SETS[set];
const g = STAGES[stage];
const list = make();
const gap = 6;
const rows = Math.ceil(list.length / g.cols);
const W = g.cols * g.w + (g.cols + 1) * gap, H = rows * g.h + (rows + 1) * gap;

// 1. The website's sheet.
const tile = ({ pose }) => {
  const { css, group } = R.standaloneCat(R.defaultLook, pose);
  // The cat's place across the stage is in points (`PetRender.placement`: the anchor plus `pose.x`), 7 pixels each in these sheets.
  return `<div class="t"><svg width="${g.w}" height="${g.h}" viewBox="0 0 ${g.w} ${g.h}"><style>${css}</style><g transform="translate(${g.ax + (pose.x ?? 0) * 7} ${g.ay}) scale(${g.scale}) translate(0 -34)">${group}</g></svg></div>`;
};
const html = `<body style="margin:0;background:rgb(134,134,146)"><style>.grid{display:grid;grid-template-columns:repeat(${g.cols},${g.w}px);gap:${gap}px;padding:${gap}px}.t{background:#000;width:${g.w}px;height:${g.h}px;overflow:hidden}svg{display:block}</style><div class="grid">${list.map(tile).join('')}</div></body>`;
const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || undefined, headless: true });
const page = await (await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 1 })).newPage();
await page.setContent(html);
// Two frames, so the whole sheet has been painted before it is captured.
await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))));
const webPng = await page.screenshot({ clip: { x: 0, y: 0, width: W, height: H } });
await browser.close();
await vite.close();

// 2. Tile by tile: the silhouettes (white on the black of the stage, in the top of the tile, above the tab chips and the caption).
const out = join(root, 'compare');
mkdirSync(out, { recursive: true });
writeFileSync(join(out, `${set}-web.png`), webPng);
const grey = async (input) => { const { data, info } = await sharp(input).greyscale().raw().toBuffer({ resolveWithObject: true }); return { data, width: info.width, height: info.height }; };
const app = await grey(appPath), web = await grey(webPng);
if (app.width !== web.width || app.height !== web.height) {
  console.error(`The sheets differ in size (the app's is ${app.width} x ${app.height}, the website's ${web.width} x ${web.height}): is it the "${set}" sheet?`);
  process.exit(1);
}
const top = Math.floor(g.h * 0.6);
const at = (k) => { const r = Math.floor(k / g.cols), c = k % g.cols; return { x: gap + c * (g.w + gap), y: gap + r * (g.h + gap) }; };
const pairs = Buffer.alloc(g.w * 3 * top * list.length * 3, 134);
let total = 0;
list.forEach((f, k) => {
  const o = at(k);
  let inter = 0, union = 0;
  for (let y = 0; y < top; y++) {
    for (let x = 0; x < g.w; x++) {
      const i = (o.y + y) * app.width + o.x + x;
      const a = app.data[i] > 128, b = web.data[i] > 128;
      if (a && b) inter++; if (a || b) union++;
      const row = (k * top + y) * g.w * 3 * 3;
      const put = (col, r, gg, bb) => { const p = row + (col * g.w + x) * 3; pairs[p] = r; pairs[p + 1] = gg; pairs[p + 2] = bb; };
      put(0, app.data[i], app.data[i], app.data[i]); put(1, web.data[i], web.data[i], web.data[i]);
      if (a && b) put(2, 255, 255, 255); else if (a) put(2, 255, 60, 60); else if (b) put(2, 60, 255, 90); else put(2, 0, 0, 0);
    }
  }
  const iou = inter / Math.max(1, union);
  total += iou;
  console.log(`u = ${f.u.toFixed(2).padStart(5)}   IoU ${iou.toFixed(3)}`);
});
await sharp(pairs, { raw: { width: g.w * 3, height: top * list.length, channels: 3 } }).png().toFile(join(out, `${set}-pairs.png`));
console.log(`mean IoU ${(total / list.length).toFixed(3)}   (compare/${set}-pairs.png: app | website | overlay)`);
