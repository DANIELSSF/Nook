/**
 * Whether the page's cat is asleep: one state, shared by every cat that sleeps with it (the hero's, the stage's, the one by the
 * download), so waking one wakes them all.
 *
 * The visit begins asleep when it is night for the visitor (see `night.ts`) and the page is dark. It is woken by a touch (a click,
 * a tap, Enter or Space on it), or by the light: if the page turns light while it sleeps, it wakes squinting. Once woken it stays
 * awake for the rest of the visit (sessionStorage), and going back to dark does not put it back to sleep; only a long quiet, at
 * night and in the dark, lets it doze off again. Nobody wakes all at once: the cats do the waking, slowly (see `anim.ts`).
 */
import { env } from '../scripts/env';
import { AWAKE_KEY, dozeAfter, hourNow, isNight } from './night';

export type WakeCause = 'touch' | 'light';
export type SlumberEvent = { type: 'wake'; cause: WakeCause } | { type: 'doze' };

const root = document.documentElement;

class Slumber {
  /** The cat is asleep. */
  asleep = false;
  private started = false;
  private listeners = new Set<(e: SlumberEvent) => void>();

  on(fn: (e: SlumberEvent) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit(e: SlumberEvent): void { this.listeners.forEach((fn) => fn(e)); }

  /** Decides how the visit begins and starts watching for the light and for the quiet. Call once, after `startEnv()`. */
  start(): void {
    if (this.started) return;
    this.started = true;
    let woken = false;
    try { woken = sessionStorage.getItem(AWAKE_KEY) === 'awake'; } catch { /* storage may be blocked */ }
    this.asleep = isNight(env.hour) && env.theme === 'dark' && !woken;
    this.mirror();
    // The light comes on (the toggle, or the system turning light): a sleeper wakes, squinting.
    env.on('theme', () => { if (this.asleep && env.theme === 'light') this.wake('light'); });
    // Coming back to the tab counts as being there, so the cat does not doze the moment you return.
    env.on('visibility', () => { if (!env.hidden) env.lastInput = performance.now() / 1000; });
    window.setInterval(() => this.watchQuiet(), 5000);
  }

  /** The first frames are in: cats that start asleep may be seen now (see `html.cat-wait` in hero.css). */
  ready(): void { root.classList.remove('cat-wait'); }

  /** Wakes the page's cat. Nothing happens if it is awake already. */
  wake(cause: WakeCause): void {
    if (!this.asleep) return;
    this.asleep = false;
    try { sessionStorage.setItem(AWAKE_KEY, 'awake'); } catch { /* the cat just forgets */ }
    this.mirror();
    this.emit({ type: 'wake', cause });
  }

  /** Lets it fall asleep (after a long quiet). */
  doze(): void {
    if (this.asleep) return;
    this.asleep = true;
    this.mirror();
    this.emit({ type: 'doze' });
  }

  private mirror(): void { root.classList.toggle('cat-asleep', this.asleep); }

  private watchQuiet(): void {
    if (this.asleep || env.hidden || env.reduced) return;
    if (env.theme !== 'dark' || !isNight(hourNow())) return;
    if (env.idleFor() >= dozeAfter()) this.doze();
  }
}

export const slumber = new Slumber();

/**
 * Makes the element a cat sleeps in (or on) something a keyboard can wake while it sleeps: focusable, a button, named «Despertar al
 * gato»; Enter or Space wake it. When it is awake the element goes back to what it was. A click wakes it too, for elements that
 * have no click of their own.
 */
export function wakeButton(host: HTMLElement, label: string): void {
  const was = { tabindex: host.getAttribute('tabindex'), role: host.getAttribute('role'), label: host.getAttribute('aria-label') };
  const put = (name: string, value: string | null) => { if (value === null) host.removeAttribute(name); else host.setAttribute(name, value); };
  const sync = () => {
    if (slumber.asleep) {
      host.setAttribute('tabindex', '0'); host.setAttribute('role', 'button'); host.setAttribute('aria-label', label);
    } else {
      put('tabindex', was.tabindex); put('role', was.role); put('aria-label', was.label);
    }
  };
  host.addEventListener('click', () => slumber.wake('touch'));
  host.addEventListener('keydown', (e) => {
    if ((e.key === 'Enter' || e.key === ' ') && slumber.asleep) { e.preventDefault(); slumber.wake('touch'); }
  });
  slumber.on(sync);
  sync();
}
