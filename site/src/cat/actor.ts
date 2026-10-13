/**
 * A living cat on the page. It is the app's pet director and life layer in small: it breathes, blinks, flicks an ear, looks
 * at the pointer, gets curious when the pointer lingers, starts a gesture now and then (the hour of the day tilts which), naps
 * when nobody is around, and reacts to what the page tells it (an alert, a finished task, a poke). Frames are only painted
 * while the cat is on screen and the tab is visible, and only when the picture changed enough to notice.
 *
 * A cat that `sleeps` shares the page's sleep (see `slumber.ts`): it may start the visit curled up, it stirs when the pointer
 * comes close, it wakes slowly when it is touched or the light comes on, and it dozes off again after a long quiet.
 */
import {
  blend, clonePose, distance, staged, type Pose,
} from './pose';
import * as A from './anim';
import { bindCat, defaultLook, type CatView, type Look } from './render';
import { env, type DayPart } from '../scripts/env';
import { slumber, type WakeCause } from './slumber';
import { Secondary } from './secondary';
import { isNight } from './night';
import { applyLife, temperamentOf, type Personality } from './life';

export { applyLife, temperamentOf, type Personality, type Temperament } from './life';

export type GestureKind = 'nap' | 'groom' | 'glance' | 'yawn' | 'stretch' | 'wave' | 'play' | 'peek' | 'loaf' | 'hunt' | 'scratch' | 'startle' | 'tailPlay';
export const PERSONALITIES: Personality[] = ['curious', 'playful', 'calm', 'sleepy'];
export const GESTURES: GestureKind[] = ['glance', 'groom', 'yawn', 'stretch', 'scratch', 'startle', 'tailPlay', 'loaf', 'hunt', 'play', 'wave', 'nap'];

// MARK: What the cat feels like doing

/** Seconds into a nap by which the cat has lain down, closed its eyes and curled up (the app's nap routine is settled by 4.7). */
const NAP_SETTLED = 5;

const napAfter = 25; // seconds of stillness a curious cat needs (the app waits minutes; a page is not a Mac left alone)

export function napThreshold(personality: Personality, dayPart: DayPart): number {
  let t = personality === 'playful' ? 90 : personality === 'calm' ? 40 : personality === 'sleepy' ? 16 : napAfter;
  if (dayPart === 'night') t *= 0.6;
  return t;
}

function bias(kind: GestureKind, personality: Personality, dayPart: DayPart): number {
  let w = 1;
  const k = kind;
  switch (personality) {
    case 'curious': if (k === 'glance' || k === 'peek') w = 1.3; else if (k === 'hunt') w = 1.2; break;
    case 'playful':
      if (k === 'play' || k === 'tailPlay') w = 2; else if (k === 'hunt') w = 2.3; else if (k === 'startle' || k === 'wave' || k === 'peek') w = 1.4;
      else if (k === 'stretch') w = 1.2; else if (k === 'loaf' || k === 'nap') w = 0.45; else if (k === 'yawn' || k === 'groom') w = 0.7;
      break;
    case 'calm':
      if (k === 'loaf') w = 2.2; else if (k === 'groom') w = 1.5; else if (k === 'glance' || k === 'yawn' || k === 'stretch') w = 1.25;
      else if (k === 'play' || k === 'wave') w = 0.5; else if (k === 'hunt' || k === 'startle') w = 0.4;
      break;
    case 'sleepy':
      if (k === 'nap') w = 3; else if (k === 'yawn') w = 2.8; else if (k === 'loaf') w = 2.2; else if (k === 'stretch' || k === 'groom') w = 1.4;
      else if (k === 'play' || k === 'hunt' || k === 'tailPlay') w = 0.25; else if (k === 'peek' || k === 'wave') w = 0.4;
      break;
  }
  if (dayPart === 'night') { if (k === 'yawn') w *= 2; else if (k === 'nap' || k === 'loaf') w *= 1.4; else if (k === 'play' || k === 'hunt') w *= 0.6; }
  else if (dayPart === 'morning') { if (k === 'stretch') w *= 1.6; else if (k === 'yawn') w *= 1.3; }
  else if (dayPart === 'evening' && k === 'play') w *= 1.2;
  return w;
}

const BASE_WEIGHT: Record<GestureKind, number> = { nap: 6, groom: 3, glance: 2.5, yawn: 1.8, stretch: 2, wave: 1.2, play: 2, peek: 1.5, loaf: 1.6, hunt: 1.6, scratch: 1.4, startle: 0.45, tailPlay: 0.8 };

export function cheerFor(personality: Personality): A.Cheer {
  return personality === 'curious' ? 'hop' : personality === 'playful' ? 'doubleHop' : 'content';
}

const pauseScale = (p: Personality): number => (p === 'playful' ? 0.75 : p === 'calm' ? 1.2 : p === 'sleepy' ? 1.35 : 1);

// MARK: The actor

export interface CatOptions {
  look?: Look;
  personality?: Personality;
  /** Gestures it may start by itself. */
  gestures?: GestureKind[];
  /** How active it is: 0 starts no gestures (it still breathes, blinks and reacts), 1 is normal, 2 is lively. */
  activity?: number;
  /** Follows the pointer with its eyes and head, and gets curious when it is close. */
  pointer?: boolean;
  /** Glances up or down as the page scrolls under it (on unless false: a cat on a stage that stays put has nothing scrolling under it). */
  scroll?: boolean;
  /**
   * The follow-through: the tail, ears and head on springs (on unless false). A cat whose every pose is directed, drawn large, does
   * without it: a spring that lags a quick change of pose bunches the tail into a lump that shows at that size.
   */
  followThrough?: boolean;
  /** On duty: eyes a little wider, ears forward, and it does not wander off into gestures. */
  working?: boolean;
  /** Height of a celebration hop, in rig units (4 is the wing's). */
  hop?: number;
  /** Called when the cat has something to say (a poke, an alert, a wake); the page decides how to show it. */
  onSay?: (kind: 'mew' | 'cheer' | 'sleepy' | 'wake' | 'woke' | 'light') => void;
  /** Shares the page's sleep: curled up while the page's cat sleeps, woken by a touch or the light. */
  sleeps?: boolean;
  /** The pose it holds when it must not move and is awake, if not the plain sit (the peeking cat has its own). */
  still?: () => Pose;
  /** Lowest visible rig y for a peek; peeks are only chosen when set. */
  ledge?: number;
  /** Where the cat's attention comes from, if not the visitor's pointer (a demo's synthetic cursor). */
  pointerSource?: () => PointerLike | null;
}

export interface PointerLike { x: number; y: number; seen: boolean; lastMove: number; lastDown: number }

interface Running { kind: GestureKind; start: number; length: number; variant: number; facing: 1 | -1; release: number | null }
interface Reaction { kind: 'celebrate' | 'perk' | 'land' | 'startle'; start: number; length: number; style?: A.Cheer; variant?: number }

const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));

export class CatActor {
  readonly view: CatView;
  readonly svg: SVGSVGElement;
  look: Look;
  personality: Personality;
  working: boolean;
  visible = false;
  /** Poses it painted last, to skip a frame that would look the same. */
  private painted: Pose | null = null;
  private paintedAt = 0;
  /** Until when it keeps the screen's own rate after its picture last moved: the pauses between the beats of a movement keep it. */
  private fastUntil = 0;
  private opts: CatOptions;
  private running: Running | null = null;
  private reaction: Reaction | null = null;
  private lastKind: GestureKind | null = null;
  private nextAt: number;
  private picks = Math.floor(Math.random() * 1000);
  private seed = Math.floor(Math.random() * 100000);
  private driver: ((now: number, dt: number) => { pose: Pose; life?: number } | null) | null = null;
  private frozen: Pose | null = null;
  // pointer awareness
  private rect: DOMRect | null = null;
  private rectAt = 0;
  private near = false;
  private curiousAmount = 0;
  private curiousSince = 0;
  private gx = 0;
  private gy = 0;
  private followAmount = 0;
  private hover = 0;
  private hovering = false;
  private scrollLook = 0;
  private unit = 0.8;
  private lastTick = 0;
  /** The follow-through (the app's `PetSecondary`): the tail, ears and head follow the pose on springs, so nothing stops dead. */
  private secondary = new Secondary();
  private pokes = 0;
  private lastPoke = 0;
  // sleep
  private readonly sleeper: boolean;
  private nightLook = true;
  private phase: 'awake' | 'asleep' | 'waking' = 'awake';
  /** When the waking began, and how far into its nap the cat was then (the pose it wakes from). */
  private phaseAt = 0;
  private sleptAge = 0;
  /** A nap is a gesture of the app's with an age: seconds since it began, plus where it began (a cat put to bed is found deep in it). */
  private napBase = 0;
  private napFrom = 0;
  private wakeKind: 'touch' | 'light' = 'touch';
  private stirAt: number | null = null;
  private lastStir = -99;
  private dozePending = false;
  private afterWake: (() => void)[] = [];
  private stillTimer = 0;
  private lastNow = 0;
  private off: (() => void) | null = null;

  constructor(svg: SVGSVGElement, opts: CatOptions = {}) {
    this.svg = svg;
    this.opts = opts;
    this.look = opts.look ?? defaultLook;
    this.personality = opts.personality ?? 'curious';
    this.working = !!opts.working;
    this.view = bindCat(svg);
    this.view.setLook(this.look);
    this.nextAt = performance.now() / 1000 + 3.5 + Math.random() * 3;
    this.measure(true);
    this.sleeper = !!opts.sleeps;
    if (this.sleeper) {
      this.off = slumber.on((e) => { if (e.type === 'wake') this.wake(e.cause); else this.doze(); });
      if (slumber.asleep) {
        // Put to bed: found deep in a nap that nothing but a touch or the light ends. Drawn asleep at once, so it is never seen awake first.
        const now = performance.now() / 1000;
        this.phase = 'asleep'; this.napBase = A.BEDTIME_AGE; this.napFrom = now;
        this.paintNow(env.reduced ? A.asleepPose() : A.asleepAt(this.napAge(now), now));
      }
    }
  }

  // MARK: Controls

  setLook(look: Look): void { this.look = look; this.painted = null; }
  setPersonality(p: Personality): void { this.personality = p; }
  /** Whether the night hours make the cat sleepy-eyed (on by default; a visitor who picks its character decides for themselves). */
  setNightLook(on: boolean): void { this.nightLook = on; }
  setWorking(on: boolean): void { this.working = on; }
  setGestures(gestures: GestureKind[]): void { this.opts = { ...this.opts, gestures }; }
  setActivity(a: number): void { this.opts = { ...this.opts, activity: a }; }
  /** An external director supplies the pose (the story's walk, its drag and landing); the small life still goes on over it. */
  setDriver(fn: ((now: number, dt: number) => { pose: Pose; life?: number } | null) | null): void { this.driver = fn; this.painted = null; kick(); }
  /** Holds one pose (Reduce Motion) until `null`. */
  freeze(pose: Pose | null): void { this.frozen = pose; this.painted = null; if (pose) this.paintNow(pose); }

  /** Starts `kind` now, as the rhythm would when its time comes. (A cat that sleeps does nothing until it is awake.) */
  start(kind: GestureKind, now = performance.now() / 1000, variant?: number): void {
    if (this.sleeper && this.phase !== 'awake') return;
    const pick = this.picks++;
    const roll = (salt: number) => A.hash(pick, this.seed + salt);
    const r: Running = { kind, start: now, length: 3, variant: variant ?? 0, facing: roll(97) < 0.5 ? 1 : -1, release: null };
    switch (kind) {
      case 'groom': r.length = A.GROOM_LENGTH; r.variant = variant ?? (roll(83) < 0.35 ? 1 : 0); break;
      case 'glance': r.length = A.GLANCE_LENGTH; r.variant = variant ?? Math.floor(roll(83) * 4) % 4; break;
      case 'stretch': r.length = 7.0; break;
      case 'wave': r.length = 3.4; break;
      case 'play': r.length = 6.4; break;
      case 'peek': r.length = A.PEEK_LENGTH; break;
      case 'nap': r.length = 16 + roll(47) * 10; break;
      case 'yawn': r.length = A.YAWN_LENGTH; break;
      case 'scratch': r.length = A.SCRATCH_LENGTH; break;
      case 'startle': r.length = A.STARTLE_LENGTH; r.variant = variant ?? (roll(83) < 0.5 ? 0 : 1); break;
      case 'tailPlay': r.length = A.TAILPLAY_LENGTH; break;
      case 'loaf': r.variant = variant ?? (roll(83) < 0.55 ? 1 : 0); r.length = r.variant === 1 ? 12 + roll(53) * 5 : 8 + roll(53) * 5; break;
      case 'hunt': r.variant = variant ?? (roll(83) < 0.45 ? 1 : 0); r.length = A.huntLength(r.variant); r.facing = 1; break;
    }
    this.running = r;
    this.reaction = null;
    kick();
  }

  /** The task finished: a single glad gesture. */
  celebrate(now = performance.now() / 1000): void {
    if (this.sleeper && this.phase !== 'awake') return;
    const style = cheerFor(this.personality);
    this.reaction = { kind: 'celebrate', start: now, length: A.cheerLength(style), style };
    this.running = null;
    this.opts.onSay?.('cheer');
    kick();
  }

  /** Something wants attention: ears up, a small mew. */
  perk(now = performance.now() / 1000, length = 3.2): void {
    if (this.sleeper && this.phase !== 'awake') return;
    this.reaction = { kind: 'perk', start: now, length };
    if (this.running) this.running.release = this.running.release ?? now;
    this.opts.onSay?.('mew');
    kick();
  }

  /** A soft landing after being carried. */
  land(now = performance.now() / 1000): void {
    this.reaction = { kind: 'land', start: now, length: A.LAND_LENGTH + 0.6 };
    this.running = null;
    kick();
  }

  /** A poke (click or tap): a mew, then a hop; quick pokes startle it. A sleeper that is poked wakes, slowly. */
  poke(now = performance.now() / 1000): void {
    kick();
    if (this.sleeper && this.phase !== 'awake') {
      // The page's cat wakes (and so do the others); if this one is asleep on its own, it wakes by itself.
      slumber.wake('touch');
      this.wake('touch', now);
      return;
    }
    this.markActive(now);
    if (env.reduced) { this.opts.onSay?.('mew'); return; }
    const quick = now - this.lastPoke < 0.8;
    this.lastPoke = now;
    this.pokes++;
    if (quick) { this.reaction = { kind: 'startle', start: now, length: A.STARTLE_LENGTH, variant: this.pokes % 2 }; this.running = null; this.opts.onSay?.('mew'); return; }
    if (this.pokes % 3 === 0) this.celebrate(now); else this.perk(now, 2.4);
  }

  setHover(on: boolean): void {
    this.hovering = on;
    kick();
    // A pointer right over a sleeper stirs it.
    if (on && this.phase === 'asleep') this.stir();
  }

  /** True if anything is on at the moment (a gesture, a reaction, the pointer's attention, a change between sleep and waking). */
  get busy(): boolean {
    return !!(this.running || this.reaction || this.curiousAmount > 0.02 || this.phase === 'waking' || this.stirAt !== null || this.lyingDown);
  }

  // MARK: Sleep

  /** Curled up (or going to be). */
  get asleep(): boolean { return this.phase === 'asleep'; }
  /** Asleep, or waking up: not yet itself. */
  get drowsy(): boolean { return this.phase !== 'awake'; }

  /** Runs `fn` once the cat is awake (at once if it is). A gesture asked of a sleeper waits for it this way. */
  whenAwake(fn: () => void): void { if (this.phase === 'awake') fn(); else this.afterWake.push(fn); }

  /** How far into its nap the cat is, in seconds (the age the app's nap routine is given). */
  private napAge(now: number): number { return this.napBase + (now - this.napFrom); }

  /** Still lying down: a cat that has only just begun to doze off is not yet curled up, and has nothing to stir. */
  private get lyingDown(): boolean { return this.phase === 'asleep' && this.napAge(performance.now() / 1000) < NAP_SETTLED; }

  /** A sleeper that notices something: it twitches as it does in a dream, a lid cracks open a little, and it settles back. */
  stir(now = performance.now() / 1000): void {
    if (this.phase !== 'asleep' || this.stirAt !== null || env.reduced || this.napAge(now) < NAP_SETTLED) return;
    this.stirAt = now; this.lastStir = now;
  }

  /**
   * Begins to wake: slowly, whatever woke it (an ear flicks, the eyes open and sink again, a stretch, a yawn, a slow blink, and it
   * sits up: the app's `waking`). The story wakes its own cat this way too (`story`). A cat that is not in sight, or that must not
   * move, just changes.
   */
  wake(cause: WakeCause | 'story' = 'touch', now = performance.now() / 1000): void {
    if (!this.sleeper || this.phase !== 'asleep') return;
    this.running = null; this.reaction = null; this.stirAt = null; this.dozePending = false; this.painted = null;
    this.wakeKind = cause === 'light' ? 'light' : 'touch';
    this.sleptAge = this.napAge(now);
    this.phase = 'waking'; this.phaseAt = now;
    kick();
    if (env.reduced) { this.holdStill(); return; }
    if (!this.visible || env.hidden) this.finishWake(now, false);
  }

  private finishWake(now: number, speak = true): void {
    window.clearTimeout(this.stillTimer);
    const kind = this.wakeKind;
    this.phase = 'awake'; this.stirAt = null; this.painted = null;
    this.nextAt = now + 2.5 + Math.random() * 3;
    if (env.reduced) this.holdStill();
    if (speak) this.opts.onSay?.(kind === 'light' ? 'light' : 'woke');
    this.afterWake.splice(0).forEach((fn) => fn());
  }

  /** Falls asleep after a long quiet (it finishes what it is doing first): a nap of the app's own, from the sit. */
  doze(now = performance.now() / 1000): void {
    if (!this.sleeper || this.phase !== 'awake' || this.driver) return;
    if (this.running || this.reaction) { this.dozePending = true; return; }
    this.startDoze(now);
  }

  private startDoze(now: number): void {
    this.dozePending = false;
    this.painted = null;
    // Seen, it lies down and curls up (the nap begins at its beginning); unseen or still, it is simply found asleep.
    const seen = !env.reduced && this.visible && !env.hidden;
    this.phase = 'asleep'; this.napBase = seen ? 0 : A.BEDTIME_AGE; this.napFrom = now;
    if (env.reduced) { this.holdStill(); return; }
    if (seen) this.opts.onSay?.('sleepy');
  }

  /** What it shows when it must not move (Reduce Motion): a still pose for what it is doing. A wake is two stills in turn, never a movement. */
  holdStill(): void {
    window.clearTimeout(this.stillTimer);
    let pose: Pose;
    if (this.sleeper && this.phase === 'asleep') pose = A.asleepPose();
    else if (this.sleeper && this.phase === 'waking') {
      pose = A.wakeStill();
      this.stillTimer = window.setTimeout(() => this.finishWake(performance.now() / 1000), 1600);
    } else pose = this.opts.still ? this.opts.still() : A.staticPose({ working: this.working });
    this.freeze(pose);
  }

  /** Back to moving after a still frame. */
  release(): void {
    window.clearTimeout(this.stillTimer);
    if (this.phase === 'waking') this.finishWake(performance.now() / 1000, false);
    this.freeze(null);
  }

  /** Stops listening to the page's sleep. */
  detach(): void { this.off?.(); this.off = null; window.clearTimeout(this.stillTimer); }

  /**
   * What the sleeper looks like this frame, or null if it is awake: the app's nap at its age, or its waking. `life` is how much of
   * its small life is laid over it (the app's: none in the middle of a nap or a waking, fading out as a nap begins). Changes of
   * phase happen here, when their time comes.
   */
  private slumberLayer(now: number): { pose: Pose; life: number } | null {
    if (this.dozePending && !this.running && !this.reaction) this.startDoze(now);
    switch (this.phase) {
      case 'asleep': {
        const age = this.napAge(now);
        this.watchStir(now);
        if (this.stirAt !== null) {
          const u = now - this.stirAt;
          if (u < A.STIR_LENGTH) return { pose: A.stirred(u, now, age), life: 0 };
          this.stirAt = null;
        }
        return { pose: A.asleepAt(age, now), life: 1 - A.ramp(age, 0, 0.8) };
      }
      case 'waking': {
        const light = this.wakeKind === 'light';
        const u = now - this.phaseAt;
        if (u >= A.wakeLength(light ? 1 : 0)) { this.finishWake(now); return null; }
        return { pose: A.waking(u, now, this.sleptAge, A.BEDTIME_NAP, light ? 1 : 0), life: 0 };
      }
      default: return null;
    }
  }

  /** A pointer that comes close to a sleeper (and moves) makes it stir; it does not stir again at once. */
  private watchStir(now: number): void {
    if (this.stirAt !== null || env.touch || env.reduced || now - this.lastStir < 7 || this.napAge(now) < NAP_SETTLED) return;
    const ptr: PointerLike | null = this.opts.pointerSource ? this.opts.pointerSource() : env.pointer;
    const rect = this.rect;
    if (!ptr || !ptr.seen || !rect || rect.width <= 0 || now - ptr.lastMove > 0.5) return;
    const dist = Math.hypot(ptr.x - (rect.left + rect.width / 2), ptr.y - (rect.top + rect.height * 0.6));
    if (dist < clamp(rect.width * 0.75, 70, 170)) this.stir(now);
  }

  // MARK: The clock

  private markActive(now: number): void {
    // Whatever the visitor does wakes a sleeping cat: it lifts its head first.
    if (this.running && (this.running.kind === 'nap' || this.running.kind === 'loaf') && this.running.release === null) {
      this.running.release = now;
      this.opts.onSay?.('wake');
    }
  }

  private measure(force = false): void {
    const now = performance.now();
    if (!force && now - this.rectAt < 120) return;
    this.rectAt = now;
    this.rect = this.svg.getBoundingClientRect();
    const w = this.rect.width;
    if (w > 0) this.unit = w / 44;
  }

  /** Chooses the next gesture, or none. */
  private choose(): GestureKind | null {
    const idle = env.idleFor();
    const allowed = this.opts.gestures ?? GESTURES;
    const nap = idle >= napThreshold(this.personality, env.dayPart) && !this.working;
    // A cat with a single thing to do (the peeking one) does it again and again.
    const pool = allowed.length === 1 ? allowed : allowed.filter((k) => k !== this.lastKind);
    const options = pool
      .map((k) => {
        if (this.working) return [k, 0] as const;
        if (k === 'nap') return [k, nap ? BASE_WEIGHT.nap * bias(k, this.personality, env.dayPart) : 0] as const;
        if (k === 'peek') return [k, this.opts.ledge !== undefined ? BASE_WEIGHT.peek * bias(k, this.personality, env.dayPart) : 0] as const;
        return [k, BASE_WEIGHT[k] * bias(k, this.personality, env.dayPart)] as const;
      })
      .filter(([, w]) => w > 0);
    const total = options.reduce((s, [, w]) => s + w, 0);
    if (total <= 0) return null;
    let r = Math.random() * total;
    for (const [k, w] of options) { if (r < w) return k; r -= w; }
    return options[options.length - 1]?.[0] ?? null;
  }

  private gap(): number {
    const activity = this.opts.activity ?? 1;
    const base = 6 + Math.random() * 8;
    return base * pauseScale(this.personality) / Math.max(0.25, activity);
  }

  // MARK: Frame

  /** Computes the pose for this moment (seconds on the page's clock). */
  pose(now: number, dt: number): Pose {
    const alert = this.working ? 1 : 0;
    // In the night hours a cat that sleeps with the page carries itself the way the app's sleepy cat does (half-lidded, ears a little
    // back, the tail low), unless the visitor chose who it is.
    const drowsy = this.sleeper && this.nightLook && this.personality === 'curious' && isNight(env.hour);
    const tm = temperamentOf(drowsy ? 'sleepy' : this.personality, env.dayPart);
    let base: Pose;
    let life = 1;

    const driven = this.driver?.(now, dt);
    // Asleep, waking or dozing, the sleeper's own poses are all there is: no gestures, no pointer, no small life over them.
    const sleeping = !driven && this.sleeper ? this.slumberLayer(now) : null;
    if (sleeping) {
      const asleep = clonePose(sleeping.pose);
      if (sleeping.life > 0.02) applyLife(asleep, { time: now, temperament: tm, restful: sleeping.life, quiet: 1, rate: 1, alert });
      this.secondary.apply(asleep, dt, this.unit);
      return asleep;
    }
    if (driven) {
      base = driven.pose;
      life = driven.life ?? (base.action === 'sit' ? 1 : 0.25);
    } else {
      base = A.sit(now, alert);
      // The gesture over the idle sit.
      if (this.running) {
        const r = this.running;
        const u = now - r.start;
        const releasing = r.release !== null;
        const weight = releasing ? 1 - A.ramp(now - (r.release as number), 0, r.kind === 'nap' ? 0.9 : 0.45) : 1;
        if (u >= r.length || weight <= 0) {
          this.lastKind = r.kind;
          // A few gestures lead into another, as in the app.
          const follow = !releasing && u >= r.length ? this.followUp(r) : null;
          this.running = null;
          this.nextAt = now + (follow ? follow.delay : this.gap());
          if (follow) this.pendingFollow = follow;
        } else {
          const shift = 0;
          const g = A.perform(kindToAction(r.kind), u, r.length, now, { facing: r.facing, alert, shift, variant: r.variant });
          // The ledge is the lowest y that may show: a peek needs it.
          const gp = r.kind === 'peek' && this.opts.ledge !== undefined ? A.peek(u, now, this.opts.ledge) : g;
          const wide = r.kind === 'nap' || r.kind === 'loaf' || r.kind === 'stretch' || r.kind === 'hunt';
          // As in the app (`PetDirector.pose`): a nap or a lie-down that is let go of unwinds legs first, so the head comes up first.
          const order = releasing && (r.kind === 'nap' || r.kind === 'loaf') ? 'legsFirst' : 'headFirst';
          base = wide ? staged(base, gp, weight, order) : blend(base, gp, weight);
          if (r.kind === 'nap') base.zAlpha *= Math.pow(weight, releasing ? 12 : 4);
          // How much of its small life the gesture leaves it (`PetDirector.lifeWeight`): it fades out as the gesture takes the body and
          // back in as it ends, so the blinks and glances under way never jump in size; a nap takes all of it.
          const presence = weight * A.ramp(u, 0, 0.8) * (1 - A.ramp(u, r.length - 0.8, r.length));
          life = 1 - presence * (r.kind === 'nap' ? 1 : 0.65);
        }
      } else if (!this.reaction && !env.reduced && now >= this.nextAt && !this.frozen) {
        const pf = this.pendingFollow;
        if (pf) { this.pendingFollow = null; this.start(pf.kind, now); }
        else if ((this.opts.activity ?? 1) > 0 && this.curiousAmount < 0.05 && !this.working) {
          const k = this.choose();
          if (k) this.start(k, now); else this.nextAt = now + 3;
        } else this.nextAt = now + 2;
      }
    }

    // The reaction over everything.
    let reactionWeight = 0;
    if (this.reaction) {
      const rc = this.reaction;
      const u = now - rc.start;
      if (u >= rc.length) { this.reaction = null; this.nextAt = Math.max(this.nextAt, now + 2.5 + Math.random() * 3); }
      else {
        reactionWeight = A.ramp(u, 0, 0.14) * (1 - A.ramp(u, rc.length - 0.35, rc.length));
        let rp: Pose;
        switch (rc.kind) {
          case 'celebrate': rp = A.celebrate(u, now, this.opts.hop ?? 4, rc.style ?? 'hop'); reactionWeight = A.ramp(u, 0, 0.1) * (1 - A.ramp(u, rc.length - 0.3, rc.length)); break;
          case 'land': rp = A.land(u, now); reactionWeight = 1 - A.ramp(u, rc.length - 0.4, rc.length); break;
          case 'startle': rp = A.startle(u, now, rc.variant ?? 0); break;
          default: {
            const amount = A.ramp(u, 0, 0.25) * (1 - A.ramp(u, rc.length - 0.9, rc.length));
            rp = A.perked(base, now, amount, u);
            reactionWeight = 1;
          }
        }
        base = rc.kind === 'perk' ? rp : blend(base, rp, reactionWeight);
        life *= 1 - 0.7 * reactionWeight;
      }
    }

    const p = clonePose(base);

    // Where the pointer is, and what the cat makes of it.
    if (this.opts.pointer !== false && !env.reduced) this.attend(p, now, dt, life);
    // The page scrolling under it.
    if (this.opts.scroll !== false && !env.reduced) this.scrollGlance(p, dt, life);
    // A hand over it: pleased.
    this.hover += ((this.hovering && !env.reduced ? 1 : 0) - this.hover) * (1 - Math.exp(-dt * 7));
    if (this.hover > 0.01) {
      const h = this.hover * life;
      p.eyes *= 1 - 0.6 * h; p.earL += 0.08 * h; p.earR += 0.08 * h; p.tilt += -0.05 * h; p.head.y -= 0.35 * h;
      const slow = Math.max(0, Math.sin((now - 0) * 0.9));
      p.eyes *= 1 - 0.3 * slow * h;
    }

    // Its small life. However its layers add up (a glance of its own over the pointer's, over a perk), the painter keeps the face
    // together, as the app's does (`faceLayout` in render.ts): the eyes stay in the face and the mouth goes where the face turns.
    applyLife(p, { time: now, temperament: tm, restful: life, quiet: 1, rate: 1, alert });
    // Its follow-through, over whatever was made: the app's player lays it on last, too.
    if (this.opts.followThrough !== false) this.secondary.apply(p, dt, this.unit);
    return p;
  }

  private pendingFollow: { kind: GestureKind; delay: number } | null = null;

  private followUp(r: Running): { kind: GestureKind; delay: number } | null {
    const roll = Math.random();
    switch (r.kind) {
      case 'startle': return roll < 0.65 ? { kind: 'groom', delay: 0.8 + Math.random() * 0.8 } : null;
      case 'stretch': return roll < 0.35 ? { kind: 'yawn', delay: 0.4 + Math.random() * 0.5 } : null;
      case 'hunt': return r.variant === 1 ? (roll < 0.7 ? { kind: 'groom', delay: 0.9 + Math.random() * 0.7 } : null) : (roll < 0.3 ? { kind: 'glance', delay: 0.8 + Math.random() * 0.6 } : null);
      case 'groom': return roll < 0.15 ? { kind: 'glance', delay: 0.6 + Math.random() * 0.6 } : null;
      default: return null;
    }
  }

  /** Eyes and head follow the pointer; closer, the cat gets curious; left alone with it, it settles and slow-blinks. */
  private attend(p: Pose, now: number, dt: number, life: number): void {
    const rect = this.rect;
    const ptr: PointerLike | null = this.opts.pointerSource ? this.opts.pointerSource() : env.pointer;
    const live = !!ptr && ptr.seen && !!rect && rect.width > 0 && now - ptr.lastMove < 20 && !(env.touch && now - ptr.lastDown > 6);
    if (!rect || !ptr || !live) { this.near = false; this.curiousAmount += (0 - this.curiousAmount) * (1 - Math.exp(-dt * 3)); this.followAmount += (0 - this.followAmount) * (1 - Math.exp(-dt * 2)); return; }
    const cx = rect.left + rect.width / 2, cy = rect.top + rect.height * 0.45;
    const dx = ptr.x - cx, dy = ptr.y - cy;
    const dist = Math.hypot(dx, dy);
    const enter = Math.max(120, rect.width * 3.2), leave = enter * 1.35;
    const near = dist < (this.near ? leave : enter);
    if (near && !this.near) this.curiousSince = now;
    this.near = near;
    // A cat napping is not woken by a pointer that merely comes by (a move that is close, or a click, does).
    const resting = !!this.running && (this.running.kind === 'nap') && this.running.release === null;
    if (resting && near && dist < enter * 0.6 && now - ptr.lastMove < 0.4) this.markActive(now);
    const target = near && !resting ? 1 : 0;
    this.curiousAmount += (target - this.curiousAmount) * (1 - Math.exp(-dt * (target > this.curiousAmount ? 4.5 : 2.2)));
    const follow = (resting || this.running?.kind === 'loaf') ? 0 : 1;
    this.followAmount += (follow - this.followAmount) * (1 - Math.exp(-dt * 3));
    const scale = Math.max(90, rect.width * 2.2);
    const tx = clamp(dx / scale, -1, 1), ty = clamp(-dy / scale, -1, 1);
    this.gx += (tx - this.gx) * (1 - Math.exp(-dt * 7));
    this.gy += (ty - this.gy) * (1 - Math.exp(-dt * 7));
    const f = this.followAmount * (1 - this.curiousAmount * 0.6) * life;
    // Far away: the eyes go first and the head a little behind them.
    p.look.x += 1.25 * this.gx * f; p.look.y += 0.7 * this.gy * f;
    p.head.x += 0.5 * this.gx * f; p.head.y += 0.25 * Math.max(0, this.gy) * f;
    p.tilt += -0.045 * this.gx * f;
    if (this.curiousAmount > 0.01 && life > 0.2) {
      const q = A.curious(p, A.gaze(this.gx, this.gy), this.curiousAmount * Math.min(1, life * 1.4), now - this.curiousSince, true);
      Object.assign(p, q);
    }
  }

  private scrollGlance(p: Pose, dt: number, life: number): void {
    const v = env.scrollVelocity;
    const target = clamp(v / 1500, -1, 1);
    this.scrollLook += (target - this.scrollLook) * (1 - Math.exp(-dt * 5));
    const s = this.scrollLook * life;
    if (Math.abs(s) < 0.01) return;
    p.look.y += -0.9 * s; p.head.y += -0.35 * Math.abs(s) - 0.2 * s;
    const fast = clamp((Math.abs(v) - 1800) / 2600, 0, 1) * life;
    if (fast > 0) { p.earL += 0.2 * fast; p.earR += 0.2 * fast; p.eyes *= 1 + 0.1 * fast; }
  }

  // MARK: Painting

  private paintNow(pose: Pose): void {
    this.view.paint(pose, this.look);
    this.painted = clonePose(pose);
    this.paintedAt = performance.now();
  }

  /**
   * Whether the cat moves: a gesture, a reaction, the story's walk, or a picture that has just moved (the pointer it follows, a glance).
   * It is then drawn at the screen's own rate; one that only breathes, about twenty times a second.
   */
  moving(now: number): boolean { return this.busy || !!this.driver || now < this.fastUntil; }

  /** When it wants its next frame, on the page's clock (seconds): at once while it moves, a twentieth of a second later while it rests. */
  nextTickAt(now: number): number {
    if (this.frozen) return Infinity;
    return this.moving(now) || !this.lastTick ? now : this.lastTick + IDLE_TICK;
  }

  /** One frame. Returns true if something was painted. */
  tick(now: number): boolean {
    if (this.frozen) { if (!this.painted) this.paintNow(this.frozen); return false; }
    // A cat that is only breathing does not need a frame every refresh of the screen: about twenty a second is plenty.
    if (this.lastTick && now - this.lastTick < (this.moving(now) ? 0.006 : IDLE_TICK - 0.004)) return false;
    const dt = this.lastTick ? Math.min(0.1, now - this.lastTick) : 1 / 30;
    this.lastTick = now;
    this.lastNow = now;
    this.measure();
    const p = this.pose(now, dt);
    const ms = performance.now();
    const moved = this.painted ? distance(this.painted, p) * this.unit : Infinity;
    // A picture that moves by more than a fraction of a pixel from frame to frame keeps the screen's rate a moment longer.
    if (moved > 0.35) this.fastUntil = now + 0.15;
    // Paint when the picture would visibly change (the breathing alone changes a fraction of a pixel), and at least every 200 ms.
    if (!this.painted || moved > 0.14 || ms - this.paintedAt > 220) {
      this.paintNow(p);
      return true;
    }
    return false;
  }

  /** Forget timing after the cat was off screen, so a gesture does not start the instant it comes back. */
  resume(now: number): void {
    // Time did not pass for a cat nobody was looking at: a wake or a stir carries on from where it was.
    const gap = this.lastNow ? now - this.lastNow : 0;
    if (gap > 0.3) {
      this.phaseAt += gap; this.napFrom += gap;
      if (this.stirAt !== null) this.stirAt += gap;
    }
    // Resumed more than once for the same stretch (every cat on the loop hears the same event): count it once.
    this.lastNow = now;
    this.lastTick = 0;
    this.secondary.reset();
    if (this.nextAt < now + 1.2) this.nextAt = now + 1.2 + Math.random() * 2.5;
  }

  get daypart(): DayPart { return env.dayPart; }
}

function kindToAction(kind: GestureKind): import('./pose').Action {
  switch (kind) {
    case 'nap': return 'sleep';
    default: return kind as import('./pose').Action;
  }
}

// MARK: The loop

/** Seconds between the frames of a cat that only breathes. */
const IDLE_TICK = 0.045;

const actors = new Set<CatActor>();
let raf = 0;
let timer = 0;
let last = 0;

/**
 * One frame for every cat on screen. While one of them moves the loop runs at the screen's own rate; while they all only breathe it
 * sleeps on a timer until the next one is due, instead of being woken by every refresh of the screen for nothing.
 */
function frame(ts: number): void {
  raf = 0;
  const now = ts / 1000;
  let any = false, soonest = Infinity;
  const dt = last ? Math.min(0.1, now - last) : 1 / 30;
  last = now;
  env.sampleScroll(dt);
  for (const a of actors) {
    if (!a.visible) continue;
    any = true;
    a.tick(now);
    soonest = Math.min(soonest, a.nextTickAt(now));
  }
  if (!any || env.hidden || env.reduced) { last = 0; return; }
  const wait = soonest - now;
  if (wait <= 0.012) { raf = requestAnimationFrame(frame); return; }
  // Woken a little early, so the frame it then waits for is the one the cat is due on.
  timer = window.setTimeout(() => { timer = 0; raf = requestAnimationFrame(frame); }, Math.min(1000, (wait - 0.008) * 1000));
}

function kick(): void {
  if (raf || env.hidden || env.reduced) return;
  if (timer) { window.clearTimeout(timer); timer = 0; }
  raf = requestAnimationFrame(frame);
}

/** Registers a cat with the shared loop. It runs only while on screen. */
export function runCat(actor: CatActor, host: Element = actor.svg): () => void {
  actors.add(actor);
  // Reduced motion: one still frame per state, no loop.
  const still = () => {
    if (env.reduced) {
      actor.holdStill();
    } else {
      actor.release();
      actor.resume(performance.now() / 1000);
      kick();
    }
  };
  if (env.reduced) still();
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      const was = actor.visible;
      actor.visible = e.isIntersecting;
      if (actor.visible && !was) { actor.resume(performance.now() / 1000); kick(); }
    }
  }, { rootMargin: '80px' });
  io.observe(host);
  const offs = [env.on('motion', still), env.on('visibility', () => { if (!env.hidden) { actors.forEach((a) => a.resume(performance.now() / 1000)); kick(); } })];
  return () => { io.disconnect(); actors.delete(actor); actor.detach(); offs.forEach((o) => o()); };
}

/** The cats on the loop (a test hook; see the dev-only `__nookCat`). */
export const catActors = (): ReadonlySet<CatActor> => actors;
