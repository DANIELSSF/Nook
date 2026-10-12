import { gsap } from 'gsap';
import type { Anchor, Fx, PlayerContext, SceneDef, Step, Target, Vars } from './types';
import { Geometry } from './geometry';
import { camTransform, clampCam, fitCam, type Cam, type Frame } from './camera';
import { planPath, pointAt, reachTime, type Pt } from './cursor';
import { planTyping, typedCount } from './typing';
import { IslandController, type IslandStateName } from './island';
import { LiveIcons } from './liveIcons';
import { CatActor, runCat, type PointerLike } from '../cat/actor';
import * as A from '../cat/anim';
import { bindCat, defaultLook, type CatView } from '../cat/render';
import type { Pose } from '../cat/pose';
import { hashString } from './rng';
import { env } from '../scripts/env';

/**
 * Plays a scripted scene on a styled frame, the way Recordly shows a screen recording: a window on a soft wallpaper, a smooth
 * cursor that glides along eased arcs, click ripples, a camera that eases into the area being used and back out, typing with a
 * human cadence, and keystroke chips. Everything is DOM and SVG, so it stays crisp at any size and weighs nothing; one GSAP
 * timeline drives all of it, so it can be paused, sought and looped, and shown as a still frame when motion is not welcome.
 *
 * The scene is laid out at a fixed design size (640 × 400) and the camera scales it to the window. Every position the script
 * names is measured from the markup at build time and baked into the timeline, which is rebuilt when the window is resized.
 */

const FX: Record<Fx, { from: Vars; to: Vars; out: Vars }> = {
  fade: { from: { autoAlpha: 0 }, to: { autoAlpha: 1 }, out: { autoAlpha: 0 } },
  rise: { from: { autoAlpha: 0, y: 10 }, to: { autoAlpha: 1, y: 0 }, out: { autoAlpha: 0, y: -6 } },
  drop: { from: { autoAlpha: 0, y: -10 }, to: { autoAlpha: 1, y: 0 }, out: { autoAlpha: 0, y: -8 } },
  pop: { from: { autoAlpha: 0, scale: 0.93 }, to: { autoAlpha: 1, scale: 1 }, out: { autoAlpha: 0, scale: 0.96 } },
  slide: { from: { autoAlpha: 0, x: 16 }, to: { autoAlpha: 1, x: 0 }, out: { autoAlpha: 0, x: 12 } },
};

/** How far along the clock a move with `power2.inOut` has got when it is `u` of the way there (the inverse of that ease). */
const easeTime = (u: number): number => (u <= 0.5 ? Math.sqrt(u / 2) : 1 - Math.sqrt((1 - u) / 2));

/** The cat's scenes a `pose` step can play: each is the pose `u` seconds after the scene began. */
const SCENES: Record<'sad', (u: number) => Pose> = {
  sad: (u) => A.sad(u, A.sadAmount(u)),
};

interface CompileState {
  /** End of the sequence so far, and the start of the last step (for `with`). */
  t: number;
  last: number;
  cursor: Pt;
  cursorShown: boolean;
  cam: Cam;
  caption: HTMLElement | null;
  carry: { el: HTMLElement; dx: number; dy: number } | null;
  island: Map<string, IslandStateName>;
  typed: Map<HTMLElement, string>;
  shown: Map<HTMLElement, boolean>;
  scroll: Map<HTMLElement, number>;
  /** What each class of each element is at this point of the script: the timeline sets it explicitly, never relatively. */
  classes: Map<HTMLElement, Map<string, boolean>>;
  moves: number;
}

export interface PlayerOptions {
  /** Plays once and reports when it is done (for exporting clips), instead of looping. */
  once?: boolean;
}

export class DemoPlayer implements PlayerContext {
  readonly root: HTMLElement;
  readonly def: SceneDef;
  private screen: HTMLElement;
  private camera: HTMLElement;
  private scene: HTMLElement;
  private cursor: HTMLElement;
  private cursorInner: HTMLElement;
  private ripple: HTMLElement;
  private keysHost: HTMLElement;
  private capHost: HTMLElement;
  private geo: Geometry;
  private frame: Frame = { screenW: 640, screenH: 400, designW: 640, designH: 400 };
  private camState: Cam = { cx: 320, cy: 200, k: 1 };
  private cursorPos: Pt = { x: -100, y: -100 };
  private cursorVisible = false;
  private tl: gsap.core.Timeline | null = null;
  private islands = new Map<string, IslandController>();
  private cats = new Map<string, CatActor>();
  private catCleanups: (() => void)[] = [];
  /** The cats a `pose` step paints (the sad cat of the quit card), bound once. */
  private posed = new Map<SVGSVGElement, CatView>();
  /** The tab icons that move while a script says their tab works. */
  private icons: LiveIcons;
  private resets: (() => void)[] = [];
  private captions: string[] = [];
  private ro: ResizeObserver | null = null;
  private resizeTimer = 0;
  private wantPlay = false;
  private opts: PlayerOptions;
  /** Resolves when a `once` run reaches its end. */
  done: Promise<void>;
  private finish: () => void = () => {};
  duration = 0;
  /** Where each step starts and how long it takes (for tuning a script). */
  trace: { do: string; at: number; d: number }[] = [];

  constructor(root: HTMLElement, def: SceneDef, opts: PlayerOptions = {}) {
    this.root = root;
    this.def = def;
    this.opts = opts;
    const need = (sel: string) => {
      const el = root.querySelector<HTMLElement>(sel);
      if (!el) throw new Error(`demo "${def.id}": missing ${sel}`);
      return el;
    };
    this.screen = need('[data-screen]');
    this.camera = need('[data-camera]');
    this.scene = need('[data-scene]');
    this.cursor = need('[data-cursor]');
    this.cursorInner = need('[data-cursor-inner]');
    this.ripple = need('[data-ripple]');
    this.keysHost = need('[data-keys]');
    this.capHost = need('[data-caption]');
    this.geo = new Geometry(this.scene);
    this.icons = new LiveIcons(root);
    this.captions = Array.from(root.querySelectorAll('[data-steps] li')).map((li) => li.textContent?.trim() ?? '');
    this.done = new Promise((res) => { this.finish = res; });
    this.scene.querySelectorAll<HTMLElement>('[data-island]').forEach((el) => this.islands.set(el.dataset['t'] ?? 'island', new IslandController(el)));
    this.makeCats();
  }

  // MARK: Context for `call` steps

  q(name: string): HTMLElement | null { return this.geo.el(name); }

  // MARK: Setup

  private makeCats(): void {
    // The cat watches the demo's cursor, not the visitor's.
    const pointerSource = (): PointerLike | null => {
      if (!this.cursorVisible) return null;
      const r = this.cursor.getBoundingClientRect();
      return { x: r.left, y: r.top, seen: true, lastMove: performance.now() / 1000, lastDown: 0 };
    };
    this.scene.querySelectorAll<HTMLElement>('[data-island]').forEach((island) => {
      const svg = island.querySelector<SVGSVGElement>('[data-cat-host] svg.cat');
      if (!svg) return;
      const actor = new CatActor(svg, { pointer: true, activity: 0, hop: 4, pointerSource });
      this.cats.set(island.dataset['t'] ?? 'island', actor);
      this.catCleanups.push(runCat(actor, island));
    });
    // The big cats on a stage (the home and the greeting): the same cat, drawn large, that looks at the cursor and hops when asked.
    this.scene.querySelectorAll<HTMLElement>('[data-stage-cat]').forEach((host) => {
      const svg = host.querySelector<SVGSVGElement>('svg.cat');
      if (!svg) return;
      const actor = new CatActor(svg, { pointer: true, activity: 0, hop: 5, pointerSource });
      this.cats.set(host.dataset['stageCat'] ?? 'stage', actor);
      this.catCleanups.push(runCat(actor, host));
    });
  }

  /** Measures the window, builds the timeline and puts the scene at its first frame. */
  init(): void {
    this.layout();
    this.build();
    this.ro = new ResizeObserver(() => {
      window.clearTimeout(this.resizeTimer);
      this.resizeTimer = window.setTimeout(() => this.relayout(), 120);
    });
    this.ro.observe(this.screen);
    if (env.reduced) this.showPoster();
  }

  private layout(): void {
    const sw = this.scene.offsetWidth, sh = this.scene.offsetHeight;
    this.frame = { screenW: this.screen.clientWidth, screenH: this.screen.clientHeight, designW: sw, designH: sh };
    this.islands.forEach((c) => c.refit());
  }

  private relayout(): void {
    if (!this.tl) return;
    const time = this.tl.time();
    const playing = this.tl.isActive();
    this.layout();
    this.build();
    if (env.reduced) { this.showPoster(); return; }
    this.goto(time);
    if (playing && this.wantPlay) this.tl?.play();
  }

  // MARK: Camera and cursor

  private applyCam(c: Cam): void {
    this.camState = c;
    const { tx, ty } = camTransform(this.frame, c);
    this.camera.style.transform = `translate3d(${tx.toFixed(2)}px, ${ty.toFixed(2)}px, 0) scale(${c.k.toFixed(4)})`;
    this.paintCursor();
  }

  /** The cursor keeps about the same size on screen whatever the zoom. */
  private cursorScale(k = this.camState.k): number { return Math.min(2.4, Math.max(0.7, 1 / Math.pow(k, 0.85))); }

  private paintCursor(): void {
    const s = this.cursorScale();
    this.cursor.style.transform = `translate3d(${this.cursorPos.x.toFixed(2)}px, ${this.cursorPos.y.toFixed(2)}px, 0) scale(${s.toFixed(3)})`;
  }

  private setCursor(x: number, y: number): void {
    this.cursorPos = { x, y };
    this.paintCursor();
  }

  // MARK: Compiling a script into a timeline

  private els(target: Target): HTMLElement[] {
    const names = Array.isArray(target) ? target : [target];
    const out: HTMLElement[] = [];
    for (const n of names) {
      if (n === '@cursor') { out.push(this.cursor); continue; }
      this.scene.querySelectorAll<HTMLElement>(`[data-t="${n}"]`).forEach((e) => out.push(e));
      if (!this.scene.querySelector(`[data-t="${n}"]`)) throw new Error(`demo "${this.def.id}": no element named "${n}"`);
    }
    return out;
  }

  private build(): void {
    this.tl?.kill();
    this.resets = [];
    this.keysHost.replaceChildren();
    this.capHost.replaceChildren();
    this.geo = new Geometry(this.scene);
    const fit = fitCam(this.frame);
    const start: Pt = this.def.cursorStart ? this.geo.point(this.def.cursorStart) : { x: this.frame.designW + 60, y: this.frame.designH * 0.72 };
    const st: CompileState = {
      t: 0, last: 0, cursor: start, cursorShown: false, cam: fit, caption: null, carry: null,
      island: new Map(), typed: new Map(), shown: new Map(), scroll: new Map(), classes: new Map(), moves: 0,
    };
    this.islands.forEach((c, id) => st.island.set(id, (this.def.islands?.[id] ?? (c.el.dataset['state'] as IslandStateName | undefined) ?? 'open')));
    const tl = gsap.timeline({ paused: true });

    this.trace = [];
    for (const step of this.def.steps) {
      const at = step.at ?? (step.with ? st.last : st.t) + (step.delay ?? 0);
      const d = this.compile(tl, st, step, at);
      this.trace.push({ do: step.do, at: +at.toFixed(2), d: +d.toFixed(2) });
      st.last = at;
      st.t = Math.max(st.t, at + d);
    }
    const hold = this.def.hold ?? 1.6;
    // Extend the timeline over the hold, so the last frame stays before the loop starts over.
    tl.set({}, {}, st.t + hold);
    tl.eventCallback('onComplete', () => {
      if (this.opts.once) { this.finish(); return; }
      this.reset();
      this.tl?.restart(false);
    });
    this.tl = tl;
    this.duration = tl.duration();

    // Where everything is at the first frame.
    this.resets.push(() => {
      this.cursorVisible = false;
      gsap.set(this.cursor, { autoAlpha: 0 });
      gsap.set(this.cursorInner, { scale: 1 });
      gsap.set(this.ripple, { autoAlpha: 0 });
      this.cursorPos = { ...start };
      this.applyCam(fit);
      this.islands.forEach((c, id) => c.set(this.def.islands?.[id] ?? 'open'));
    });
    this.reset();
  }

  /** Puts every element the script touches back where the first frame has it. */
  reset(): void {
    this.resets.forEach((fn) => fn());
  }

  private compile(tl: gsap.core.Timeline, st: CompileState, step: Step, at: number): number {
    switch (step.do) {
      case 'wait': return step.t;
      case 'label': tl.addLabel(step.name, at); return 0;
      case 'caption': return this.stepCaption(tl, st, step.n, at);
      case 'show':
      case 'hide': return this.stepVisibility(tl, st, step, at);
      case 'set': tl.set(this.els(step.target), step.vars, at); return 0;
      case 'tween': {
        const d = step.t ?? 0.5;
        const els = this.els(step.target);
        const to = { ...step.vars, duration: d, ease: step.ease ?? 'power2.out', immediateRender: false };
        if (step.from) tl.fromTo(els, step.from, to, at); else tl.to(els, to, at);
        return d;
      }
      case 'class': {
        this.els(step.target).forEach((el) => {
          step.add?.split(' ').filter(Boolean).forEach((c) => this.classAt(tl, st, el, c, true, at));
          step.remove?.split(' ').filter(Boolean).forEach((c) => this.classAt(tl, st, el, c, false, at));
        });
        return 0;
      }
      case 'text': {
        const el = this.geo.el(step.target);
        if (!el) throw new Error(`demo "${this.def.id}": no element named "${step.target}"`);
        const was = el.textContent ?? '';
        if (!st.typed.has(el)) { st.typed.set(el, was); this.resets.push(() => { el.textContent = was; }); }
        const before = st.typed.get(el) as string;
        const proxy = { v: 0 };
        tl.fromTo(proxy, { v: 0 }, { v: 1, duration: 0.001, immediateRender: false, onUpdate: () => { el.textContent = proxy.v >= 1 ? step.text : before; } }, at);
        st.typed.set(el, step.text);
        return 0;
      }
      case 'island': return this.stepIsland(tl, st, step, at);
      case 'move': return this.stepMove(tl, st, step.to, step.t, step.arc, step.ease, at);
      case 'click': return this.stepClick(tl, st, step, at);
      case 'carry': return this.stepCarry(tl, st, step, at);
      case 'drag': return this.stepDrag(tl, st, step, at);
      case 'pose': return this.stepPose(tl, st, step, at);
      case 'type': return this.stepType(tl, st, step, at);
      case 'keys': return this.stepKeys(tl, step, at);
      case 'zoom': return this.stepZoom(tl, st, step, at);
      case 'scroll': return this.stepScroll(tl, st, step, at);
      case 'cat': {
        const actor = this.cats.get(step.target ?? 'island');
        if (!actor) return 0;
        const was = actor.working;
        this.resets.push(() => actor.setWorking(was));
        tl.call(() => {
          if (step.action === 'perk') actor.perk();
          else if (step.action === 'celebrate') actor.celebrate();
          else if (step.action === 'wave') actor.start('wave');
          else actor.setWorking(step.action === 'work');
        }, [], at);
        return 0;
      }
      case 'call': tl.call(() => step.fn(this), [], at); return 0;
    }
  }

  /**
   * Sets a class on or off at `at`. It is a zero-length tween whose update says what the class is, from what the script knows it
   * was just before, so it is right whichever way the timeline is played, rewound or sought (GSAP's own `className` tweens keep
   * a snapshot of the whole attribute, and several of them on one element undo each other).
   */
  private classAt(tl: gsap.core.Timeline, st: CompileState, el: HTMLElement, cls: string, on: boolean, at: number): void {
    let known = st.classes.get(el);
    if (!known) { known = new Map(); st.classes.set(el, known); }
    if (!known.has(cls)) {
      const had = el.classList.contains(cls);
      known.set(cls, had);
      this.resets.push(() => { el.classList.toggle(cls, had); });
    }
    const before = known.get(cls) as boolean;
    const proxy = { v: 0 };
    tl.fromTo(proxy, { v: 0 }, { v: 1, duration: 0.001, immediateRender: false, onUpdate: () => { el.classList.toggle(cls, proxy.v >= 1 ? on : before); } }, at);
    known.set(cls, on);
  }

  private stepCaption(tl: gsap.core.Timeline, st: CompileState, n: number | null, at: number): number {
    const text = n === null ? null : this.captions[n];
    if (st.caption) tl.to(st.caption, { autoAlpha: 0, y: -4, duration: 0.25, ease: 'power1.in' }, at);
    if (text === null || text === undefined) { st.caption = null; return 0; }
    const el = document.createElement('div');
    el.className = 'demo__cap';
    const num = document.createElement('span');
    num.className = 'demo__cap-n';
    num.textContent = String((n as number) + 1);
    el.append(num, document.createTextNode(text));
    this.capHost.appendChild(el);
    gsap.set(el, { autoAlpha: 0 });
    tl.fromTo(el, { autoAlpha: 0, y: 8 }, { autoAlpha: 1, y: 0, duration: 0.4, ease: 'power2.out', immediateRender: false }, at + 0.1);
    st.caption = el;
    return 0;
  }

  private stepVisibility(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'show' | 'hide' }>, at: number): number {
    const fx = FX[step.fx ?? 'fade'];
    const d = step.t ?? 0.4;
    const els = this.els(step.target);
    const showing = step.do === 'show';
    els.forEach((el) => {
      if (st.shown.has(el)) return;
      // The first thing the script does to an element says how it starts: showing it means it starts hidden, hiding it means it
      // starts visible. The markup shows the finished frame, so the first frame has to be set explicitly, either way.
      st.shown.set(el, !showing);
      if (el !== this.cursor) this.resets.push(() => { gsap.set(el, showing ? fx.from : fx.to); });
    });
    tl.fromTo(els, showing ? fx.from : fx.to, { ...(showing ? fx.to : fx.out), duration: d, ease: showing ? 'power3.out' : 'power2.in', stagger: step.stagger ?? 0, immediateRender: false }, at);
    if (els.includes(this.cursor)) {
      st.cursorShown = showing;
      tl.call(() => { this.cursorVisible = showing; }, [], at);
    }
    return d + (step.stagger ?? 0) * Math.max(0, els.length - 1);
  }

  private stepIsland(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'island' }>, at: number): number {
    const id = step.target ?? 'island';
    const ctrl = this.islands.get(id);
    if (!ctrl) throw new Error(`demo "${this.def.id}": no island named "${id}"`);
    const from = st.island.get(id) ?? 'open';
    const d = step.t ?? 0.9;
    tl.add(ctrl.morph(from, step.state, { duration: d, ease: step.ease ?? 'expo.out' }), at);
    st.island.set(id, step.state);
    return d;
  }

  private stepMove(tl: gsap.core.Timeline, st: CompileState, to: Anchor, t: number | undefined, arc: number | undefined, ease: string | undefined, at: number): number {
    const target = this.geo.point(to);
    const from = st.cursor;
    const path = planPath(from, target, hashString(this.def.id) + st.moves++ * 7919, arc);
    const d = t ?? reachTime(path.length);
    if (!st.cursorShown) {
      tl.fromTo(this.cursor, { autoAlpha: 0 }, { autoAlpha: 1, duration: 0.3, ease: 'power1.out', immediateRender: false }, at);
      tl.call(() => { this.cursorVisible = true; }, [], at);
      st.cursorShown = true;
    }
    const carry = st.carry;
    const proxy = { u: 0 };
    tl.fromTo(proxy, { u: 0 }, {
      u: 1, duration: d, ease: ease ?? 'power2.inOut', immediateRender: false,
      onUpdate: () => {
        const p = pointAt(path, proxy.u);
        this.setCursor(p.x, p.y);
        if (carry) gsap.set(carry.el, { x: p.x + carry.dx, y: p.y + carry.dy });
      },
    }, at);
    st.cursor = target;
    return d;
  }

  private stepClick(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'click' }>, at: number): number {
    // The camera starts to close in as the cursor sets off, so it is there when the click lands.
    if (step.zoom && step.to) this.stepZoom(tl, st, { do: 'zoom', to: step.to, scale: step.zoom, t: 1.1 }, at + 0.15);
    let d = 0;
    if (step.to) d = this.stepMove(tl, st, step.to, undefined, undefined, undefined, at) + 0.08;
    const when = at + d;
    const p = st.cursor;
    const pressEl = step.press ? this.geo.el(step.press) : step.to ? this.geo.anchorEl(step.to) : null;
    const comp = this.cursorScale(st.cam.k);
    // The cursor dips and springs back; a ring spreads from the tip.
    tl.fromTo(this.cursorInner, { scale: 1 }, { scale: 0.78, duration: 0.09, ease: 'power2.in', transformOrigin: '2px 2px', immediateRender: false }, when);
    tl.to(this.cursorInner, { scale: 1, duration: 0.3, ease: 'back.out(2.4)' }, when + 0.09);
    const right = step.kind === 'right';
    this.classAt(tl, st, this.ripple, 'is-right', right, when);
    tl.fromTo(this.ripple, { x: p.x, y: p.y, scale: 0.25 * comp, autoAlpha: 0.95 }, { x: p.x, y: p.y, scale: 1.7 * comp, autoAlpha: 0, duration: 0.6, ease: 'power2.out', immediateRender: false }, when);
    if (pressEl) {
      this.classAt(tl, st, pressEl, 'is-press', true, when);
      this.classAt(tl, st, pressEl, 'is-press', false, when + 0.17);
    }
    return d + 0.34;
  }

  private stepCarry(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'carry' }>, at: number): number {
    if (step.target === null) { st.carry = null; return 0; }
    const el = this.geo.el(step.target);
    if (!el) throw new Error(`demo "${this.def.id}": no element named "${step.target}"`);
    const carry = { el, dx: step.dx ?? 8, dy: step.dy ?? 10 };
    st.carry = carry;
    tl.set(el, { x: st.cursor.x + carry.dx, y: st.cursor.y + carry.dy, autoAlpha: 1 }, at);
    this.resets.push(() => { gsap.set(el, { x: 0, y: 0 }); });
    return 0;
  }

  /**
   * A tab dragged past its neighbours. The cursor takes hold (a press, a small ring), the tab lifts (`is-lifted`: a shadow and a
   * little more size) and follows the cursor sideways; as its edge passes the middle of a neighbour, that neighbour springs into the
   * room the tab leaves; the cursor lets go and the tab settles. Only offsets are tweened (`x`), so the markup keeps the order it had
   * and the positions the script measures stay where the layout put them. The cursor is expected to be on the tab already.
   *
   * How far each one goes is measured when the press happens (the row may have changed since the script was built: a tab renamed, a
   * marker added), by the same offsets the rest of the engine reads, which a transform does not move; the build only needs an estimate
   * of it, for the cursor's path and for when each neighbour gives way.
   */
  private stepDrag(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'drag' }>, at: number): number {
    const dragged = this.geo.el(step.target);
    const names = Array.isArray(step.over) ? step.over : [step.over];
    const others = names.map((n) => this.geo.el(n)) as HTMLElement[];
    if (!dragged || others.some((o) => !o) || !others.length) throw new Error(`demo "${this.def.id}": drag needs "${step.target}" and its neighbours`);
    /** Where each goes: the dragged one takes the place of the farthest neighbour, and every neighbour takes the room the dragged one leaves. */
    const measure = () => {
      const a = this.geo.rectOf(dragged);
      const rects = others.map((o) => this.geo.rectOf(o));
      const near = rects[0]!, far = rects[rects.length - 1]!;
      const toLeft = a.x > near.x;
      const gap = toLeft ? a.x - (near.x + near.w) : near.x - (a.x + a.w);
      return { a, rects, toLeft, shift: toLeft ? far.x - a.x : far.x + far.w - (a.x + a.w), aside: toLeft ? a.w + gap : -(a.w + gap) };
    };
    const first = measure();
    const live = { shift: first.shift, aside: first.aside };
    const move = step.t ?? 0.85, lead = 0.2;
    [dragged, ...others].forEach((el) => this.resets.push(() => { gsap.set(el, { x: 0 }); }));

    const from = st.cursor;
    const to = { x: from.x + first.shift, y: from.y };
    const path = planPath(from, to, hashString(this.def.id) + st.moves++ * 7919, 0);
    const comp = this.cursorScale(st.cam.k);
    // Press: the cursor dips and a ring spreads, as in a click, but the cursor stays down. The row is measured as it is now.
    tl.call(() => { const m = measure(); live.shift = m.shift; live.aside = m.aside; }, [], at);
    tl.fromTo(this.cursorInner, { scale: 1 }, { scale: 0.78, duration: 0.09, ease: 'power2.in', transformOrigin: '2px 2px', immediateRender: false }, at);
    this.classAt(tl, st, this.ripple, 'is-right', false, at);
    tl.fromTo(this.ripple, { x: from.x, y: from.y, scale: 0.25 * comp, autoAlpha: 0.95 }, { x: from.x, y: from.y, scale: 1.7 * comp, autoAlpha: 0, duration: 0.6, ease: 'power2.out', immediateRender: false }, at);
    this.classAt(tl, st, dragged, 'is-lifted', true, at + 0.1);
    // The carry: the cursor and the tab move together, one proxy for both so they cannot drift apart.
    const proxy = { u: 0 };
    tl.fromTo(proxy, { u: 0 }, {
      u: 1, duration: move, ease: 'power2.inOut', immediateRender: false,
      onUpdate: () => {
        const p = pointAt(path, proxy.u);
        this.setCursor(p.x, p.y);
        gsap.set(dragged, { x: live.shift * proxy.u });
      },
    }, at + lead);
    // Each neighbour gives way, with a spring, as the tab's leading edge passes its middle: the moment the carry's ease is that far along.
    others.forEach((el, i) => {
      const r = first.rects[i]!;
      const edge = first.toLeft ? first.a.x : first.a.x + first.a.w;
      const passed = Math.min(1, Math.max(0, (r.x + r.w / 2 - edge) / first.shift));
      tl.fromTo(el, { x: 0 }, { x: () => live.aside, duration: 0.55, ease: 'back.out(0.9)', immediateRender: false }, at + lead + move * easeTime(passed));
    });
    // Let go.
    const drop = at + lead + move + 0.06;
    this.classAt(tl, st, dragged, 'is-lifted', false, drop);
    tl.to(this.cursorInner, { scale: 1, duration: 0.3, ease: 'back.out(2.4)' }, drop);
    st.cursor = to;
    return lead + move + 0.5;
  }

  /** A scene of the cat played on a cat of the page as the timeline runs: the pose is a function of the time since the scene began. */
  private stepPose(tl: gsap.core.Timeline, _st: CompileState, step: Extract<Step, { do: 'pose' }>, at: number): number {
    const host = this.geo.el(step.target);
    const svg = host?.matches('svg') ? (host as unknown as SVGSVGElement) : host?.querySelector<SVGSVGElement>('svg.cat');
    if (!svg) throw new Error(`demo "${this.def.id}": no cat in "${step.target}"`);
    let view = this.posed.get(svg);
    if (!view) { view = bindCat(svg); this.posed.set(svg, view); }
    const scene = SCENES[step.scene];
    const paint = (u: number) => view.paint(scene(u), defaultLook);
    this.resets.push(() => paint(0));
    const proxy = { u: 0 };
    tl.fromTo(proxy, { u: 0 }, { u: step.t, duration: step.t, ease: 'none', immediateRender: false, onUpdate: () => paint(proxy.u) }, at);
    // It plays alongside whatever the script does next, so it does not hold the script back.
    return 0;
  }

  private stepType(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'type' }>, at: number): number {
    const el = this.geo.el(step.target);
    if (!el) throw new Error(`demo "${this.def.id}": no element named "${step.target}"`);
    if (step.zoom) this.stepZoom(tl, st, { do: 'zoom', to: step.target, scale: step.zoom, t: 0.9 }, at);
    if (!st.typed.has(el)) { const was = el.textContent ?? ''; st.typed.set(el, was); this.resets.push(() => { el.textContent = was; }); }
    const prefix = step.append ? (st.typed.get(el) ?? '') : '';
    const chars = Array.from(step.text);
    const plan = planTyping(step.text, step.cps ?? 14, step.seed ?? hashString(step.text));
    const proxy = { p: 0 };
    tl.fromTo(proxy, { p: 0 }, {
      p: plan.total, duration: Math.max(0.01, plan.total), ease: 'none', immediateRender: false,
      onUpdate: () => { el.textContent = prefix + chars.slice(0, typedCount(plan, proxy.p)).join(''); },
    }, at);
    st.typed.set(el, prefix + step.text);
    return plan.total;
  }

  private stepKeys(tl: gsap.core.Timeline, step: Extract<Step, { do: 'keys' }>, at: number): number {
    const chip = document.createElement('div');
    chip.className = 'demo__keychip';
    step.keys.forEach((k) => { const kbd = document.createElement('kbd'); kbd.textContent = k; chip.appendChild(kbd); });
    this.keysHost.appendChild(chip);
    gsap.set(chip, { autoAlpha: 0 });
    const hold = step.t ?? 1.0;
    tl.fromTo(chip, { autoAlpha: 0, y: 12, scale: 0.94 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.24, ease: 'back.out(1.7)', immediateRender: false }, at);
    tl.fromTo(chip.querySelectorAll('kbd'), { scale: 1 }, { scale: 0.9, duration: 0.09, yoyo: true, repeat: 1, ease: 'power1.inOut', immediateRender: false }, at + 0.26);
    tl.to(chip, { autoAlpha: 0, y: -6, duration: 0.32, ease: 'power2.in' }, at + hold);
    return hold * 0.6;
  }

  private stepZoom(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'zoom' }>, at: number): number {
    const fit = fitCam(this.frame);
    let target: Cam;
    if (step.to === 'fit') target = fit;
    else {
      // The camera centres on the point (an element's centre, or the spot named inside it) and magnifies the fit by `scale`. In
      // a small window it never goes below a size where the text reads, so it pans to the spot instead of fitting the area.
      const p = this.geo.point(step.to);
      const k = Math.max(fit.k * (step.scale ?? 1.35), Math.min(0.85, fit.k * 2.6));
      target = clampCam(this.frame, { cx: p.x, cy: p.y, k });
    }
    const d = step.t ?? 1.1;
    const proxy = { ...st.cam };
    tl.fromTo(proxy, { ...st.cam }, {
      ...target, duration: d, ease: step.ease ?? 'power3.inOut', immediateRender: false,
      onUpdate: () => this.applyCam({ cx: proxy.cx, cy: proxy.cy, k: proxy.k }),
    }, at);
    st.cam = target;
    return d;
  }

  private stepScroll(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'scroll' }>, at: number): number {
    const list = this.geo.el(step.list);
    if (!list) throw new Error(`demo "${this.def.id}": no element named "${step.list}"`);
    const view = list.parentElement as HTMLElement;
    let offset = 0;
    if (step.to === 'end') offset = list.offsetTop + list.offsetHeight + 10 - view.clientHeight;
    else if (step.to !== 'start') {
      const target = this.geo.el(step.to);
      if (!target) throw new Error(`demo "${this.def.id}": no element named "${step.to}"`);
      offset = list.offsetTop + target.offsetTop + target.offsetHeight + 10 - view.clientHeight;
    }
    offset = Math.max(0, offset);
    const from = st.scroll.get(list) ?? 0;
    if (!st.scroll.has(list)) this.resets.push(() => { gsap.set(list, { y: 0 }); });
    const d = step.t ?? 0.6;
    tl.fromTo(list, { y: -from }, { y: -offset, duration: d, ease: 'power2.out', immediateRender: false }, at);
    st.scroll.set(list, offset);
    return d;
  }

  // MARK: Playing

  /** Plays from where it is. Does nothing when motion is not welcome. */
  play(): void {
    this.wantPlay = true;
    if (env.reduced || env.hidden || !this.tl) return;
    this.tl.play();
    this.icons.start();
  }

  pause(): void {
    this.wantPlay = false;
    this.tl?.pause();
    this.icons.stop();
  }

  /** Starts over from the first frame. */
  restart(): void {
    if (!this.tl) return;
    this.reset();
    this.tl.restart(false);
    this.wantPlay = true;
    if (!env.reduced && !env.hidden) this.icons.start();
  }

  /** The still frame for Reduce Motion: the scene as it is at its `poster` label, with the captions listed beside it. */
  showPoster(): void {
    if (!this.tl) return;
    this.wantPlay = false;
    this.icons.stop();
    const at = this.tl.labels['poster'];
    this.goto(at ?? Math.max(0, this.duration - (this.def.hold ?? 1.6) - 0.01));
    // A still frame shows the whole scene, with no cursor.
    this.applyCam(fitCam(this.frame));
    this.cursorVisible = false;
    gsap.set(this.cursor, { autoAlpha: 0 });
    gsap.set(this.capHost.children, { autoAlpha: 0 });
  }

  /** Back to motion after a still frame. */
  resumeMotion(visible: boolean): void {
    if (!this.tl) return;
    this.reset();
    this.tl.restart(false);
    this.wantPlay = visible;
    if (!visible) { this.tl.pause(); this.icons.stop(); } else if (!env.hidden) this.icons.start();
  }

  /**
   * Puts the scene at `time` seconds. The timeline is rewound first and everything reset, then played forward to `time`, so every
   * tween between the start and there is rendered in order: seeking straight to a late time would skip the ones before it.
   */
  private goto(time: number): void {
    if (!this.tl) return;
    this.tl.pause();
    this.tl.seek(0, true);
    this.reset();
    this.tl.seek(time, false);
    // The icons that move are drawn as they are at this moment (at rest for a still frame).
    this.icons.paint(env.reduced ? null : performance.now() / 1000);
  }

  /** Jumps to `time` seconds and holds there (for tests and screenshots). */
  seek(time: number): void {
    this.wantPlay = false;
    this.goto(time);
  }

  get isPlaying(): boolean { return !!this.tl && this.tl.isActive(); }

  destroy(): void {
    this.tl?.kill();
    this.icons.stop();
    this.ro?.disconnect();
    this.catCleanups.forEach((fn) => fn());
  }
}
