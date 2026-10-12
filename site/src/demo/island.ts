import { gsap } from 'gsap';

/**
 * The island's morph, the way the app does it: the window (here, the box) keeps its size and a mask grows. The mask is three
 * custom properties (--c-ix, --c-iy, --c-r) that the CSS turns into clip-paths for the rim, the body and the content, so the
 * island opens from the notch without a single layout property changing. `--open` (0 collapsed, 1 open) carries the cat to the
 * corner and crossfades what the strip shows.
 */
export type IslandStateName = 'collapsed' | 'peek' | 'open' | 'tall';

export interface IslandShape { w: number; h: number; r: number; open: number }

export const COMPACT = { w: 248, h: 36, r: 16 };
export const PEEK = { w: 372, h: 106, r: 24 };

export class IslandController {
  readonly el: HTMLElement;
  /** Full width, open height and tall height, in px. */
  W = 0;
  OH = 0;
  TH = 0;
  cur: IslandShape = { w: 0, h: 0, r: 0, open: 1 };
  name: IslandStateName = 'open';
  private tween: gsap.core.Tween | null = null;

  constructor(el: HTMLElement) {
    this.el = el;
    this.measure();
    this.name = (el.dataset['state'] as IslandStateName | undefined) ?? 'open';
    this.cur = this.shape(this.name);
    this.write(this.cur);
  }

  measure(): void {
    const cs = getComputedStyle(this.el);
    this.W = this.el.offsetWidth;
    this.OH = parseFloat(cs.getPropertyValue('--oh')) || 300;
    this.TH = parseFloat(cs.getPropertyValue('--th')) || this.OH;
  }

  shape(name: IslandStateName): IslandShape {
    switch (name) {
      case 'collapsed': return { ...COMPACT, w: Math.min(COMPACT.w, this.W), open: 0 };
      case 'peek': return { ...PEEK, w: Math.min(PEEK.w, this.W), open: 0 };
      case 'tall': return { w: this.W, h: this.TH, r: 28, open: 1 };
      default: return { w: this.W, h: this.OH, r: 28, open: 1 };
    }
  }

  write(s: IslandShape): void {
    const st = this.el.style;
    st.setProperty('--c-ix', `${(this.W - s.w) / 2}px`);
    st.setProperty('--c-iy', `${Math.max(0, this.el.offsetHeight - s.h)}px`);
    st.setProperty('--c-r', `${s.r}px`);
    st.setProperty('--open', String(Math.round(s.open * 1000) / 1000));
  }

  /** Jumps to a state. */
  set(name: IslandStateName): void {
    this.tween?.kill();
    this.name = name;
    this.cur = this.shape(name);
    this.el.dataset['state'] = name;
    this.write(this.cur);
  }

  /** Re-measures after a resize and redraws the current state. */
  refit(): void {
    this.measure();
    this.cur = this.shape(this.name);
    this.write(this.cur);
  }

  /** A tween between two named states that does not depend on where the island is now: for timelines, which may seek anywhere. */
  morph(from: IslandStateName, to: IslandStateName, vars: gsap.TweenVars = {}): gsap.core.Tween {
    const a = this.shape(from);
    const b = this.shape(to);
    const proxy = { ...a };
    return gsap.to(proxy, {
      w: b.w, h: b.h, r: b.r, open: b.open, ease: 'expo.out', duration: 0.9, ...vars,
      onUpdate: () => { this.cur = { ...proxy }; this.write(proxy); },
    });
  }

  /** Morphs to `name`. Returns the tween (so a timeline can place it). */
  to(name: IslandStateName, vars: { duration?: number; ease?: string; onComplete?: () => void } = {}): gsap.core.Tween {
    this.tween?.kill();
    const target = this.shape(name);
    this.name = name;
    this.el.dataset['state'] = name;
    const from = { ...this.cur };
    const proxy = { ...from };
    this.tween = gsap.to(proxy, {
      w: target.w, h: target.h, r: target.r, open: target.open,
      duration: vars.duration ?? 0.9, ease: vars.ease ?? 'expo.out',
      onUpdate: () => { this.cur = { ...proxy }; this.write(proxy); },
      onComplete: vars.onComplete,
    });
    return this.tween;
  }
}
