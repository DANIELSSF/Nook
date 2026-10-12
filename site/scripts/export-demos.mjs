/**
 * Records each demo of the site to a clip you can reuse in the README, a post or a slide: a 1280 × 720 WebM, and an MP4 (H.264,
 * no audio) made from it. The demos are DOM and SVG, so the clips are the real thing, frame by frame.
 *
 *   npm run export:demos                      # every demo, light theme
 *   npm run export:demos -- --scene follow    # one demo
 *   npm run export:demos -- --theme dark      # or `both`
 *
 * It builds the site with the demo pages switched on (into dist-export/), serves it on a local port, and drives a browser with
 * Playwright's video recording. First time: `npx playwright install chromium` (or PLAYWRIGHT_CHANNEL=msedge|chrome to use a
 * browser you already have). Trimming and the MP4 need ffmpeg: the one in $FFMPEG, on the PATH (`brew install ffmpeg`), or
 * ffmpeg-static's binary if you installed it yourself. Nothing is downloaded here: without ffmpeg you get the raw WebM only. Clips land
 * in exports/.
 */
import { chromium } from 'playwright';
import ffmpeg from 'ffmpeg-static';
import { execFile, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createReadStream, existsSync, mkdirSync, renameSync, rmSync, statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { config } from '../src/config.ts';

const run = promisify(execFile);
// The script never fetches a binary itself (an unverified download it would then run): it uses an ffmpeg that is already on this Mac.
const onPath = () => {
  const found = spawnSync('/usr/bin/which', ['ffmpeg'], { encoding: 'utf8' });
  return found.status === 0 ? found.stdout.trim() : null;
};
const ffmpegPath = [process.env.FFMPEG, onPath(), ffmpeg].find((candidate) => candidate && existsSync(candidate)) ?? null;
if (!ffmpegPath) console.log('No ffmpeg found (FFMPEG, PATH or ffmpeg-static): only the raw WebM clips will be written. `brew install ffmpeg` for trimmed WebM and MP4.');
const root = join(fileURLToPath(new URL('..', import.meta.url)));
const out = join(root, 'exports');
const dist = join(root, 'dist-export');
const args = process.argv.slice(2);
const flag = (name, fallback) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : fallback; };
const ALL = ['home', 'follow', 'question', 'compose', 'agents', 'alerts', 'customize', 'quit'];
const scenes = flag('scene') ? flag('scene').split(',') : ALL;
// A scene name becomes part of a file name: only the known ones.
const unknown = scenes.filter((scene) => !ALL.includes(scene));
if (unknown.length) { console.error(`Unknown scene: ${unknown.join(', ')}. Scenes: ${ALL.join(', ')}.`); process.exit(1); }
const THEMES = ['light', 'dark'];
const themes = flag('theme', 'light') === 'both' ? THEMES : [flag('theme', 'light')];
if (!themes.every((theme) => THEMES.includes(theme))) { console.error('Theme: light, dark or both.'); process.exit(1); }
const port = Number(flag('port', 4350));

// 1. Build the site with the demo pages on.
console.log('Building…');
const built = spawnSync('npx', ['astro', 'build', '--outDir', 'dist-export'], { cwd: root, stdio: 'inherit', env: { ...process.env, EXPORT_DEMOS: '1' } });
if (built.status !== 0) process.exit(built.status ?? 1);

// 2. Serve it under the site's base path.
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };
const server = createServer((req, res) => {
  let path = decodeURIComponent((req.url ?? '/').split('?')[0]);
  if (!path.startsWith(config.base)) { res.writeHead(404).end(); return; }
  path = normalize(path.slice(config.base.length));
  let file = join(dist, path);
  if (existsSync(file) && statSync(file).isDirectory()) file = join(file, 'index.html');
  if (!file.startsWith(dist) || !existsSync(file)) { res.writeHead(404).end('not found'); return; }
  res.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream' });
  createReadStream(file).pipe(res);
});
await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));

mkdirSync(out, { recursive: true });
let browser;
try {
  browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || undefined, headless: true });
} catch (e) {
  console.error('\nNo browser to record with. Run `npx playwright install chromium` (or set PLAYWRIGHT_CHANNEL=msedge|chrome).\n');
  server.close();
  process.exit(1);
}

try {
  for (const theme of themes) {
    for (const scene of scenes) {
      const tmp = join(out, '.tmp');
      rmSync(tmp, { recursive: true, force: true });
      const ctx = await browser.newContext({
        viewport: { width: 1280, height: 720 }, colorScheme: theme, reducedMotion: 'no-preference',
        recordVideo: { dir: tmp, size: { width: 1280, height: 720 } },
      });
      const page = await ctx.newPage();
      const began = Date.now();
      await page.goto(`http://127.0.0.1:${port}${config.base}demo/${scene}/`, { waitUntil: 'load' });
      await page.waitForFunction(() => window.__demoStarted !== undefined, null, { timeout: 30000 });
      // How long the recording ran before the demo's first frame: that part is cut off.
      const lead = (Date.now() - began) / 1000 - 0.15;
      await page.waitForFunction(() => window.__demoDone === true, null, { timeout: 120000, polling: 250 });
      await page.waitForTimeout(300);
      const video = page.video();
      await ctx.close();
      const webmSrc = await video.path();
      const base = `${scene}-${theme}`;
      const webm = join(out, `${base}.webm`);
      const mp4 = join(out, `${base}.mp4`);
      if (!ffmpegPath) {
        // Untrimmed: the first moments are the page loading.
        renameSync(webmSrc, webm);
        rmSync(tmp, { recursive: true, force: true });
        console.log(`${base}: ${(statSync(webm).size / 1024).toFixed(0)} KB raw webm`);
        continue;
      }
      renameSync(webmSrc, join(tmp, 'raw.webm'));
      // Trim the lead-in and tidy the encode (the raw recording is bulky).
      await run(ffmpegPath, ['-y', '-ss', String(Math.max(0, lead)), '-i', join(tmp, 'raw.webm'), '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '32', '-an', webm]);
      await run(ffmpegPath, ['-y', '-i', webm, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-preset', 'slow', '-movflags', '+faststart', '-an', mp4]);
      rmSync(tmp, { recursive: true, force: true });
      console.log(`${base}: ${(statSync(mp4).size / 1024).toFixed(0)} KB mp4, ${(statSync(webm).size / 1024).toFixed(0)} KB webm`);
    }
  }
} finally {
  await browser.close();
  server.close();
  rmSync(dist, { recursive: true, force: true });
}
console.log(`\nClips in ${out}`);
