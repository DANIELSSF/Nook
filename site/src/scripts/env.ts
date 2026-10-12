/**
 * What the page knows about its surroundings: the pointer, the clock, whether motion is welcome, whether the tab is visible,
 * whether the device is touch, how fast the page is scrolling. Everything that reacts to the visitor reads it from here, so
 * there is one listener per signal instead of one per element.
 */
import { hourNow, isNight } from '../cat/night';

export type DayPart = 'morning' | 'day' | 'evening' | 'night';

/**
 * The part of the day, which tilts the cat's mood: sleepier at night, stretchier in the morning (the app's boundaries). The night is
 * the one the cat sleeps in (`NIGHT`, 23:00 to 6:00), so the two cannot drift apart.
 */
export const dayPartOf = (hour: number): DayPart => (isNight(hour) ? 'night' : hour < 10 ? 'morning' : hour < 18 ? 'day' : 'evening');

type Topic = 'motion' | 'visibility' | 'theme' | 'touch';
type Listener = () => void;

const listeners: Record<Topic, Set<Listener>> = { motion: new Set(), visibility: new Set(), theme: new Set(), touch: new Set() };
const emit = (topic: Topic) => listeners[topic].forEach((fn) => fn());

export const env = {
  /** Motion is not welcome: the OS asks for less (or the visitor chose so in the footer). */
  reduced: false,
  /** The device has no hover and a coarse pointer. */
  touch: false,
  /** The tab is in the background. */
  hidden: false,
  /** The resolved theme: what is on screen right now. */
  theme: 'dark' as 'light' | 'dark',
  /** The hour it is for the page: the visitor's clock, or the `?hora=` test override. */
  hour: hourNow(),
  dayPart: dayPartOf(hourNow()),
  pointer: { x: -1, y: -1, seen: false, lastMove: 0, lastDown: 0, kind: 'mouse' as string },
  /** The last time the visitor did anything (move, press, scroll, key): what makes the cat sleepy. */
  lastInput: performance.now() / 1000,
  /** Scroll speed in px/s, smoothed. Positive scrolls down. */
  scrollVelocity: 0,
  scrollY: 0,
  on(topic: Topic, fn: Listener): () => void {
    listeners[topic].add(fn);
    return () => listeners[topic].delete(fn);
  },
  /** Called by the cat loop once per frame to keep the scroll speed current. */
  sampleScroll(dt: number): void {
    // The position the last scroll event saw: reading window.scrollY here, after the frame's first writes, would make the
    // browser recompute styles on the spot, every frame.
    const y = latestY;
    if (dt > 0) {
      const v = (y - env.scrollY) / dt;
      env.scrollVelocity += (v - env.scrollVelocity) * Math.min(1, dt * 8);
    }
    env.scrollY = y;
  },
  /** Seconds since the visitor last did anything. */
  idleFor(): number { return performance.now() / 1000 - env.lastInput; },
};

const root = document.documentElement;
let latestY = window.scrollY;

function readMotion(): void {
  const manual = root.dataset['motion'];
  const mq = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const next = manual === 'reduced' ? true : manual === 'full' ? false : mq;
  if (next !== env.reduced) { env.reduced = next; root.classList.toggle('is-reduced', next); emit('motion'); }
}

function readTheme(): void {
  const t = root.dataset['theme'];
  const next = t === 'light' || t === 'dark' ? t : window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  if (next !== env.theme) { env.theme = next; emit('theme'); }
}

function readTouch(): void {
  const next = window.matchMedia('(hover: none) and (pointer: coarse)').matches;
  if (next !== env.touch) { env.touch = next; root.classList.toggle('is-touch', next); emit('touch'); }
}

let started = false;
export function startEnv(): void {
  if (started) return;
  started = true;
  const mqMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const mqTheme = window.matchMedia('(prefers-color-scheme: dark)');
  const mqTouch = window.matchMedia('(hover: none) and (pointer: coarse)');
  env.reduced = false; env.theme = 'dark';
  readMotion(); readTheme(); readTouch();
  mqMotion.addEventListener('change', readMotion);
  mqTheme.addEventListener('change', readTheme);
  mqTouch.addEventListener('change', readTouch);
  // Manual choices live on <html data-theme / data-motion>; watch them so a toggle anywhere reaches everyone.
  new MutationObserver(() => { readMotion(); readTheme(); }).observe(root, { attributes: true, attributeFilter: ['data-theme', 'data-motion'] });

  env.hidden = document.hidden;
  root.classList.toggle('is-hidden', env.hidden);
  document.addEventListener('visibilitychange', () => {
    env.hidden = document.hidden;
    root.classList.toggle('is-hidden', env.hidden);
    emit('visibility');
  });

  const seen = (e: PointerEvent) => {
    const p = env.pointer;
    p.x = e.clientX; p.y = e.clientY; p.seen = true; p.kind = e.pointerType;
    p.lastMove = performance.now() / 1000;
    env.lastInput = p.lastMove;
  };
  window.addEventListener('pointermove', seen, { passive: true });
  window.addEventListener('pointerdown', (e) => { seen(e); env.pointer.lastDown = performance.now() / 1000; }, { passive: true });
  window.addEventListener('pointerleave', () => { env.pointer.seen = false; }, { passive: true });
  document.documentElement.addEventListener('mouseleave', () => { env.pointer.seen = false; });
  window.addEventListener('keydown', () => { env.lastInput = performance.now() / 1000; }, { passive: true });
  window.addEventListener('scroll', () => { env.lastInput = performance.now() / 1000; latestY = window.scrollY; }, { passive: true });
  latestY = env.scrollY = window.scrollY;
}
