import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { IslandController } from '../demo/island';
import { CatActor, runCat } from '../cat/actor';
import * as A from '../cat/anim';
import { basePose, blend, clonePose, swungTail, type Pose } from '../cat/pose';
import { env } from './env';

gsap.registerPlugin(ScrollTrigger);

/** Where each beat of the story starts, as a fraction of the scroll through the stage. */
const BEATS = [0, 0.14, 0.33, 0.52, 0.78, 1];
/** The moments in it: the pointer takes hold of the cat, lets go of it, and the day goes by. */
const GRAB = 0.1, DROP = 0.29, RELEASED = 0.335;
/**
 * The stretch of scroll over which the cat's place goes from the ledge's left end to where it stays, and the scroll past which it
 * naps (scrolled back above the second, it gets up again).
 */
const WALK_FROM = 0.35, WALK_TO = 0.475, NAP_AT = 0.8, NAP_UNTIL = 0.785;

interface Pt { x: number; y: number }
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const lerpP = (a: Pt, b: Pt, t: number): Pt => ({ x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t) });
const clamp01 = (n: number) => Math.min(1, Math.max(0, n));
const cubic = (p0: Pt, c1: Pt, c2: Pt, p1: Pt, t: number): Pt => {
  const v = 1 - t;
  return {
    x: v * v * v * p0.x + 3 * v * v * t * c1.x + 3 * v * t * t * c2.x + t * t * t * p1.x,
    y: v * v * v * p0.y + 3 * v * v * t * c1.y + 3 * v * t * t * c2.y + t * t * t * p1.y,
  };
};

// MARK: The cat on the ledge

/** How long it takes to get up from its sit into a walk (and to sit down again), and how long it stays down before it gets up again. */
const GET_UP = 0.4, REST = 0.25;
/** How long it stands where it stopped before it sits down: a scroll that only pauses does not sit it down. */
const PAUSE = 1.2;
/** Its walk: the fastest it goes (rig units a second), how quickly it closes the distance to its place, and the speed of a full stride. */
const WALK_SPEED = 46, CATCH_UP = 4, STRIDE_SPEED = 14;
/**
 * How long it takes to lie down for its nap (the app's nap lies down over this long), how far into the nap it is curled up all the
 * way (the app's: 4.7 s), and how much faster than that it unwinds when the night is scrolled back.
 */
const LIE_DOWN = 1.6, CURLED = 4.7, UNWIND = 3;
/** How long its reactions last, and how long one takes to let go when the cat has to move on. */
const REACTION = { land: A.LAND_LENGTH + 0.6, celebrate: A.cheerLength('content'), perk: 3.4 } as const;
const LET_GO = 0.3;
/**
 * How far it perks up at a notice, and how hard it lands: the app's perk turns the ears in and its landing squashes the head into
 * the body with the ears flat out, which at this size read as a broken cat, so the big cat does both a little less.
 */
const PERK = 0.65, LANDING = 0.4;
/** How far up its tail curls when it celebrates: all the way, its tip touches the side of its head. */
const CHEER_TAIL = 0.55;
/** How high above the ledge the pointer lets go of it, in rig units: the height the app's landing falls from (`A.land`). */
const DROP_HEIGHT = 9;

type Reaction = keyof typeof REACTION;

/**
 * The sit turned toward `other` (a walker standing side-on, or the cat lying down), `w` of the way, the way a cat drawn this large
 * reads as a cat all along: its tail comes up first and its body and legs turn while it still looks at us, and its head turns
 * last. Each leg of the front-facing sit goes to the leg of `other` that stands where it does, so no leg crosses another on the
 * way, and the tail swings round its root rather than sliding through a stub. (The app's own staging, head first, goes through
 * shapes that read as a lump at this size.)
 */
function fromSit(sitting: Pose, other: Pose, w: number): Pose {
  if (w <= 0) return sitting;
  if (w >= 1) return other;
  const s = clonePose(sitting);
  const [farHind, farFront, nearHind, nearFront] = s.legs;
  s.legs = [farHind, nearFront, farFront, nearHind];
  const r = blend(s, other, A.ramp(w, 0, 0.65));
  const h = blend(s, other, A.ramp(w, 0.45, 1));
  // The head turns late, but it rises or sinks with the body, so a cat lying down does not leave its head up in the air.
  r.head = { x: h.head.x, y: r.head.y };
  r.headScale = h.headScale; r.tilt = h.tilt; r.earL = h.earL; r.earR = h.earR; r.eyes = h.eyes; r.look = h.look; r.mouth = h.mouth;
  const tail = A.ramp(w, 0, 0.5);
  r.tail = swungTail(s.tail, other.tail, tail, 0);
  return r;
}

/**
 * The big cat on the terminal's ledge. The scroll says where it should be and when something happens (it is put down, a notice
 * comes, the night falls); the cat does it in time, with the app's own poses: it gets up and walks there, it celebrates and perks
 * only while it sits, it lies down and curls up as the app's cat does when it naps. It only ever walks on, the way the story goes:
 * scrolled back, it stays where it got to (the pointer picks it up from there). However slowly the page is scrolled, or wherever it
 * stops, the cat is never held halfway between two poses: when the scroll stops, it finishes the movement it is in.
 */
class LedgeCat {
  /** Where it is along the ledge: 0 at its left end, 1 where it ends up. */
  u = 0;
  /** Its speed along the ledge, in px a second. */
  private v = 0;
  /** How far up it is: 0 sitting, 1 standing side-on (and walking); it goes up or down at a steady pace, never stopping between. */
  private up = 0;
  private rising = false;
  /** When it last sat all the way down, and when it last moved along the ledge. */
  private downAt = -1e9;
  private movedAt = 0;
  private amp = 0;
  /** The distance walked, in px: the legs follow it, so the feet stay planted. */
  private walked = 0;
  /** The nap: when it began, and when it was let go of and how deep into it the cat was then (seconds along the nap's own path). */
  private nap: { start: number; release: number | null; depth: number } | null = null;
  private reaction: { kind: Reaction; start: number; release: number | null } | null = null;
  private asked: { kind: Reaction; from: number; until: number } | null = null;

  /** Taken up by the pointer, or put down: whatever it was doing is over, and it is sitting where it is. */
  reset(): void {
    this.v = 0; this.amp = 0; this.up = 0; this.rising = false; this.downAt = -1e9;
    this.nap = null; this.reaction = null; this.asked = null;
  }

  /** Back in its wing: the next time it is put down, it is at the ledge's left end. */
  home(): void { this.reset(); this.u = 0; }

  /** Found where the scroll puts it, at once (the page opened halfway through the story, or it was out of sight): asleep at night. */
  place(u: number, p: number, now: number): void {
    this.reset();
    this.u = u;
    if (p >= NAP_AT) this.nap = { start: now - A.BEDTIME_AGE, release: null, depth: 0 };
  }

  /** Put down on the ledge by the pointer. */
  land(now: number): void { this.reset(); this.reaction = { kind: 'land', start: now, release: null }; }

  /** A reaction the story asks for: done once the cat sits still, if the scroll is still between `from` and `until` by then. */
  ask(kind: Reaction, from: number, until: number): void { this.asked = { kind, from, until }; }

  /**
   * The pose for this frame. `target` is where the scroll puts the cat along the ledge (0...1), `span` the ledge's length in px,
   * `unit` the px of a rig unit, `alert` whether it is on duty.
   */
  frame(now: number, dt: number, p: number, target: number, span: number, unit: number, alert: number): { pose: Pose; life: number } {
    const gap = (Math.max(target, this.u) - this.u) * span;
    const need = gap > 1;
    const night = p >= NAP_AT;

    // To walk, it lets go of what it is doing first; and it gets up from a nap when the night is scrolled back.
    if (need && this.reaction && this.reaction.release === null) this.reaction.release = now;
    if (this.nap && this.nap.release === null && (need || p < NAP_UNTIL)) {
      this.nap.release = now; this.nap.depth = Math.min(CURLED, now - this.nap.start);
    }

    // Up and down at a steady pace: it gets up when it has somewhere to go (once it has been down a moment), and sits down when it
    // has stood still for a while. It never stops halfway, and a change of mind on the way runs back along the same path.
    if (need && !this.reaction && !this.nap && (this.up > 0 || now - this.downAt >= REST)) this.rising = true;
    else if (!need && now - this.movedAt > PAUSE) this.rising = false;
    const wasUp = this.up;
    this.up = Math.min(1, Math.max(0, this.up + (this.rising ? dt : -dt) / GET_UP));
    if (this.up === 0 && wasUp > 0) this.downAt = now;
    if (this.up > 0 && wasUp === 0) this.movedAt = now;
    const standing = this.up >= 1, seated = this.up <= 0;

    // Standing, it walks on to where the scroll puts it, at a cat's pace.
    if (standing && need) {
      const want = Math.min(WALK_SPEED * unit, gap * CATCH_UP);
      this.v += (want - this.v) * (1 - Math.exp(-dt * 8));
      const step = Math.min(gap, Math.max(0, this.v * dt));
      if (step >= gap) this.v = 0;
      this.u += step / span; this.walked += step;
      this.movedAt = now;
    } else this.v = 0;
    // A full stride when it goes at a walk, shorter steps when it only creeps, and standing when it has stopped.
    const stride = standing ? Math.min(1, this.v / (STRIDE_SPEED * unit)) : 0;
    this.amp += (stride - this.amp) * (1 - Math.exp(-dt * 6));

    const sitting = A.sit(now, alert);
    let pose = fromSit(sitting, A.walk((this.walked / (20 * unit)) * 2 * Math.PI, this.amp, now), A.smooth(this.up));
    let life = 1 - 0.65 * this.up;

    // The night: it lies down the same way it gets up, and then curls up as the app's cat does when it naps, in the nap's own
    // time (the scroll only says when). Let go of, it goes back along the very same path, faster: it uncurls, opens its eyes, and
    // sits up, so every moment of it is one the cat has already been through.
    if (!this.nap && night && !need && seated && !this.reaction) this.nap = { start: now, release: null, depth: 0 };
    if (this.nap) {
      const nap = this.nap;
      const depth = nap.release === null ? now - nap.start : nap.depth - (now - nap.release) * UNWIND;
      if (nap.release !== null && depth <= 0) { this.nap = null; this.downAt = now; }
      else {
        pose = depth < LIE_DOWN ? fromSit(sitting, A.loaf(0, 0, now), A.ramp(depth, 0, LIE_DOWN)) : A.perform('sleep', depth, A.BEDTIME_NAP, now);
        life = 1 - A.ramp(depth, 0, 0.8);
      }
    }

    // A reaction it was asked for, once it sits still (a celebration is not for a cat that walks or sleeps).
    const asked = this.asked;
    if (asked && (p < asked.from || p >= asked.until)) this.asked = null;
    else if (asked && !need && seated && !this.nap) { this.reaction = { kind: asked.kind, start: now, release: null }; this.asked = null; }
    const r = this.reaction;
    if (r) {
      const age = now - r.start, length = REACTION[r.kind];
      const letGo = r.release === null ? 1 : 1 - A.ramp(now - r.release, 0, LET_GO);
      if (age >= length || letGo <= 0) this.reaction = null;
      else {
        // Over the sit, as the app's director lays them: blended in and out, the perk eased by its own amount.
        let weight: number;
        if (r.kind === 'perk') {
          weight = A.ramp(age, 0, 0.25) * (1 - A.ramp(age, length - 0.9, length)) * letGo * PERK;
          pose = A.perked(pose, now, weight, age);
        } else if (r.kind === 'celebrate') {
          // The content cheer (it sits up tall, squints with pleasure, its tail curls up), its tail curled up `CHEER_TAIL` of the
          // way, clear of the head: the hop raises its paws over its body, which at this size reads as two black-rimmed arms.
          weight = A.ramp(age, 0, 0.1) * (1 - A.ramp(age, length - 0.3, length)) * letGo;
          const cheer = A.celebrate(age, now, 4, 'content');
          cheer.tail = blend(pose, cheer, CHEER_TAIL).tail;
          pose = blend(pose, cheer, weight);
        } else {
          // The app's landing, with its squash at impact (`A.land`: from 0.3 s, gone by 0.66 s) eased to `LANDING`, and its tail
          // swung up from where it hung in the pointer's hand to its sit as it falls.
          weight = (1 - A.ramp(age, length - 0.4, length)) * letGo;
          const impact = A.ramp(age, 0.3, 0.4) * (1 - A.ramp(age, 0.4, 0.66));
          const landed = A.squash(A.land(age, now), -(1 - LANDING) * 1.2 * impact, 0.26);
          landed.tail = swungTail(A.lifted(now).tail, landed.tail, A.ramp(age, 0, 0.45), 0);
          pose = blend(pose, landed, weight);
        }
        life *= 1 - 0.7 * weight;
      }
    }
    return { pose, life };
  }
}

/**
 * The story: the stage stays put while you scroll, and the scroll is the clock. The layers drift by different amounts, the day
 * goes from dawn to night, and the cat, the cursor and the island follow the scroll position: the pointer takes the cat from its
 * wing, drags it to a Terminal window and lets go; it lands and walks along the ledge while Claude works; the island drops a
 * notice and it perks its ears, hops for joy; and in the dark it curls up.
 *
 * The scroll decides where the cat is carried (the drag) and where it should be on the ledge; what it does there (the walk, the
 * landing, the hop, the ears, the curling up) plays in real time when the scroll asks for it (`LedgeCat`), so it looks like the app's.
 */
export function initStory(root: HTMLElement): () => void {
  const cleanups: (() => void)[] = [];
  const $ = <T extends Element = HTMLElement>(sel: string): T => {
    const el = root.querySelector<T>(sel);
    if (!el) throw new Error(`story: missing ${sel}`);
    return el;
  };
  const stage = $('[data-stage]');
  const track = $('[data-track]');
  const sky = { dawn: $('[data-sky="dawn"]'), day: $('[data-sky="day"]'), dusk: $('[data-sky="dusk"]'), night: $('[data-sky="night"]') };
  const sun = $('[data-orb="sun"]'), moon = $('[data-orb="moon"]'), stars = $('[data-stars]');
  const layers = { clouds: $('[data-layer="clouds"]'), far: $('[data-layer="far"]'), fg: $('[data-layer="fg"]') };
  const terminal = $('[data-win="terminal"]'), userWin = $('[data-win="user"]'), ledge = $('[data-ledge]');
  const connected = $('[data-connected]');
  const veil = $('[data-veil]');
  const termLines = Array.from(root.querySelectorAll<HTMLElement>('.term__line'));
  const docLines = Array.from(root.querySelectorAll<HTMLElement>('[data-doc-line]'));
  const island = $('[data-island]');
  const ctrl = new IslandController(island);
  const wingHost = island.querySelector<HTMLElement>('[data-cat-host]');
  const wingSvg = wingHost?.querySelector<SVGSVGElement>('svg.cat') ?? null;
  const catEl = $('[data-story-cat]');
  const catInner = $('[data-story-cat-inner]');
  const bigSvg = catInner.querySelector<SVGSVGElement>('svg.cat');
  const cursor = $('[data-story-cursor]');
  const caps = Array.from(root.querySelectorAll<HTMLElement>('[data-cap]'));
  const dots = Array.from(root.querySelectorAll<HTMLElement>('[data-dot]'));
  const q = (name: string) => island.querySelector<HTMLElement>(`[data-t="${name}"]`);
  const peekOk = q('peek-ok'), peekAsk = q('peek-ask'), badge = q('badge'), badge2 = q('badge2'), dotsEl = q('dots');
  if (!bigSvg) throw new Error('story: no cat');

  // The stage's size and where things sit on it, read once per layout (not per frame: a read after the frame's writes forces the
  // browser to recompute styles and layout on the spot). What moves while you scroll is known without asking: the terminal's
  // drift is GSAP's own `x`, and the stage is pinned to the top of the screen.
  const lay = { sw: 0, sh: 0, wing: { x: 0, y: 0 }, tx: 0, ty: 0, tw: 0, trackTop: 0, trackH: 0 };
  const measure = () => {
    const sr = stage.getBoundingClientRect();
    const wr = (wingHost ?? island).getBoundingClientRect();
    lay.sw = stage.clientWidth; lay.sh = stage.clientHeight;
    lay.wing = { x: wr.left + wr.width / 2 - sr.left, y: wr.bottom - 1.6 - sr.top };
    // The terminal's box without its transform (its offset parent is the stage), and its title bar is the ledge.
    lay.tx = terminal.offsetLeft; lay.ty = terminal.offsetTop + ledge.offsetTop; lay.tw = terminal.offsetWidth;
    lay.trackTop = track.getBoundingClientRect().top + window.scrollY; lay.trackH = track.offsetHeight;
  };
  measure();
  const W = () => lay.sw;
  const H = () => lay.sh;
  /** Where the stage's top is on screen: it sticks at 0 while the track scrolls past. */
  const stageTop = () => { const t = lay.trackTop - env.scrollY; return Math.min(Math.max(t, 0), t + lay.trackH - lay.sh); };
  /** The story's pointer, in screen coordinates, for the wing's cat to look at (null while it is not on screen). */
  let pointerSeen: { x: number; y: number } | null = null;

  // The wing's own cat: it blinks and watches the pointer that is coming for it (the story's, not the visitor's); the big one is
  // the one that goes places. If the page's cat sleeps, this one starts the story asleep and the pointer that comes for it wakes it,
  // slowly (the story's own doing; the page's cat stays as it was).
  const wingActor = wingSvg ? new CatActor(wingSvg, {
    pointer: true, activity: 0, sleeps: true,
    pointerSource: () => pointerSeen ? { x: pointerSeen.x, y: pointerSeen.y, seen: true, lastMove: performance.now() / 1000, lastDown: 0 } : null,
  }) : null;
  if (wingActor && wingSvg) cleanups.push(runCat(wingActor, island));

  // MARK: Reduced motion: one still scene

  const placeStatic = () => {
    const sr = stage.getBoundingClientRect();
    const tr = terminal.getBoundingClientRect();
    const lr = ledge.getBoundingClientRect();
    const x = tr.left - sr.left + tr.width * 0.64, y = lr.top - sr.top;
    catEl.style.opacity = '1';
    catInner.style.transform = `translate(${x}px, ${y}px) scale(1, 1)`;
  };
  if (env.reduced) {
    root.classList.add('is-static');
    gsap.set(sky.dawn, { opacity: 0 });
    gsap.set(sky.day, { opacity: 1 });
    gsap.set(userWin, { autoAlpha: 1 });
    gsap.set(connected, { autoAlpha: 1 });
    // The midday sun, clear of the cat: high in the middle of a wide scene; on a narrow one, peeking over the terminal's right end.
    gsap.set(sun, { x: () => W() * (W() < 761 ? 0.85 : 0.6), y: () => H() * (W() < 761 ? 0.24 : 0.2) });
    ctrl.set('peek');
    gsap.set(peekOk, { autoAlpha: 1 });
    gsap.set(badge, { autoAlpha: 0 });
    gsap.set(dotsEl, { autoAlpha: 1 });
    placeStatic();
    const actor = new CatActor(bigSvg, { pointer: false, activity: 0, working: false });
    // Attentive to the notice, as far as the moving cat perks up (`PERK`).
    actor.freeze(A.perked(basePose(), 0, PERK, 10));
    const ro = new ResizeObserver(() => { ctrl.refit(); placeStatic(); });
    ro.observe(stage);
    return () => {
      ro.disconnect();
      actor.freeze(null);
      // Leave nothing of the still scene behind for the scrolling one to start from.
      root.classList.remove('is-static');
      gsap.set([sky.dawn, sky.day, userWin, connected, sun, peekOk, badge, dotsEl, catEl, catInner], { clearProps: 'all' });
      ctrl.set('collapsed');
    };
  }

  // MARK: Geometry, read live each frame so a drifting window carries the cat with it

  // The cat's unit is whatever the CSS made it (it scales with the screen): the drawn width over the rig's 44 units.
  let unit = 3.3;
  const readUnit = () => { const w = parseFloat(getComputedStyle(bigSvg).width); unit = w > 0 ? w / 44 : 3.3; };
  readUnit();
  const wingUnit = 0.78;

  interface Geo { W: Pt; T0: Pt; T1: Pt; sw: number; sh: number; s0: number }
  const geometry = (): Geo => {
    const left = lay.tx + ((gsap.getProperty(terminal, 'x') as number) || 0);
    return {
      W: lay.wing,
      T0: { x: left + lay.tw * 0.16, y: lay.ty },
      T1: { x: left + lay.tw * 0.64, y: lay.ty },
      sw: lay.sw, sh: lay.sh, s0: wingUnit / unit,
    };
  };

  // MARK: The cat and the cursor, from the scroll

  const view = { p: 0 };
  let tl: gsap.core.Timeline;
  let prevP = 0, lastNow = 0, onLedge = false;
  // The big cat is the app's cat drawn some 150 px wide, where the flick of an eye or a turn of the head the app's cat makes at the
  // notch's size reads as a broken cat: it does not turn to the visitor's pointer or to the scroll, its tail and ears are not on
  // springs, and what it does on the ledge it does with the app's own poses (`LedgeCat`).
  const actor = new CatActor(bigSvg, { pointer: false, scroll: false, followThrough: false, activity: 0 });
  const ledgeCat = new LedgeCat();
  const events: { at: number; fn: () => void }[] = [
    { at: 0.045, fn: () => wingActor?.wake('story') },
    { at: 0.525, fn: () => ledgeCat.ask('celebrate', 0.52, 0.62) },
    { at: 0.618, fn: () => ledgeCat.ask('perk', 0.61, 0.78) },
  ];

  const nape = (c: Pt, s: number): Pt => ({ x: c.x + 1.2 * unit * s, y: c.y - 28.5 * unit * s });
  /** Where the pointer lets go of the cat over a place on the ledge: the landing falls from there. */
  const above = (c: Pt): Pt => ({ x: c.x, y: c.y - DROP_HEIGHT * unit });

  actor.setDriver((now, dt) => {
    const p = tl ? tl.progress() : view.p;
    view.p = p;
    // The first frame, or the first after the cat was out of sight: nothing that happened meanwhile plays now.
    const fresh = !lastNow || now - lastNow > 1;
    lastNow = now;
    if (fresh) prevP = p;
    const g = geometry();
    const s0 = g.s0;
    let pos: Pt = g.W, s = s0, visible = 0, pose: Pose = A.sit(now), life = 1;
    let cur: Pt | null = null, curOpacity = 0;
    const alert = p > 0.34 && p < 0.5 ? 1 : 0;

    if (p < GRAB) {
      // The pointer comes in from the right, toward the cat in its wing.
      const u = clamp01((p - 0.012) / (GRAB - 0.012));
      const start: Pt = { x: g.sw + 30, y: g.W.y + 110 };
      cur = lerpP(start, nape(g.W, s0), A.smooth(u));
      curOpacity = clamp01((p - 0.012) / 0.02);
      onLedge = false;
      ledgeCat.home();
    } else if (p < DROP) {
      // It has the cat by the scruff and carries it down to the window (or, scrolled back, up from where it had walked to on the
      // ledge): the cat grows as it comes toward us.
      const u = clamp01((p - GRAB) / (DROP - GRAB));
      const e = A.smooth(u);
      const spot = above(lerpP(g.T0, g.T1, ledgeCat.u));
      const c1: Pt = { x: g.W.x + (spot.x - g.W.x) * 0.08, y: lerp(g.W.y, spot.y, 0.6) };
      const c2: Pt = { x: lerp(g.W.x, spot.x, 0.55), y: spot.y + 8 };
      pos = cubic(g.W, c1, c2, spot, e);
      s = lerp(s0, 1, A.smooth(Math.min(1, u * 1.15)));
      visible = 1;
      pose = A.lifted(now); life = 0.1;
      cur = nape(pos, s); curOpacity = 1;
      onLedge = false;
    } else {
      visible = 1;
      s = 1;
      if (p < RELEASED) {
        const u = clamp01((p - DROP) / (RELEASED - DROP));
        const from = nape(above(lerpP(g.T0, g.T1, ledgeCat.u)), 1);
        cur = lerpP(from, { x: from.x + 150, y: from.y - 120 }, A.smooth(u));
        curOpacity = 1 - u;
      }
      // On the ledge: put down by the pointer it lands; found there (the page opened here) it is where the scroll puts it.
      const target = A.ramp(p, WALK_FROM, WALK_TO);
      if (fresh) ledgeCat.place(target, p, now);
      else if (!onLedge) ledgeCat.land(now);
      onLedge = true;
      ({ pose, life } = ledgeCat.frame(now, dt, p, target, Math.max(1, g.T1.x - g.T0.x), unit, alert));
      pos = lerpP(g.T0, g.T1, ledgeCat.u);
    }

    for (const ev of events) if (prevP < ev.at && p >= ev.at) ev.fn();
    prevP = p;
    actor.setWorking(alert > 0);

    // What the scroll moved: the big cat and the pointer (the wing's cat steps aside while the big one is out).
    catEl.style.opacity = String(visible);
    catInner.style.transform = `translate(${pos.x.toFixed(2)}px, ${pos.y.toFixed(2)}px) scale(${s.toFixed(4)})`;
    // The wing's cat steps aside while the big one is out, and is not drawn at all meanwhile (nothing repaints for a cat nobody sees).
    const wingOn = p < GRAB - 0.002;
    if (wingHost) wingHost.style.opacity = wingOn ? '1' : '0';
    if (wingActor && wingActor.visible !== wingOn) { wingActor.visible = wingOn; if (wingOn) wingActor.resume(now); }
    if (cur) {
      cursor.style.opacity = String(curOpacity);
      cursor.style.transform = `translate(${cur.x.toFixed(2)}px, ${cur.y.toFixed(2)}px)`;
      pointerSeen = curOpacity > 0.1 ? { x: cur.x, y: cur.y + stageTop() } : null;
    } else { cursor.style.opacity = '0'; pointerSeen = null; }
    return { pose, life };
  });
  cleanups.push(runCat(actor, stage));

  // MARK: The pointer adds depth

  // With a mouse, the far layers lean away from the pointer and the near ones toward it, a few pixels, so the scene has depth
  // when you are not scrolling too. Only the sky's layers move: the windows stay put (the cat stands on the terminal). The CSS
  // `translate` property composes with the transform the scroll sets, and eases each change (story.css).
  if (!env.touch) {
    const depth: [HTMLElement, number, number][] = [[layers.clouds, -14, -8], [layers.far, -24, -12], [layers.fg, 44, 24]];
    let raf = 0, nx = 0, ny = 0;
    const apply = () => {
      raf = 0;
      for (const [el, kx, ky] of depth) el.style.translate = `${(nx * kx).toFixed(1)}px ${(ny * ky).toFixed(1)}px`;
    };
    const onMove = (e: PointerEvent) => {
      if (e.pointerType !== 'mouse' || !document.documentElement.classList.contains('in-story')) return;
      nx = e.clientX / window.innerWidth - 0.5; ny = e.clientY / window.innerHeight - 0.5;
      if (!raf) raf = requestAnimationFrame(apply);
    };
    window.addEventListener('pointermove', onMove, { passive: true });
    cleanups.push(() => { window.removeEventListener('pointermove', onMove); cancelAnimationFrame(raf); depth.forEach(([el]) => { el.style.translate = ''; }); });
  }

  // MARK: The layers, the sky, the island, the captions: one timeline, the scroll is its clock

  const ctx = gsap.context(() => {
    tl = gsap.timeline({
      defaults: { ease: 'none' },
      scrollTrigger: {
        trigger: track, start: 'top top', end: 'bottom bottom', scrub: 0.5, invalidateOnRefresh: true,
        onUpdate: (self) => {
          const p = self.progress;
          const beat = BEATS.findIndex((b, i) => p >= b && p < (BEATS[i + 1] ?? 2));
          dots.forEach((d, i) => d.classList.toggle('is-on', i === beat));
        },
        onToggle: (self) => document.documentElement.classList.toggle('in-story', self.isActive),
      },
    });

    // The day goes by: each sky fades to show the next one under it.
    tl.to(sky.dawn, { opacity: 0, duration: 0.22 }, 0.14)
      .to(sky.day, { opacity: 0, duration: 0.2 }, 0.5)
      .to(sky.dusk, { opacity: 0, duration: 0.14 }, 0.74)
      .fromTo(stars, { opacity: 0 }, { opacity: 1, duration: 0.14 }, 0.8)
      .fromTo(veil, { opacity: 0 }, { opacity: 1, duration: 0.14 }, 0.78);
    // The sun crosses the sky and sets; the moon rises where it was not.
    const orbs = { p: 0 };
    tl.fromTo(orbs, { p: 0 }, {
      p: 1, duration: 1,
      onUpdate: () => {
        const u = clamp01(orbs.p / 0.84);
        // On a narrow screen the cat sits right of the middle, just under the sky, so the sun goes the other way and higher:
        // over the cat's head while it walks, and to its left once it sits (never behind it); the moon rises clear of it too.
        const narrow = W() < 761;
        const sx = narrow ? lerp(W() * 0.95, 0, u) : lerp(W() * 0.1, W() * 0.9, u);
        const sy = H() * (0.66 - (narrow ? 0.6 : 0.5) * Math.sin(Math.PI * u));
        sun.style.transform = `translate3d(${sx.toFixed(1)}px, ${sy.toFixed(1)}px, 0)`;
        sun.style.opacity = String(1 - A.ramp(orbs.p, 0.72, 0.84));
        const m = A.ramp(orbs.p, 0.78, 0.9);
        moon.style.opacity = String(m);
        moon.style.transform = `translate3d(${(W() * (narrow ? 0.87 : 0.74 + 0.06 * orbs.p)).toFixed(1)}px, ${(H() * (narrow ? 0.15 : 0.17)).toFixed(1)}px, 0)`;
      },
    }, 0);
    // Depth: the farther a layer, the less it travels.
    tl.to(layers.clouds, { x: () => -W() * 0.2, duration: 1 }, 0)
      .to(layers.far, { x: () => -W() * 0.07, y: () => -H() * 0.03, duration: 1 }, 0)
      .to(terminal, { x: () => -W() * 0.025, duration: 1 }, 0)
      .to(layers.fg, { x: () => -W() * 0.34, y: () => -H() * 0.12, duration: 1 }, 0);
    tl.fromTo(userWin, { x: () => W() * 0.2, autoAlpha: 0 }, { x: 0, autoAlpha: 1, duration: 0.11, ease: 'power2.out' }, 0.3)
      .to(userWin, { x: () => -W() * 0.05, duration: 0.6 }, 0.41);
    // Claude works in the terminal; the visitor works in their own window.
    const lineAt = [0, 0, 0.31, 0.35, 0.37, 0.41, 0.43, 0.46, 0.48, 0.5];
    termLines.forEach((line, i) => {
      const at = lineAt[i];
      if (at === undefined || at === 0 || i >= lineAt.length) return;
      tl.fromTo(line, { autoAlpha: 0, y: 6 }, { autoAlpha: 1, y: 0, duration: 0.02, ease: 'power2.out' }, at);
    });
    tl.fromTo(docLines, { scaleX: 0.12 }, { scaleX: 1, duration: 0.07, stagger: 0.05, ease: 'power1.out' }, 0.34);
    tl.fromTo(connected, { autoAlpha: 0, y: 10, scale: 0.94 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.03, ease: 'back.out(1.8)' }, DROP + 0.01)
      .to(connected, { autoAlpha: 0, y: -6, duration: 0.03 }, 0.5);
    // The island: notices drop, a badge stays.
    if (peekOk && peekAsk && badge && badge2 && dotsEl) {
      ctrl.set('collapsed');
      gsap.set([peekOk, peekAsk, badge, badge2], { autoAlpha: 0 });
      tl.add(ctrl.morph('collapsed', 'peek', { duration: 0.035, ease: 'power2.out' }), 0.505)
        .fromTo(peekOk, { autoAlpha: 0, y: -8 }, { autoAlpha: 1, y: 0, duration: 0.025 }, 0.52)
        .to(peekOk, { autoAlpha: 0, duration: 0.02 }, 0.585)
        .add(ctrl.morph('peek', 'collapsed', { duration: 0.035, ease: 'power2.inOut' }), 0.59)
        .to(dotsEl, { autoAlpha: 0, duration: 0.02 }, 0.59)
        .fromTo(badge, { autoAlpha: 0, scale: 0.6 }, { autoAlpha: 1, scale: 1, duration: 0.02, ease: 'back.out(2)' }, 0.615)
        .add(ctrl.morph('collapsed', 'peek', { duration: 0.035, ease: 'power2.out' }), 0.63)
        .fromTo(peekAsk, { autoAlpha: 0, y: -8 }, { autoAlpha: 1, y: 0, duration: 0.025 }, 0.645)
        .to(peekAsk, { autoAlpha: 0, duration: 0.02 }, 0.71)
        .add(ctrl.morph('peek', 'collapsed', { duration: 0.035, ease: 'power2.inOut' }), 0.715)
        .to(badge, { autoAlpha: 0, duration: 0.02 }, 0.715)
        .fromTo(badge2, { autoAlpha: 0, scale: 0.6 }, { autoAlpha: 1, scale: 1, duration: 0.02, ease: 'back.out(2)' }, 0.73);
    }
    // The words: one beat at a time.
    caps.forEach((cap, i) => {
      const start = BEATS[i] ?? 0, end = BEATS[i + 1] ?? 1;
      tl.fromTo(cap, { autoAlpha: 0, y: 26 }, { autoAlpha: 1, y: 0, duration: 0.035, ease: 'power2.out' }, start + (i === 0 ? 0.005 : 0.012));
      if (i < caps.length - 1) tl.to(cap, { autoAlpha: 0, y: -18, duration: 0.03, ease: 'power2.in' }, end - 0.035);
    });
    tl.to({}, { duration: 0.0001 }, 1);
  }, root);

  const ro = new ResizeObserver(() => { ctrl.refit(); readUnit(); measure(); });
  ro.observe(stage);
  // ScrollTrigger re-measures on a resize and when the fonts or the page above change height; the story measures first, so the
  // timeline's values (functions of the stage's size) are worked out from the new layout.
  const onRefresh = () => measure();
  ScrollTrigger.addEventListener('refreshInit', onRefresh);
  cleanups.push(() => { ro.disconnect(); ScrollTrigger.removeEventListener('refreshInit', onRefresh); ctx.revert(); actor.setDriver(null); document.documentElement.classList.remove('in-story'); });
  // Everything is measured once the fonts are in.
  void document.fonts?.ready.then(() => ScrollTrigger.refresh());
  return () => cleanups.forEach((fn) => fn());
}
