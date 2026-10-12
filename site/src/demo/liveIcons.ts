import { iconMarkup, moves, type TabIconName } from '../lib/tabIcons';

/** A new picture twenty times a second: enough for a slow turn this small (the app's own rate). */
const FRAME_MS = 1000 / 20;

/**
 * Keeps the tab icons of one demo alive. An icon is an `<svg class="tabicon" data-icon="flame">` whose drawing comes from the
 * app's own geometry (`lib/tabIcons.ts`); it moves while it also has `is-moving`, which a script step adds ("while its AI works"),
 * and rests otherwise. Nothing runs unless `start()` was called, and the demo player calls it only while it plays, so a demo that
 * is off screen, a tab in the background and Reduce Motion cost nothing.
 */
export class LiveIcons {
  private raf = 0;
  private last = 0;
  private running = false;

  constructor(private readonly root: HTMLElement) {}

  start(): void {
    if (this.running) return;
    this.running = true;
    this.raf = requestAnimationFrame(this.tick);
  }

  stop(): void {
    this.running = false;
    cancelAnimationFrame(this.raf);
  }

  /** Draws every icon once: the moving ones `time` seconds into their movement (`null`: all of them at rest, for a still frame). */
  paint(time: number | null): void {
    this.root.querySelectorAll<SVGSVGElement>('svg.tabicon[data-icon]').forEach((svg) => {
      const icon = svg.dataset['icon'] as TabIconName;
      if (time !== null && svg.classList.contains('is-moving') && moves(icon)) {
        svg.innerHTML = iconMarkup(icon, time);
        delete svg.dataset['rest'];
      } else if (svg.dataset['rest'] !== '1') {
        svg.innerHTML = iconMarkup(icon, null);
        svg.dataset['rest'] = '1';
      }
    });
  }

  private tick = (now: number): void => {
    if (!this.running) return;
    this.raf = requestAnimationFrame(this.tick);
    if (now - this.last < FRAME_MS) return;
    this.last = now;
    this.paint(now / 1000);
  };
}
