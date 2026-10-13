import { startEnv, env } from './env';
import { initTheme } from './theme';
import { initHeader } from './header';
import { initReveal } from './reveal';
import { initHero } from './hero';
import { initPersonality } from './personality';
import { initDemos } from '../demo/manager';
import { initFilm } from '../film';
import { initVignettes } from './vignettes';
import { initPlatform, initDownloadThanks } from './platform';
import { initMotionToggle } from './motion';
import { initFavicon } from './favicon';
import { initOffscreen } from './offscreen';
import { slumber } from '../cat/slumber';

startEnv();
// Whether the cat starts the visit asleep is decided before any cat is made, so each is drawn right at once.
slumber.start();
initTheme();
initHeader();
initReveal();
const hero = document.querySelector<HTMLElement>('[data-hero]');
if (hero) initHero(hero);
document.querySelectorAll<HTMLElement>('[data-personality]').forEach(initPersonality);
initDemos();
const film = document.querySelector<HTMLElement>('[data-film]');
if (film) initFilm(film);
initVignettes();
initPlatform();
initDownloadThanks();
initMotionToggle();
initFavicon();
initOffscreen();
// Every cat that starts asleep has been drawn asleep by now: they may be seen.
slumber.ready();

// Test hook (development only): look at, and drive, the cat's sleep from the console or a headless probe.
if (import.meta.env.DEV) {
  void import('../cat/actor').then(({ catActors }) => {
    (window as unknown as { __nookCat?: unknown }).__nookCat = { slumber, env, actors: catActors };
  });
}

// The scroll-driven parts load once the page is quiet, so the first paint does not wait for them.
const later = (fn: () => void): void => {
  const w = window as Window & { requestIdleCallback?: (f: () => void, o?: { timeout: number }) => number };
  if (w.requestIdleCallback) w.requestIdleCallback(fn, { timeout: 1200 }); else window.setTimeout(fn, 200);
};
later(() => {
  void import('./smooth').then((m) => m.initSmooth());
  const story = document.querySelector<HTMLElement>('[data-story]');
  if (story) {
    let stop: (() => void) | null = null;
    const boot = () => import('./story').then((m) => { stop = m.initStory(story); });
    void boot();
    // A change of the motion setting rebuilds the scene (a still one, or the scrolling one).
    env.on('motion', () => { stop?.(); stop = null; void boot(); });
  }
});
