/**
 * Makes the social preview image (public/og.png, 1200 × 630) from the site's own styles: the island and the cat on the dark
 * page, the way the hero shows them. The other icons (favicon, touch icon) are built by Astro itself from the cat's drawing
 * (src/pages/favicon.svg.ts, apple-touch-icon.png.ts), so they need nothing here.
 *
 *   npm run assets        # needs a browser: `npx playwright install chromium`, or PLAYWRIGHT_CHANNEL=msedge|chrome
 */
import { chromium } from 'playwright';
import sharp from 'sharp';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const cat = readFileSync(join(root, 'scripts/assets/cat-sit.svg'), 'utf8').replace('class="cat ', 'class="cat ');
const css = ['tokens', 'base', 'island'].map((n) => `<link rel="stylesheet" href="${pathToFileURL(join(root, `src/styles/${n}.css`))}">`).join('');

const html = `<!doctype html><html lang="es" data-theme="dark"><head><meta charset="utf-8">${css}
<style>
  body { width: 1200px; height: 630px; margin: 0; overflow: hidden; background: #0a0c0b; font-family: var(--font-sans); color: #f2f5f3; position: relative; }
  .glow { position: absolute; inset: 0; background: radial-gradient(48% 70% at 78% 0%, #1f3a31, transparent 70%), radial-gradient(40% 50% at 0% 100%, rgb(230 120 85 / 0.14), transparent 70%), radial-gradient(40% 50% at 100% 90%, rgb(81 217 173 / 0.12), transparent 70%); }
  .copy { position: absolute; left: 76px; top: 150px; width: 520px; }
  .eyebrow { font-size: 20px; font-weight: 650; letter-spacing: 0.18em; text-transform: uppercase; color: #51d9ad; display: flex; align-items: center; gap: 12px; }
  .eyebrow::before { content: ''; width: 9px; height: 9px; border-radius: 50%; background: #51d9ad; box-shadow: 0 0 0 5px rgb(81 217 173 / 0.18); }
  h1 { margin: 20px 0 0; font-size: 168px; line-height: 0.95; font-weight: 720; letter-spacing: -0.055em; }
  p { margin: 26px 0 0; font-size: 40px; line-height: 1.18; font-weight: 520; letter-spacing: -0.02em; color: rgb(242 245 243 / 0.84); }
  .foot { position: absolute; left: 76px; bottom: 56px; font-size: 22px; color: rgb(242 245 243 / 0.5); letter-spacing: 0.01em; }
  .stage { position: absolute; left: 640px; top: 0; zoom: 0.93; }
  .island { filter: drop-shadow(0 30px 40px rgb(0 0 0 / 0.6)); }
</style></head><body>
<div class="glow"></div>
<div class="copy"><div class="eyebrow">Un pequeño espacio para tu IA</div><h1>Nook</h1><p>Tu terminal, a un gesto de distancia.</p></div>
<div class="foot">App nativa de macOS · Claude Code y Codex</div>
<div class="stage">
  <div class="island tc-mint" data-state="open" style="--oh:340px;--th:340px;--iw:572px">
    <div class="island__rim"></div><div class="island__shape"></div>
    <div class="island__content">
      <div class="island__strip"><div class="island__cat">${cat}</div>
        <div class="island__right island__right--open"><span class="dots" data-on="false"><i></i><i></i><i></i></span></div></div>
      <div class="island__panel">
        <div class="island__tabs"><span class="tab tc-mint is-active"><i class="tab__dot"></i>Claude Code</span></div>
        <div class="island__convo">
          <div class="msg msg--user">Actualiza la página de bienvenida.</div>
          <div class="msg msg--tool">Edit(src/pages/bienvenida.astro)</div>
          <div class="msg msg--out">Añadidas 12 líneas, quitadas 3</div>
          <div class="msg msg--ai">Listo. El diseño ahora se adapta a móvil y escritorio.</div>
        </div>
        <div class="composer"><div class="composer__text"><span class="ph">Mensaje o /comando para Claude…</span></div>
          <div class="composer__row"><span class="composer__status"><i></i><span>Claude · en vivo · ↵ enviar</span></span><span class="composer__spacer"></span><span class="send"></span></div></div>
      </div>
    </div>
  </div>
</div></body></html>`;

const tmp = join(root, 'scripts/.og.tmp.html');
writeFileSync(tmp, html);
const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || undefined, headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto(pathToFileURL(tmp).href, { waitUntil: 'load' });
  await page.waitForTimeout(400);
  const png = await page.screenshot({ type: 'png' });
  // A palette keeps the file small (a social image is fetched a lot).
  const out = await sharp(png).png({ palette: true, quality: 92, effort: 10, compressionLevel: 9 }).toBuffer();
  writeFileSync(join(root, 'public/og.png'), out);
  console.log(`public/og.png ${out.length} bytes`);
} finally {
  await browser.close();
  rmSync(tmp, { force: true });
}
