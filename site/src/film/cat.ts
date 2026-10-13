import { gsap } from 'gsap';
import * as A from '../cat/anim';
import { applyLife, temperamentOf } from '../cat/life';
import { blend, clonePose, type Action, type Pose } from '../cat/pose';
import { bindCat, defaultLook, type CatView, type Look } from '../cat/render';

/**
 * A cat of the film. The page's other cats live on their own clocks (`CatActor`); this one is a pure function of the film's time, made
 * of the app's own poses (`anim.ts`): the sit and its breathing, the gestures and reactions the script asks for, its small life
 * (`life.ts`) and its eyes on the cursor. So the film can be paused, sought and drawn frame by frame, and every frame is one the cat
 * would really show. Nothing here invents a pose: a gesture is `perform`, a cheer is `celebrate`, a perk is `perked`, a nap is the
 * app's nap and the sad cat is `sad`, mixed the way the pet director mixes them (`actor.ts`).
 *
 * It is never left showing a blend between two poses: when the film pauses, the cat settles into the still of what it is doing (the
 * sit, its curled nap, the drooped sad cat) in a quarter of a second, and when the film goes on it eases back into the take.
 */

export type GestureName = 'wave' | 'glance' | 'yawn' | 'groom';

type CatEvent =
  | { kind: 'gesture'; at: number; name: GestureName; length: number; variant: number }
  | { kind: 'celebrate'; at: number; style: A.Cheer; length: number }
  | { kind: 'perk'; at: number; length: number }
  | { kind: 'work'; at: number; on: boolean }
  | { kind: 'nap'; at: number }
  | { kind: 'sad'; at: number; length: number }
  | { kind: 'blink'; at: number }
  | { kind: 'look'; at: number; look: Look };

/** What the cat can see this frame: the cursor (in on-screen pixels), how visible it is, and where and how big the cat is. */
export interface Sight {
  cursor: { x: number; y: number; alpha: number } | null;
  /** The cat's centre and width, in on-screen pixels. */
  cat: { x: number; y: number; w: number };
}

export interface FilmCatOptions {
  /** A cat drawn large (on a stage, in the cat's close-up): its small life and its gaze are damped, so nothing in it shows too much. */
  big?: boolean;
  /** Height of a celebration hop, in rig units (4 is the wing's, 5 a stage's). */
  hop?: number;
  /** Offsets this cat's clock for its small life, so two cats do not blink at the same moment. */
  seed?: number;
}

const LENGTH: Record<GestureName, number> = { wave: 3.4, glance: A.GLANCE_LENGTH, yawn: A.YAWN_LENGTH, groom: A.GROOM_LENGTH };
const ACTION: Record<GestureName, Action> = { wave: 'wave', glance: 'glance', yawn: 'yawn', groom: 'groom' };
/** How long the cat takes to settle when the film pauses, and to ease back into the take when it plays on. */
const SETTLE = 0.25;
/**
 * The stills of a nap, by how far into it the cat is: the app's nap (`perform('sleep')`) at the ends of its stages, never inside one.
 * Just begun, it holds the sit; lying down, the loaf it lies down into (1.6 s in); resting, the loaf with its eyes shut (2.9 s, before it
 * curls); curling up or curled, the curled sleeper. Each still is the nearest end of the stage it is in.
 */
const NAP_STILLS: [number, number | 'curled' | 'sit'][] = [[0.6, 'sit'], [2.25, 1.6], [3.85, 2.9], [Infinity, 'curled']];
const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));
const temperament = temperamentOf('curious', 'day');

export class FilmCat {
  readonly view: CatView;
  readonly svg: SVGSVGElement;
  /** The element whose visibility says whether the cat is on screen (its shot, or the cat's stage). */
  readonly gate: HTMLElement;
  private events: CatEvent[] = [];
  private opts: FilmCatOptions;
  private last: Pose | null = null;
  private lastLook: Look = defaultLook;
  private settle: gsap.core.Tween | null = null;
  /** Playing on after a pause: the pose it eases from, and when (on the page's clock) the easing began. */
  private resume: { from: Pose; at: number } | null = null;

  constructor(svg: SVGSVGElement, gate: HTMLElement, opts: FilmCatOptions = {}) {
    this.svg = svg;
    this.gate = gate;
    this.opts = opts;
    this.view = bindCat(svg);
  }

  // MARK: The script

  /** Forgets every event (the timeline is being rebuilt). */
  clear(): void { this.events = []; }

  gesture(at: number, name: GestureName, variant = 0): number { this.events.push({ kind: 'gesture', at, name, length: LENGTH[name], variant }); return LENGTH[name]; }
  celebrate(at: number, style: A.Cheer = 'hop'): void { this.events.push({ kind: 'celebrate', at, style, length: A.cheerLength(style) }); }
  perk(at: number, length = 3.2): void { this.events.push({ kind: 'perk', at, length }); }
  work(at: number, on: boolean): void { this.events.push({ kind: 'work', at, on }); }
  nap(at: number): void { this.events.push({ kind: 'nap', at }); }
  sad(at: number, length: number): void { this.events.push({ kind: 'sad', at, length }); }
  blink(at: number): void { this.events.push({ kind: 'blink', at }); }
  dress(at: number, look: Look): void { this.events.push({ kind: 'look', at, look }); }

  /** Whether it is in sight at the moment (its shot or stage is showing). */
  get shown(): boolean { return (gsap.getProperty(this.gate, 'autoAlpha') as number) > 0.001; }

  // MARK: Poses

  private latest<K extends CatEvent['kind']>(kind: K, t: number): Extract<CatEvent, { kind: K }> | null {
    let found: Extract<CatEvent, { kind: K }> | null = null;
    for (const e of this.events) if (e.kind === kind && e.at <= t && (!found || e.at >= found.at)) found = e as Extract<CatEvent, { kind: K }>;
    return found;
  }

  private lookAt(t: number): Look { return this.latest('look', t)?.look ?? defaultLook; }

  /** How much on duty it is: the app's working posture, eased in and out over a third of a second. */
  private alertAt(t: number): number {
    let a = 0;
    const works = this.events.filter((e): e is Extract<CatEvent, { kind: 'work' }> => e.kind === 'work' && e.at <= t).sort((x, y) => x.at - y.at);
    for (const w of works) a = w.on ? a + (1 - a) * A.ramp(t, w.at, w.at + 0.35) : a * (1 - A.ramp(t, w.at, w.at + 0.35));
    return a;
  }

  private napAt(t: number): number | null { const n = this.latest('nap', t); return n ? t - n.at : null; }

  private sadAt(t: number): number | null {
    const s = this.latest('sad', t);
    return s && t < s.at + s.length ? t - s.at : null;
  }

  /** The eyes and head on the cursor (the pet director's `attend`), and the cat's curiosity when it comes close: damped on a big cat. */
  private attend(p: Pose, sight: Sight | null, life: number): void {
    const c = sight?.cursor;
    if (!sight || !c || c.alpha <= 0.01) return;
    const damp = this.opts.big ? 0.5 : 1;
    const w = Math.max(1, sight.cat.w);
    const dx = c.x - sight.cat.x, dy = c.y - sight.cat.y;
    const scale = Math.max(90, w * 2.2);
    const gx = clamp(dx / scale, -1, 1), gy = clamp(-dy / scale, -1, 1);
    const enter = Math.max(120, w * 3.2);
    const curious = (1 - A.ramp(Math.hypot(dx, dy), enter * 0.8, enter * 1.25)) * c.alpha * damp;
    const f = c.alpha * (1 - curious * 0.6) * life * damp;
    p.look.x += 1.25 * gx * f; p.look.y += 0.7 * gy * f;
    p.head.x += 0.5 * gx * f; p.head.y += 0.25 * Math.max(0, gy) * f;
    p.tilt += -0.045 * gx * f;
    if (curious > 0.01 && life > 0.2) Object.assign(p, A.curious(p, A.gaze(gx, gy), curious * Math.min(1, life * 1.4), 0, true));
  }

  /** The cat at `t` seconds into the film, as the take has it. */
  live(t: number, sight: Sight | null): Pose {
    const sadU = this.sadAt(t);
    // The sad cat's scene is all there is while it plays: a pure function of its own time, as the quit demo plays it.
    if (sadU !== null) return A.sad(sadU, A.sadAmount(sadU));
    const clock = t + (this.opts.seed ?? 0);
    const alert = this.alertAt(t);
    const napAge = this.napAt(t);
    if (napAge !== null) {
      // Falling asleep: the app's nap from the sit (it lies down, closes its eyes and curls up), its small life fading as it lies down.
      const p = clonePose(A.asleepAt(napAge, clock));
      const life = 1 - A.ramp(napAge, 0, 0.8);
      if (life > 0.02) applyLife(p, { time: clock, temperament, restful: life * (this.opts.big ? 0.5 : 1), quiet: 1, rate: 1, alert: 0 });
      return p;
    }

    let base = A.sit(clock, alert);
    let life = 1;
    const g = this.latest('gesture', t);
    if (g && t < g.at + g.length) {
      const u = t - g.at;
      base = A.perform(ACTION[g.name], u, g.length, clock, { alert, variant: g.variant });
      // How much of its small life the gesture leaves it (`PetDirector.lifeWeight`).
      const presence = A.ramp(u, 0, 0.8) * (1 - A.ramp(u, g.length - 0.8, g.length));
      life = 1 - presence * 0.65;
    }
    // The reactions over everything, as the actor lays them on.
    const cheer = this.latest('celebrate', t);
    const perk = this.latest('perk', t);
    const reaction = cheer && perk ? (cheer.at > perk.at ? cheer : perk) : cheer ?? perk;
    if (reaction && t < reaction.at + reaction.length) {
      const u = t - reaction.at;
      if (reaction.kind === 'celebrate') {
        const w = A.ramp(u, 0, 0.1) * (1 - A.ramp(u, reaction.length - 0.3, reaction.length));
        base = blend(base, A.celebrate(u, clock, this.opts.hop ?? 4, reaction.style), w);
        life *= 1 - 0.7 * w;
      } else {
        const amount = A.ramp(u, 0, 0.25) * (1 - A.ramp(u, reaction.length - 0.9, reaction.length));
        base = A.perked(base, clock, amount, u);
        life *= 0.3;
      }
    }
    const p = clonePose(base);
    this.attend(p, sight, life);
    applyLife(p, { time: clock, temperament, restful: life * (this.opts.big ? 0.5 : 1), quiet: 1, rate: 1, alert });
    // A blink the script asks for: the app's blink, lids down in a third of the time they take to come up.
    const b = this.latest('blink', t);
    if (b && t - b.at < 0.24) {
      const u = (t - b.at) / 0.24;
      p.eyes *= 1 - (u < 0.34 ? A.ramp(u, 0, 0.34) : 1 - A.ramp(u, 0.34, 1));
    }
    return p;
  }

  /** The still of what the cat is doing at `t`: what a paused film shows, and the frame with motion reduced. */
  still(t: number, sight: Sight | null): Pose {
    const sadU = this.sadAt(t);
    if (sadU !== null) return A.sad(Math.max(sadU, A.SAD_ENTRANCE + 0.2), 1);
    const napAge = this.napAt(t);
    if (napAge !== null) {
      const still = NAP_STILLS.find(([until]) => napAge < until)?.[1] ?? 'curled';
      if (still === 'curled') return A.asleepPose();
      if (still !== 'sit') return A.asleepAt(still, 0);
    }
    const p = A.sit(0, this.alertAt(t) > 0.5 ? 1 : 0);
    this.attend(p, sight, 1);
    return p;
  }

  // MARK: Painting

  private draw(pose: Pose, t: number): void {
    const look = this.lookAt(t);
    this.view.paint(pose, look);
    this.last = pose;
    this.lastLook = look;
  }

  /** Paints the take at `t`. Right after a pause it eases out of the still it held. */
  paint(t: number, sight: Sight | null): void {
    this.settle?.kill();
    this.settle = null;
    let pose = this.live(t, sight);
    if (this.resume) {
      const u = (performance.now() / 1000 - this.resume.at) / SETTLE;
      if (u >= 1) this.resume = null;
      else pose = blend(this.resume.from, pose, A.smooth(u));
    }
    this.draw(pose, t);
  }

  /** Paints the still at `t` at once (a paused film that is sought, the frame for reduced motion). */
  paintStill(t: number, sight: Sight | null): void {
    this.settle?.kill();
    this.settle = null;
    this.resume = null;
    this.draw(this.still(t, sight), t);
  }

  /** The film paused at `t`: the cat settles into its still, in time. */
  hold(t: number, sight: Sight | null): void {
    this.resume = null;
    const to = this.still(t, sight);
    const from = this.last;
    this.settle?.kill();
    if (!from) { this.draw(to, t); return; }
    const proxy = { u: 0 };
    this.settle = gsap.to(proxy, { u: 1, duration: SETTLE, ease: 'power2.inOut', onUpdate: () => this.draw(blend(from, to, proxy.u), t), onComplete: () => { this.settle = null; } });
  }

  /** The film plays on: the next frames ease out of whatever the cat shows now. */
  release(): void {
    this.settle?.kill();
    this.settle = null;
    if (this.last) this.resume = { from: clonePose(this.last), at: performance.now() / 1000 };
  }

  /** The coat it wears at the moment (for the coat montage's label). */
  get look(): Look { return this.lastLook; }
}
