import { DemoPlayer } from './player';
import type { SceneDef } from './types';
import { env } from '../scripts/env';

type SceneModule = { default: (copy: any) => SceneDef };
/** One module per scene, loaded when its demo is about to scroll into view. */
const loaders = import.meta.glob<SceneModule>('./scenes/*.ts');

/**
 * Starts every demo on the page. A demo is built when it is within a screen or so of the viewport, plays only while at least a
 * third of it is visible and the tab is in front, and stops (showing a still frame) when the visitor asks for less motion.
 */
export function initDemos(root: ParentNode = document, opts: { once?: boolean; onReady?: (p: DemoPlayer) => void } = {}): Map<HTMLElement, DemoPlayer> {
  const players = new Map<HTMLElement, DemoPlayer>();
  const visible = new Map<HTMLElement, boolean>();
  const left = new Map<HTMLElement, number>();

  const sync = (el: HTMLElement) => {
    const p = players.get(el);
    if (!p) return;
    const should = !!visible.get(el) && !env.hidden && !env.reduced;
    if (should) {
      const away = left.get(el);
      // Come back to a demo that has been away for a while and it starts from its first frame.
      if (away !== undefined && performance.now() - away > 4000) { p.restart(); left.delete(el); }
      else if (!p.isPlaying) p.play();
    } else {
      if (!visible.get(el) && !left.has(el)) left.set(el, performance.now());
      p.pause();
    }
  };

  async function boot(el: HTMLElement): Promise<void> {
    const id = el.dataset['demo'] ?? '';
    const load = loaders[`./scenes/${id}.ts`];
    if (!load) return;
    const mod = await load();
    const copyEl = el.querySelector('[data-demo-copy]');
    const copy = copyEl?.textContent ? JSON.parse(copyEl.textContent) : {};
    const player = new DemoPlayer(el, mod.default(copy), { once: opts.once });
    player.init();
    players.set(el, player);
    opts.onReady?.(player);
    const watch = new IntersectionObserver((entries) => {
      for (const e of entries) { visible.set(el, e.isIntersecting && e.intersectionRatio >= 0.3); sync(el); }
    }, { threshold: [0, 0.3, 0.6] });
    watch.observe(el);
  }

  const near = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      near.unobserve(e.target);
      void boot(e.target as HTMLElement);
    }
  }, { rootMargin: '900px 0px' });
  root.querySelectorAll<HTMLElement>('[data-demo]').forEach((el) => near.observe(el));

  // Handy for tuning a script from the console (`__nookDemos`); not part of the shipped page.
  if (import.meta.env.DEV) (window as unknown as { __nookDemos?: Map<HTMLElement, DemoPlayer> }).__nookDemos = players;
  env.on('motion', () => players.forEach((p, el) => { if (env.reduced) p.showPoster(); else { p.resumeMotion(!!visible.get(el) && !env.hidden); sync(el); } }));
  env.on('visibility', () => players.forEach((_, el) => sync(el)));
  return players;
}
