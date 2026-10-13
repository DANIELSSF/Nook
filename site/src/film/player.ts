import { gsap } from 'gsap';
import type { Anchor, Fx, Vars } from '../demo/types';
import { Geometry } from '../demo/geometry';
import { planPath, pointAt, reachTime, type Pt } from '../demo/cursor';
import { planTyping, typedCount } from '../demo/typing';
import { IslandController, type IslandStateName } from '../demo/island';
import { LiveIcons } from '../demo/liveIcons';
import { hashString } from '../demo/rng';
import { env } from '../scripts/env';
import { fmt } from '../i18n';
import { FilmCat, type Sight } from './cat';
import { MAC, SCREEN } from './layout';
import { script, type FilmCopy } from './script';
import type { Aim, Into, Step, Target } from './types';

/**
 * Plays the film: a MacBook on a stage, a camera that moves over it, the island's shots on its screen, titles over them, and one GSAP
 * timeline for all of it, so it can be paused, sought by chapter and replayed, and drawn as one still frame when motion is not welcome.
 * It speaks the feature demos' language (`src/demo/player.ts`): a cursor that glides along eased arcs, clicks that ripple, typing
 * with a human cadence, islands that morph, a tab dragged past its neighbours; and it reuses their parts. What is its own is the camera
 * (the laptop, tipped and turned in perspective, framed into the part of the frame beside a title), the shots, the titles and the cats,
 * which are directed by the timeline (`./cat.ts`) instead of living on their own clocks, so every frame is the same every time.
 *
 * Every position the script names is measured from the markup when the timeline is built (and rebuilt when the frame is resized), so
 * the script holds no coordinates and the camera frames the same things on a phone and on a desktop.
 */

const FX: Record<Fx, { from: Vars; to: Vars; out: Vars }> = {
  fade: { from: { autoAlpha: 0 }, to: { autoAlpha: 1 }, out: { autoAlpha: 0 } },
  rise: { from: { autoAlpha: 0, y: 10 }, to: { autoAlpha: 1, y: 0 }, out: { autoAlpha: 0, y: -6 } },
  drop: { from: { autoAlpha: 0, y: -10 }, to: { autoAlpha: 1, y: 0 }, out: { autoAlpha: 0, y: -8 } },
  pop: { from: { autoAlpha: 0, scale: 0.93 }, to: { autoAlpha: 1, scale: 1 }, out: { autoAlpha: 0, scale: 0.96 } },
  slide: { from: { autoAlpha: 0, x: 16 }, to: { autoAlpha: 1, x: 0 }, out: { autoAlpha: 0, x: 12 } },
};

/** The first frame: a hair past zero, where everything the script sets at its start has been set. */
const FIRST = 0.02;
/** How far into a chapter a jump to it lands: past the cut or the short cross-fade it opens with. */
const CHAPTER_LEAD = 0.25;

/** How far along the clock a move with `power2.inOut` has got when it is `u` of the way there (the inverse of that ease). */
const easeTime = (u: number): number => (u <= 0.5 ? Math.sqrt(u / 2) : 1 - Math.sqrt((1 - u) / 2));

/** The camera: the screen point at the middle of the frame, the scale, and how far the laptop is tipped back and turned (degrees). */
interface Cam { cx: number; cy: number; k: number; rx: number; ry: number }

/**
 * The camera between two of its states, `u` of the way. The scale moves evenly in its logarithm (a dolly, not a zoom that rushes at
 * the end) and, while it changes, about the one point both states keep in the same place on the frame, so a push-in goes straight at
 * what it is pushing into.
 */
function camBetween(a: Cam, b: Cam, u: number): Cam {
  const k = a.k * Math.pow(b.k / a.k, u);
  const rx = a.rx + (b.rx - a.rx) * u, ry = a.ry + (b.ry - a.ry) * u;
  if (Math.abs(Math.log(b.k / a.k)) < 0.06) return { cx: a.cx + (b.cx - a.cx) * u, cy: a.cy + (b.cy - a.cy) * u, k, rx, ry };
  const fx = (a.cx * a.k - b.cx * b.k) / (a.k - b.k), fy = (a.cy * a.k - b.cy * b.k) / (a.k - b.k);
  return { cx: fx - (fx - a.cx) * a.k / k, cy: fy - (fy - a.cy) * a.k / k, k, rx, ry };
}

interface Chapter { id: string; name: string; at: number }
interface CatSlot {
  cat: FilmCat;
  host: HTMLElement;
  island: IslandController | null;
  still: boolean;
  /** Where its host is on the screen and how wide the cat is drawn, measured when the timeline is built (nothing moves them since). */
  rect: { x: number; y: number; w: number; h: number };
  width: number;
}

interface CompileState {
  t: number;
  last: number;
  shot: HTMLElement | null;
  scope: ParentNode;
  cursor: Pt;
  cursorShown: boolean;
  cam: Cam;
  /** Whether a camera move has been compiled yet (the first one says where the camera starts). */
  camSet: boolean;
  carry: { el: HTMLElement; dx: number; dy: number } | null;
  island: Map<IslandController, IslandStateName>;
  typed: Map<HTMLElement, string>;
  shown: Map<HTMLElement, boolean>;
  scroll: Map<HTMLElement, number>;
  classes: Map<HTMLElement, Map<string, boolean>>;
  moves: number;
}

type State = 'idle' | 'playing' | 'paused' | 'ended' | 'still';

export class FilmPlayer {
  readonly root: HTMLElement;
  private frame: HTMLElement;
  private world: HTMLElement;
  private screen: HTMLElement;
  private cursor: HTMLElement;
  private cursorInner: HTMLElement;
  private ripple: HTMLElement;
  private keysHost: HTMLElement;
  private copy: FilmCopy;
  private geo: Geometry;
  private W = 1280;
  private H = 720;
  private camState: Cam = { cx: SCREEN.w / 2, cy: SCREEN.h / 2, k: 1, rx: 0, ry: 0 };
  private cursorPos: Pt = { x: -100, y: -100 };
  private tl: gsap.core.Timeline | null = null;
  private islands = new Map<HTMLElement, IslandController>();
  private cats = new Map<SVGSVGElement, CatSlot>();
  private icons: LiveIcons;
  private resets: (() => void)[] = [];
  private chapters: Chapter[] = [];
  private ro: ResizeObserver | null = null;
  private io: IntersectionObserver | null = null;
  private resizeTimer = 0;
  private state: State = 'idle';
  private inView = false;
  /** The visitor paused it: it stays paused until they play it again (scrolling back to it does not). */
  private userPaused = false;
  private offs: (() => void)[] = [];
  // The controls.
  private toggle: HTMLButtonElement | null;
  private track: HTMLElement | null;
  private segs: HTMLElement[];
  private fills: HTMLElement[];
  private chapterLabel: HTMLElement | null;
  private timeLabel: HTMLElement | null;
  private endCard: HTMLElement | null;
  private shownChapter = -1;
  private shownSecond = -1;
  private fillCache: number[] = [];
  duration = 0;

  constructor(root: HTMLElement) {
    this.root = root;
    const need = <T extends Element = HTMLElement>(sel: string): T => {
      const el = root.querySelector<T>(sel);
      if (!el) throw new Error(`film: missing ${sel}`);
      return el;
    };
    this.frame = need('[data-film-frame]');
    this.world = need('[data-f="world"]');
    this.screen = need('[data-f="screen"]');
    this.cursor = need('[data-f="cursor"]');
    this.cursorInner = need('[data-f="cursor-inner"]');
    this.ripple = need('[data-f="ripple"]');
    this.keysHost = need('[data-f="keys"]');
    const copyEl = root.querySelector('[data-film-copy]');
    this.copy = JSON.parse(copyEl?.textContent ?? '{}') as FilmCopy;
    this.geo = new Geometry(this.screen);
    this.icons = new LiveIcons(this.frame);
    this.toggle = root.querySelector('[data-film-toggle]');
    this.track = root.querySelector('[data-film-track]');
    this.segs = Array.from(root.querySelectorAll<HTMLElement>('[data-film-seg]'));
    this.fills = this.segs.map((s) => s.querySelector<HTMLElement>('.film__fill') as HTMLElement);
    this.chapterLabel = root.querySelector('[data-film-chapter]');
    this.timeLabel = root.querySelector('[data-film-time]');
    this.endCard = root.querySelector('[data-film-end]');
    this.screen.querySelectorAll<HTMLElement>('[data-island]').forEach((el) => this.islands.set(el, new IslandController(el)));
    this.makeCats();
  }

  // MARK: Setup

  /** Every cat of the film, each with what decides whether it is in sight (its shot, or the cat's stage). */
  private makeCats(): void {
    const gateOf = (el: Element): HTMLElement => (el.closest('[data-shot]') ?? el.closest('[data-f="studio"]') ?? this.root) as HTMLElement;
    let seed = 0;
    this.root.querySelectorAll<SVGSVGElement>('svg.cat').forEach((svg) => {
      const host = svg.parentElement as HTMLElement;
      const islandEl = host.matches('[data-cat-host]') ? host.closest<HTMLElement>('[data-island]') : null;
      const big = !islandEl;
      const stage = host.matches('[data-stage-cat]');
      const cat = new FilmCat(svg, gateOf(host), { big, hop: stage ? 5 : 4, seed: (seed++) * 37.7 });
      this.cats.set(svg, { cat, host, island: islandEl ? this.islands.get(islandEl) ?? null : null, still: host.closest('[data-f="studio"]') !== null, rect: { x: 0, y: 0, w: 0, h: 0 }, width: 0 });
    });
  }

  init(): void {
    this.layout();
    this.build();
    this.bindControls();
    this.ro = new ResizeObserver(() => {
      window.clearTimeout(this.resizeTimer);
      this.resizeTimer = window.setTimeout(() => this.relayout(), 150);
    });
    this.ro.observe(this.frame);
    this.io = new IntersectionObserver((entries) => {
      for (const e of entries) this.inView = e.isIntersecting && e.intersectionRatio >= 0.5;
      this.sync();
    }, { threshold: [0, 0.25, 0.5, 0.75] });
    this.io.observe(this.frame);
    this.offs.push(
      env.on('visibility', () => this.sync()),
      env.on('motion', () => { if (env.reduced) this.showPoster(); else { this.goto(0); this.setState('idle'); this.sync(); } }),
    );
    if (env.reduced) this.showPoster(); else { this.goto(0); this.setState('idle'); }
  }

  private layout(): void {
    this.W = this.frame.clientWidth || 1280;
    this.H = this.frame.clientHeight || 720;
    this.islands.forEach((c) => c.refit());
  }

  private relayout(): void {
    if (!this.tl) return;
    const w = this.frame.clientWidth, h = this.frame.clientHeight;
    if (Math.abs(w - this.W) < 1 && Math.abs(h - this.H) < 1) return;
    const time = this.tl.time();
    const playing = this.state === 'playing';
    this.layout();
    this.build();
    if (this.state === 'still') { this.showPoster(); return; }
    this.goto(time);
    if (playing) this.tl.play();
  }

  // MARK: Names

  private find(name: string, scope: ParentNode): HTMLElement | null {
    if (name.startsWith('@')) return this.root.querySelector<HTMLElement>(`[data-f="${name.slice(1)}"]`);
    return scope.querySelector<HTMLElement>(`[data-t="${name}"]`) ?? scope.querySelector<HTMLElement>(`[data-stage-cat="${name}"]`);
  }

  private one(name: string, st: CompileState): HTMLElement {
    const el = name === '@cursor' ? this.cursor : this.find(name, st.scope);
    if (!el) throw new Error(`film: no element named "${name}"`);
    return el;
  }

  private all(target: Target, st: CompileState): HTMLElement[] {
    const names = Array.isArray(target) ? target : [target];
    const out: HTMLElement[] = [];
    for (const n of names) {
      if (n === '@cursor') { out.push(this.cursor); continue; }
      const sel = n.startsWith('@') ? `[data-f="${n.slice(1)}"]` : `[data-t="${n}"]`;
      const found = (n.startsWith('@') ? this.root : st.scope).querySelectorAll<HTMLElement>(sel);
      if (!found.length) throw new Error(`film: no element named "${n}"`);
      found.forEach((e) => out.push(e));
    }
    return out;
  }

  /** Where something is on the screen, in screen points: the offsets of the layout, which no transform or camera moves. */
  private rectOf(name: string, st: CompileState): { x: number; y: number; w: number; h: number } {
    if (name === '@mac') {
      return { x: (SCREEN.w - MAC.baseW) / 2, y: -MAC.bezel, w: MAC.baseW, h: SCREEN.h + MAC.bezel * 2 + MAC.baseH };
    }
    return this.geo.rectOf(this.one(name, st));
  }

  private point(a: Anchor, st: CompileState): Pt {
    if (typeof a === 'string') { const r = this.rectOf(a, st); return { x: r.x + r.w / 2, y: r.y + r.h / 2 }; }
    if ('el' in a) {
      const r = this.rectOf(a.el, st);
      const [fx, fy] = a.at ?? [0.5, 0.5];
      return { x: r.x + r.w * fx + (a.dx ?? 0), y: r.y + r.h * fy + (a.dy ?? 0) };
    }
    return { x: a.x, y: a.y };
  }

  // MARK: Camera and cursor

  private get tall(): boolean { return this.W / this.H < 1.2; }

  /** The part of the frame a subject goes in, in frame pixels. */
  private into(into: Into): { x: number; y: number; w: number; h: number } {
    const { W, H } = this;
    if (into === 'side') return this.tall ? { x: W * 0.04, y: H * 0.04, w: W * 0.92, h: H * 0.6 } : { x: W * 0.41, y: H * 0.07, w: W * 0.56, h: H * 0.86 };
    if (into === 'low') return this.tall ? { x: W * 0.05, y: H * 0.34, w: W * 0.9, h: H * 0.58 } : { x: W * 0.1, y: H * 0.34, w: W * 0.8, h: H * 0.6 };
    return { x: W * 0.04, y: H * 0.05, w: W * 0.92, h: H * 0.9 };
  }

  private aimCam(aim: Aim, st: CompileState): Cam {
    const r = this.rectOf(aim.el, st);
    const pad = aim.pad ?? 24;
    const sub = this.into(aim.into ?? 'full');
    let k = Math.min(sub.w / (r.w + pad * 2), sub.h / (r.h + pad * 2)) * (aim.zoom ?? 1);
    if (aim.min) k = Math.max(k, aim.min);
    // Whatever it looks at in a shot, the shot's island stays whole across the frame part: never so close that its sides (the cat,
    // the first tab, the buttons, the first letters of a line) leave it. On a phone that means the island as wide as the frame.
    const island = !aim.crop && !aim.el.startsWith('@') ? st.scope.querySelector<HTMLElement>('[data-island]') : null;
    const ir = island ? this.geo.rectOf(island) : null;
    if (ir) k = Math.min(k, sub.w / ir.w);
    const [fx, fy] = aim.at ?? [0.5, 0.5];
    const px = r.x + r.w * fx, py = r.y + r.h * fy;
    const sx = sub.x + sub.w / 2, sy = sub.y + sub.h / 2;
    const cy = aim.top !== undefined ? aim.top + this.H / (2 * k) : py - (sy - this.H / 2) / k;
    let cx = px - (sx - this.W / 2) / k;
    if (ir) {
      // Slid sideways, if it has to be, so both of its sides are inside the frame part.
      const left = this.W / 2 + (ir.x - cx) * k, right = this.W / 2 + (ir.x + ir.w - cx) * k;
      if (left < sub.x) cx = ir.x - (sub.x - this.W / 2) / k;
      else if (right > sub.x + sub.w) cx = ir.x + ir.w - (sub.x + sub.w - this.W / 2) / k;
    }
    return { k, cx, cy, rx: aim.rx ?? 0, ry: aim.ry ?? 0 };
  }

  private applyCam(c: Cam): void {
    this.camState = c;
    this.world.style.transform = `translate3d(${(this.W / 2).toFixed(2)}px, ${(this.H / 2).toFixed(2)}px, 0) rotateX(${c.rx.toFixed(3)}deg) rotateY(${c.ry.toFixed(3)}deg) scale(${c.k.toFixed(4)}) translate3d(${(-c.cx).toFixed(2)}px, ${(-c.cy).toFixed(2)}px, 0)`;
    this.paintCursor();
  }

  /** The cursor stays about the same size on the frame whatever the camera does, as a real one does on a screen being filmed. */
  private cursorScale(k = this.camState.k): number { return Math.min(2.6, Math.max(0.55, 1 / Math.pow(k, 0.82))); }

  private paintCursor(): void {
    this.cursor.style.transform = `translate3d(${this.cursorPos.x.toFixed(2)}px, ${this.cursorPos.y.toFixed(2)}px, 0) scale(${this.cursorScale().toFixed(3)})`;
  }

  private setCursor(x: number, y: number): void { this.cursorPos = { x, y }; this.paintCursor(); }

  /** A screen point on the frame, in frame pixels (the laptop is upright whenever a cat looks at the cursor, so the tilt is left out). */
  private onFrame(x: number, y: number): Pt {
    const c = this.camState;
    return { x: this.W / 2 + (x - c.cx) * c.k, y: this.H / 2 + (y - c.cy) * c.k };
  }

  // MARK: Building the timeline

  private build(): void {
    this.tl?.kill();
    this.resets = [];
    this.keysHost.replaceChildren();
    this.chapters = [];
    this.geo = new Geometry(this.screen);
    this.cats.forEach((s) => {
      s.cat.clear();
      // Measured once here, so drawing a cat never asks the browser for a layout in the middle of a frame.
      if (!s.still) { s.rect = this.geo.rectOf(s.host); s.width = s.cat.svg.clientWidth; }
    });
    const st: CompileState = {
      t: 0, last: 0, shot: null, scope: this.screen, cursor: { x: SCREEN.w + 80, y: SCREEN.h * 0.7 }, cursorShown: false,
      cam: { cx: SCREEN.w / 2, cy: SCREEN.h / 2, k: 1, rx: 0, ry: 0 }, camSet: false, carry: null,
      island: new Map(), typed: new Map(), shown: new Map(), scroll: new Map(), classes: new Map(), moves: 0,
    };
    this.islands.forEach((c) => st.island.set(c, (c.el.dataset['state'] as IslandStateName | undefined) ?? 'open'));
    const initial = new Map(st.island);
    const tl = gsap.timeline({ paused: true });
    for (const step of script(this.copy)) {
      const at = step.at ?? (step.with ? st.last : st.t) + (step.delay ?? 0);
      const d = this.compile(tl, st, step, at);
      st.last = at;
      st.t = Math.max(st.t, at + d);
    }
    // The last frame stays on: the film ends on its card, it does not loop.
    tl.set({}, {}, st.t + 0.4);
    tl.eventCallback('onUpdate', () => this.frameUpdate());
    tl.eventCallback('onComplete', () => this.ended());
    this.tl = tl;
    this.duration = tl.duration();
    this.layoutSegments();

    const start = { ...st.cursor };
    const shots = Array.from(this.root.querySelectorAll<HTMLElement>('[data-shot], [data-f="studio"]'));
    this.resets.unshift(() => {
      gsap.set(this.cursor, { autoAlpha: 0 });
      gsap.set(this.cursorInner, { scale: 1 });
      gsap.set(this.ripple, { autoAlpha: 0 });
      gsap.set(shots, { autoAlpha: 0 });
      this.cursorPos = { ...start };
      initial.forEach((state, c) => c.set(state));
    });
    this.reset();
  }

  private reset(): void { this.resets.forEach((fn) => fn()); }

  private compile(tl: gsap.core.Timeline, st: CompileState, step: Step, at: number): number {
    switch (step.do) {
      case 'wait': return step.t;
      case 'label': tl.addLabel(step.name, at); return 0;
      case 'chapter': {
        const name = this.copy.chapters.find((c) => c.id === step.id)?.name ?? step.id;
        this.chapters.push({ id: step.id, name, at });
        return 0;
      }
      case 'shot': return this.stepShot(tl, st, step, at);
      case 'show':
      case 'hide': return this.stepVisibility(tl, st, step, at);
      case 'set': tl.set(this.all(step.target, st), step.vars, at); return 0;
      case 'tween': {
        const d = step.t ?? 0.5;
        const els = this.all(step.target, st);
        const to = { ...step.vars, duration: d, ease: step.ease ?? 'power2.out', immediateRender: false };
        if (step.from) tl.fromTo(els, step.from, to, at); else tl.to(els, to, at);
        return d;
      }
      case 'class': {
        this.all(step.target, st).forEach((el) => {
          step.add?.split(' ').filter(Boolean).forEach((c) => this.classAt(tl, st, el, c, true, at));
          step.remove?.split(' ').filter(Boolean).forEach((c) => this.classAt(tl, st, el, c, false, at));
        });
        return 0;
      }
      case 'text': {
        const el = this.one(step.target, st);
        if (!st.typed.has(el)) { const was = el.textContent ?? ''; st.typed.set(el, was); this.resets.push(() => { el.textContent = was; }); }
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
      case 'type': return this.stepType(tl, st, step, at);
      case 'keys': return this.stepKeys(tl, step, at);
      case 'scroll': return this.stepScroll(tl, st, step, at);
      case 'cam': return this.stepCam(tl, st, step, at);
      case 'title': return this.stepTitle(tl, step, at);
      case 'cat': return this.stepCat(st, step, at);
      case 'sad': this.catIn(step.target, st).sad(at, step.t); return 0;
      case 'dress': this.catIn(step.target, st).dress(at, { coat: step.coat, accessory: step.accessory ?? 'none' }); return 0;
      case 'ring': return this.stepRing(tl, st, step, at);
    }
  }

  /**
   * Sets a class on or off at `at`: a zero-length tween whose update says what the class is, from what the script knows it was just
   * before, so it is right whichever way the timeline is played or sought (the demo player's way).
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

  private stepShot(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'shot' }>, at: number): number {
    const el = step.id === 'studio' ? this.root.querySelector<HTMLElement>('[data-f="studio"]') : this.root.querySelector<HTMLElement>(`[data-shot="${step.id}"]`);
    if (!el) throw new Error(`film: no shot "${step.id}"`);
    const d = step.fx === 'fade' ? step.t ?? 0.4 : 0;
    const prev = st.shot;
    if (d > 0) {
      tl.fromTo(el, { autoAlpha: 0 }, { autoAlpha: 1, duration: d, ease: 'power1.inOut', immediateRender: false }, at);
      if (prev && prev !== el) tl.fromTo(prev, { autoAlpha: 1 }, { autoAlpha: 0, duration: d, ease: 'power1.inOut', immediateRender: false }, at);
    } else {
      tl.set(el, { autoAlpha: 1 }, at);
      if (prev && prev !== el) tl.set(prev, { autoAlpha: 0 }, at);
    }
    st.shot = el;
    // The studio is not on the screen: its names are the film's own (`@studio-cat`), and the screen's stay as they were.
    if (step.id !== 'studio') st.scope = el;
    return 0;
  }

  private stepVisibility(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'show' | 'hide' }>, at: number): number {
    const fx = FX[step.fx ?? 'fade'];
    const d = step.t ?? 0.4;
    const els = this.all(step.target, st);
    const showing = step.do === 'show';
    els.forEach((el) => {
      if (st.shown.has(el)) return;
      // The first thing the script does to an element says how it starts: shown means it starts hidden, and the other way round.
      st.shown.set(el, !showing);
      if (el !== this.cursor) this.resets.push(() => { gsap.set(el, showing ? fx.from : fx.to); });
    });
    els.forEach((el) => st.shown.set(el, showing));
    tl.fromTo(els, showing ? fx.from : fx.to, { ...(showing ? fx.to : fx.out), duration: d, ease: showing ? 'power3.out' : 'power2.in', stagger: step.stagger ?? 0, immediateRender: false }, at);
    if (els.includes(this.cursor)) st.cursorShown = showing;
    return d + (step.stagger ?? 0) * Math.max(0, els.length - 1);
  }

  private islandIn(st: CompileState): IslandController {
    const el = st.scope.querySelector<HTMLElement>('[data-island]');
    const ctrl = el ? this.islands.get(el) : undefined;
    if (!ctrl) throw new Error('film: no island in this shot');
    return ctrl;
  }

  private stepIsland(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'island' }>, at: number): number {
    const ctrl = this.islandIn(st);
    const from = st.island.get(ctrl) ?? 'open';
    const d = step.t ?? 0.9;
    tl.add(ctrl.morph(from, step.state, { duration: d, ease: step.ease ?? 'expo.out' }), at);
    st.island.set(ctrl, step.state);
    return d;
  }

  private stepMove(tl: gsap.core.Timeline, st: CompileState, to: Anchor, t: number | undefined, arc: number | undefined, ease: string | undefined, at: number): number {
    const target = this.point(to, st);
    const from = st.cursor;
    const path = planPath(from, target, hashString('film') + st.moves++ * 7919, arc);
    const d = t ?? reachTime(path.length);
    if (!st.cursorShown) {
      tl.fromTo(this.cursor, { autoAlpha: 0 }, { autoAlpha: 1, duration: 0.3, ease: 'power1.out', immediateRender: false }, at);
      st.cursorShown = true;
      st.shown.set(this.cursor, true);
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
    let d = 0;
    if (step.to) d = this.stepMove(tl, st, step.to, undefined, undefined, undefined, at) + 0.08;
    const when = at + d;
    const p = st.cursor;
    const to = step.to;
    const pressEl = step.press ? this.one(step.press, st) : typeof to === 'string' ? this.one(to, st) : to && 'el' in to ? this.one(to.el, st) : null;
    const comp = this.cursorScale(st.cam.k);
    tl.fromTo(this.cursorInner, { scale: 1 }, { scale: 0.78, duration: 0.09, ease: 'power2.in', transformOrigin: '2px 2px', immediateRender: false }, when);
    tl.to(this.cursorInner, { scale: 1, duration: 0.3, ease: 'back.out(2.4)' }, when + 0.09);
    this.classAt(tl, st, this.ripple, 'is-right', step.kind === 'right', when);
    tl.fromTo(this.ripple, { x: p.x, y: p.y, scale: 0.25 * comp, autoAlpha: 0.95 }, { x: p.x, y: p.y, scale: 1.7 * comp, autoAlpha: 0, duration: 0.6, ease: 'power2.out', immediateRender: false }, when);
    if (pressEl) {
      this.classAt(tl, st, pressEl, 'is-press', true, when);
      this.classAt(tl, st, pressEl, 'is-press', false, when + 0.17);
    }
    return d + 0.34;
  }

  private stepCarry(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'carry' }>, at: number): number {
    if (step.target === null) { st.carry = null; return 0; }
    const el = this.one(step.target, st);
    const carry = { el, dx: step.dx ?? 8, dy: step.dy ?? 10 };
    st.carry = carry;
    tl.set(el, { x: st.cursor.x + carry.dx, y: st.cursor.y + carry.dy }, at);
    this.resets.push(() => { gsap.set(el, { x: 0, y: 0 }); });
    return 0;
  }

  /** A tab dragged past its neighbours, as the demo player drags one (see `stepDrag` there): it lifts, follows, and they give way. */
  private stepDrag(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'drag' }>, at: number): number {
    const dragged = this.one(step.target, st);
    const names = Array.isArray(step.over) ? step.over : [step.over];
    const others = names.map((n) => this.one(n, st));
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
    const path = planPath(from, to, hashString('film') + st.moves++ * 7919, 0);
    const comp = this.cursorScale(st.cam.k);
    tl.call(() => { const m = measure(); live.shift = m.shift; live.aside = m.aside; }, [], at);
    tl.fromTo(this.cursorInner, { scale: 1 }, { scale: 0.78, duration: 0.09, ease: 'power2.in', transformOrigin: '2px 2px', immediateRender: false }, at);
    this.classAt(tl, st, this.ripple, 'is-right', false, at);
    tl.fromTo(this.ripple, { x: from.x, y: from.y, scale: 0.25 * comp, autoAlpha: 0.95 }, { x: from.x, y: from.y, scale: 1.7 * comp, autoAlpha: 0, duration: 0.6, ease: 'power2.out', immediateRender: false }, at);
    this.classAt(tl, st, dragged, 'is-lifted', true, at + 0.1);
    const proxy = { u: 0 };
    tl.fromTo(proxy, { u: 0 }, {
      u: 1, duration: move, ease: 'power2.inOut', immediateRender: false,
      onUpdate: () => { const p = pointAt(path, proxy.u); this.setCursor(p.x, p.y); gsap.set(dragged, { x: live.shift * proxy.u }); },
    }, at + lead);
    others.forEach((el, i) => {
      const r = first.rects[i]!;
      const edge = first.toLeft ? first.a.x : first.a.x + first.a.w;
      const passed = Math.min(1, Math.max(0, (r.x + r.w / 2 - edge) / first.shift));
      tl.fromTo(el, { x: 0 }, { x: () => live.aside, duration: 0.55, ease: 'back.out(0.9)', immediateRender: false }, at + lead + move * easeTime(passed));
    });
    const drop = at + lead + move + 0.06;
    this.classAt(tl, st, dragged, 'is-lifted', false, drop);
    tl.to(this.cursorInner, { scale: 1, duration: 0.3, ease: 'back.out(2.4)' }, drop);
    st.cursor = to;
    return lead + move + 0.5;
  }

  private stepType(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'type' }>, at: number): number {
    const el = this.one(step.target, st);
    if (!st.typed.has(el)) { const was = el.textContent ?? ''; st.typed.set(el, was); this.resets.push(() => { el.textContent = was; }); }
    const prefix = step.append ? (st.typed.get(el) ?? '') : '';
    const chars = Array.from(step.text);
    const plan = planTyping(step.text, step.cps ?? 14, hashString(step.text));
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

  private stepScroll(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'scroll' }>, at: number): number {
    const list = this.one(step.list, st);
    const view = list.parentElement as HTMLElement;
    let offset = 0;
    if (step.to === 'end') offset = list.offsetTop + list.offsetHeight + 10 - view.clientHeight;
    else if (step.to !== 'start') {
      const target = this.one(step.to, st);
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

  private stepCam(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'cam' }>, at: number): number {
    const target = this.aimCam(step.aim, st);
    const from = { ...st.cam };
    const d = step.t ?? 1.2;
    if (d <= 0) {
      // A cut.
      const proxy = { v: 0 };
      tl.fromTo(proxy, { v: 0 }, { v: 1, duration: 0.001, immediateRender: false, onUpdate: () => this.applyCam(proxy.v >= 1 ? target : from) }, at);
    } else {
      const proxy = { u: 0 };
      tl.fromTo(proxy, { u: 0 }, { u: 1, duration: d, ease: step.ease ?? 'power3.inOut', immediateRender: false, onUpdate: () => this.applyCam(camBetween(from, target, proxy.u)) }, at);
    }
    if (!st.camSet) {
      // The first move says where the camera is at the first frame.
      st.camSet = true;
      const first = d <= 0 ? target : from;
      this.resets.push(() => this.applyCam(first));
    }
    st.cam = target;
    return d;
  }

  /** A title: its words rise into place one after another, it stays, and they leave, lifting a little, in the same order. */
  private stepTitle(tl: gsap.core.Timeline, step: Extract<Step, { do: 'title' }>, at: number): number {
    const el = this.root.querySelector<HTMLElement>(`[data-title="${step.id}"]`);
    if (!el) throw new Error(`film: no title "${step.id}"`);
    const words = Array.from(el.querySelectorAll<HTMLElement>('.kw > span'));
    const brand = el.dataset['place'] === 'brand';
    this.resets.push(() => { gsap.set(el, { autoAlpha: 0 }); gsap.set(words, { yPercent: brand ? 40 : 108, opacity: 0, scale: 1 }); });
    tl.set(el, { autoAlpha: 1 }, at);
    if (brand) tl.fromTo(words, { yPercent: 40, opacity: 0, scale: 0.94 }, { yPercent: 0, opacity: 1, scale: 1, duration: 1.4, ease: 'expo.out', immediateRender: false }, at);
    else tl.fromTo(words, { yPercent: 108, opacity: 0 }, { yPercent: 0, opacity: 1, duration: 0.9, ease: 'expo.out', stagger: 0.075, immediateRender: false }, at);
    const wave = el.querySelectorAll<HTMLElement>('.ktitle__wave i');
    if (wave.length) {
      // The sound, drawn: the bars of a level meter rise and fall while the title is up.
      this.resets.push(() => { gsap.set(wave, { scaleY: 0.25 }); });
      tl.fromTo(wave, { scaleY: 0.25 }, { scaleY: 1, duration: 0.22, ease: 'sine.inOut', yoyo: true, repeat: Math.max(1, Math.floor(Math.max(1, step.hold) / 0.22)), stagger: { each: 0.07, from: 'center' }, immediateRender: false }, at + 0.3);
    }
    // A title held for no time stays to the end (the last card).
    if (step.hold <= 0) return 0;
    const out = at + step.hold;
    tl.to(words, { yPercent: brand ? -10 : -36, opacity: 0, duration: 0.5, ease: 'power2.in', stagger: brand ? 0 : 0.035 }, out);
    tl.set(el, { autoAlpha: 0 }, out + 0.5 + 0.035 * words.length);
    return 0;
  }

  private catIn(name: string, st: CompileState): FilmCat {
    const el = this.one(name, st);
    const svg = el.matches('svg.cat') ? (el as unknown as SVGSVGElement) : el.querySelector<SVGSVGElement>('svg.cat');
    const slot = svg ? this.cats.get(svg) : undefined;
    if (!slot) throw new Error(`film: no cat in "${name}"`);
    return slot.cat;
  }

  private stepCat(st: CompileState, step: Extract<Step, { do: 'cat' }>, at: number): number {
    const cat = this.catIn(step.target, st);
    switch (step.act) {
      case 'celebrate': cat.celebrate(at, step.style ?? 'hop'); return 0;
      case 'perk': cat.perk(at); return 0;
      case 'work': cat.work(at, true); return 0;
      case 'rest': cat.work(at, false); return 0;
      case 'nap': cat.nap(at); return 0;
      case 'blink': cat.blink(at); return 0;
      default: cat.gesture(at, step.act, step.variant ?? 0); return 0;
    }
  }

  /** An alert's bell swings, and its sound spreads from it as rings, in the color of the alert. */
  private stepRing(tl: gsap.core.Timeline, st: CompileState, step: Extract<Step, { do: 'ring' }>, at: number): number {
    const bell = this.one(step.target, st);
    const icon = bell.querySelector<SVGElement>('svg');
    const sound = this.root.querySelector<HTMLElement>('[data-f="sound"]');
    const r = this.geo.rectOf(bell);
    if (icon) {
      this.resets.push(() => { gsap.set(icon, { rotation: 0 }); });
      tl.fromTo(icon, { rotation: 0 }, { keyframes: { rotation: [16, -14, 9, -5, 0] }, duration: 0.9, ease: 'sine.inOut', transformOrigin: '50% 12%', immediateRender: false }, at);
    }
    if (sound) {
      const rings = sound.querySelectorAll<HTMLElement>('i');
      this.resets.push(() => { gsap.set(rings, { autoAlpha: 0 }); });
      tl.set(sound, { x: r.x + r.w / 2, y: r.y + r.h / 2, '--ring': step.color }, at);
      const pulses = step.pulses ?? 1;
      for (let p = 0; p < pulses; p++) {
        tl.fromTo(rings, { scale: 0.45, autoAlpha: 0.85 }, { scale: 2.6, autoAlpha: 0, duration: 1.1, ease: 'power2.out', stagger: 0.18, immediateRender: false }, at + p * 0.42);
      }
    }
    return 0;
  }

  // MARK: Each frame

  /** What the cats see: the cursor, and where they are on the frame. */
  private sightOf(slot: CatSlot): Sight | null {
    if (slot.still) return null;
    const r = slot.rect;
    let x = r.x + r.w / 2;
    if (slot.island) {
      // The wing's cat rides along the strip as the island opens (island.css: `.island__cat`).
      const open = slot.island.cur.open;
      x += (1 - open) * (slot.island.W / 2 - 124) + open * 6;
    }
    const p = this.onFrame(x, r.y + r.h * 0.45);
    const alpha = gsap.getProperty(this.cursor, 'autoAlpha') as number;
    const c = alpha > 0 ? this.onFrame(this.cursorPos.x, this.cursorPos.y) : null;
    return { cat: { x: p.x, y: p.y, w: slot.width * this.camState.k }, cursor: c ? { x: c.x, y: c.y, alpha } : null };
  }

  private paintCats(still: boolean): void {
    if (!this.tl) return;
    const t = this.tl.time();
    this.cats.forEach((slot) => {
      if (!slot.cat.shown) return;
      const sight = this.sightOf(slot);
      if (still) slot.cat.paintStill(t, sight); else slot.cat.paint(t, sight);
    });
  }

  private frameUpdate(): void {
    if (this.state === 'playing') this.paintCats(false);
    this.paintProgress();
  }

  // MARK: Playing

  private setState(s: State): void {
    this.state = s;
    this.root.dataset['film'] = s;
    this.root.classList.toggle('is-playing', s === 'playing');
    if (this.toggle) {
      const c = this.copy.controls;
      this.toggle.setAttribute('aria-label', s === 'playing' ? c.pause : s === 'ended' ? c.replayLabel : c.play);
    }
    if (this.endCard) this.endCard.hidden = s !== 'ended';
  }

  /** Plays, or pauses, as the film's place on the page, the tab and the visitor say. */
  private sync(): void {
    if (this.state === 'still' || this.state === 'ended') return;
    const should = this.inView && !env.hidden && !env.reduced && !this.userPaused;
    if (should && this.state !== 'playing') this.play();
    else if (!should && this.state === 'playing') this.pause();
  }

  private play(): void {
    if (!this.tl || env.reduced) return;
    this.cats.forEach((s) => { if (s.cat.shown) s.cat.release(); });
    this.setState('playing');
    this.tl.play();
    this.icons.start();
  }

  private pause(): void {
    if (!this.tl) return;
    this.tl.pause();
    this.icons.stop();
    this.setState('paused');
    // The cats settle into the still of what they are doing: a paused film never holds a cat between two poses.
    const t = this.tl.time();
    this.cats.forEach((slot) => { if (slot.cat.shown) slot.cat.hold(t, this.sightOf(slot)); });
  }

  private ended(): void {
    this.icons.stop();
    this.setState('ended');
    // The last frame holds: the cats settle into their stills, in time, as they do when the film is paused.
    const t = this.tl?.time() ?? 0;
    this.cats.forEach((slot) => { if (slot.cat.shown) slot.cat.hold(t, this.sightOf(slot)); });
  }

  /** From the first frame (the replay, and the hero's «Ver la película»). */
  restart(): void {
    if (env.reduced) return;
    this.userPaused = false;
    this.goto(0);
    this.setState('idle');
    this.sync();
  }

  /**
   * Puts the film at `time`: rewound, everything reset, and played forward to there, so every step before it is drawn in order (the
   * demo player's way). The cats are drawn as the take has them when it plays, and in their stills when it is paused.
   */
  private goto(time: number): void {
    if (!this.tl) return;
    this.tl.pause();
    this.tl.seek(0, true);
    this.reset();
    // A hair past the start at least, so what the first frame sets (the screen off, the first camera) is drawn.
    this.tl.seek(Math.max(time, FIRST), false);
    this.icons.paint(env.reduced ? null : performance.now() / 1000);
    this.paintCats(this.state !== 'playing');
    this.paintProgress(true);
  }

  private seekTo(time: number): void {
    if (!this.tl) return;
    const playing = this.state === 'playing';
    const t = Math.max(0, Math.min(time, this.duration));
    this.goto(t);
    if (this.state === 'ended' && t < this.duration - 0.05) this.setState('paused');
    if (playing) this.tl.play();
    else if (this.state === 'idle' && !this.userPaused) this.sync();
  }

  /**
   * Jumps to `time` and holds there, the cats drawn as the take has them (`live`) or in their stills, as a paused film shows them:
   * for tests and frame sheets.
   */
  frameAt(time: number, live = true): void {
    if (!this.tl) return;
    this.userPaused = true;
    this.icons.stop();
    this.setState('paused');
    this.goto(time);
    if (live) this.paintCats(false);
  }

  /** The still frame for Reduce Motion: the film at its `poster`, with no cursor, the cats in their stills. */
  showPoster(): void {
    if (!this.tl) return;
    this.icons.stop();
    this.setState('still');
    const at = this.tl.labels['poster'] ?? 0;
    this.tl.pause();
    this.tl.seek(0, true);
    this.reset();
    this.tl.seek(Math.max(at, FIRST), false);
    gsap.set(this.cursor, { autoAlpha: 0 });
    this.icons.paint(null);
    this.paintCats(true);
    this.paintProgress(true);
  }

  // MARK: Controls

  private layoutSegments(): void {
    this.segs.forEach((seg, i) => {
      const c = this.chapters[i];
      const next = this.chapters[i + 1];
      const length = c ? (next ? next.at : this.duration) - c.at : 1;
      seg.style.flexGrow = String(Math.max(0.5, length));
    });
    this.fillCache = [];
    this.track?.setAttribute('aria-valuemax', String(Math.round(this.duration)));
  }

  private chapterAt(t: number): number {
    let i = 0;
    for (let k = 0; k < this.chapters.length; k++) if (this.chapters[k]!.at <= t + 0.001) i = k;
    return i;
  }

  private clock(t: number): string {
    const s = Math.max(0, Math.floor(t));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }

  /** The progress bar (a fill per chapter), the chapter's name and the clock; the slider's values for assistive technology. */
  private paintProgress(force = false): void {
    if (!this.tl) return;
    const t = this.tl.time();
    const ci = this.chapterAt(t);
    this.chapters.forEach((c, i) => {
      const end = this.chapters[i + 1]?.at ?? this.duration;
      const p = i < ci ? 1 : i > ci ? 0 : Math.min(1, Math.max(0, (t - c.at) / Math.max(0.01, end - c.at)));
      const q = Math.round(p * 1000) / 1000;
      if (force || this.fillCache[i] !== q) { this.fillCache[i] = q; const f = this.fills[i]; if (f) f.style.transform = `scaleX(${q})`; }
    });
    this.segs.forEach((s, i) => s.classList.toggle('is-current', i === ci));
    const second = Math.floor(t);
    if (!force && ci === this.shownChapter && second === this.shownSecond) return;
    const chapter = this.chapters[ci];
    if (chapter && ci !== this.shownChapter && this.chapterLabel) this.chapterLabel.textContent = chapter.name;
    if (this.timeLabel) this.timeLabel.textContent = `${this.clock(t)} / ${this.clock(this.duration)}`;
    if (this.track && chapter) {
      this.track.setAttribute('aria-valuenow', String(second));
      this.track.setAttribute('aria-valuetext', fmt(this.copy.controls.position, { n: ci + 1, total: this.chapters.length, name: chapter.name, time: this.clock(t) }));
    }
    this.shownChapter = ci;
    this.shownSecond = second;
  }

  /** To a chapter: a hair into it, past the cut or the cross-fade it opens with, so it starts on its own first shot. */
  private goChapter(i: number): void {
    const k = Math.max(0, Math.min(this.chapters.length - 1, i));
    const c = this.chapters[k];
    if (c) this.seekTo(k === 0 ? 0 : c.at + CHAPTER_LEAD);
  }

  private bindControls(): void {
    this.toggle?.addEventListener('click', () => {
      if (this.state === 'still') return;
      if (this.state === 'ended') { this.restart(); return; }
      if (this.state === 'playing') { this.userPaused = true; this.pause(); }
      else { this.userPaused = false; this.play(); }
    });
    this.root.querySelector('[data-film-replay]')?.addEventListener('click', () => {
      this.restart();
      this.toggle?.focus();
    });
    this.track?.addEventListener('click', (e) => {
      const seg = (e.target as HTMLElement).closest<HTMLElement>('[data-film-seg]');
      if (seg) this.goChapter(Number(seg.dataset['filmSeg']));
    });
    this.track?.addEventListener('keydown', (e) => {
      if (!this.tl || this.state === 'still') return;
      const ci = this.chapterAt(this.tl.time());
      const into = this.tl.time() - (this.chapters[ci]?.at ?? 0);
      let handled = true;
      switch (e.key) {
        case 'ArrowRight': case 'ArrowUp': case 'PageDown': this.goChapter(ci + 1); break;
        // Back to the start of this chapter, or to the one before when it has only just begun (a player's «previous»).
        case 'ArrowLeft': case 'ArrowDown': case 'PageUp': this.goChapter(into > CHAPTER_LEAD + 1.5 ? ci : ci - 1); break;
        case 'Home': this.goChapter(0); break;
        case 'End': this.goChapter(this.chapters.length - 1); break;
        case ' ': case 'Enter': case 'k': this.toggle?.click(); break;
        default: handled = false;
      }
      if (handled) e.preventDefault();
    });
  }

  destroy(): void {
    this.tl?.kill();
    this.icons.stop();
    this.ro?.disconnect();
    this.io?.disconnect();
    this.offs.forEach((o) => o());
  }
}
