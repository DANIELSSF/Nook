/**
 * The cat's rigs and routines, ported from the app (`PetAnimation.swift`, `PetGestures.swift`, `PetBehaviors.swift`): pure
 * functions from a moment to a `Pose`. They know nothing about the DOM, the pointer or the page; the actor chooses what to do
 * and when, and the renderer draws the result.
 */
import {
  basePose, clonePose, v, oval, limb, lerpLimb, lerpV, blend, mirror, staged, swungTail, type Pose, type V2, type Action,
} from './pose';

// MARK: Helpers

export const smooth = (t: number): number => { const c = Math.min(1, Math.max(0, t)); return c * c * (3 - 2 * c); };
/** 0 before `a`, 1 after `b`, smooth in between. */
export const ramp = (t: number, a: number, b: number): number => smooth((t - a) / (b - a));
/** Rises over `[0, a]`, holds, and falls over `[b, 1]`. */
export const hold = (u: number, a: number, b: number): number => ramp(u, 0, a) * (1 - ramp(u, b, 1));
/** A smooth bump: 0 until `a`, up to 1 at the middle of `a...b`, back to 0 at `b`. */
export const bump = (t: number, a: number, b: number): number => {
  if (!(t > a && t < b)) return 0;
  const s = Math.sin(((t - a) / (b - a)) * Math.PI);
  return s * s;
};
/** A ring-down: a sine at `hz` that dies away at `decay` a second, starting at `t0`. */
export const ringing = (t: number, t0: number, hz: number, decay: number): number => {
  if (t <= t0) return 0;
  const u = t - t0;
  return Math.sin(2 * Math.PI * hz * u) * Math.exp(-decay * u);
};

/**
 * Deterministic noise in 0..<1: the app's own hash (`PetAnimation.hash`, a 64-bit splitmix finalizer), so that anything the cat
 * does at random happens here at the very moment it does in the app. The slot a moment falls in changes rarely and the frames ask
 * for the same one again and again, so the last answer for each salt is kept.
 */
const hashed = new Map<number, { n: number; value: number }>();
export function hash(n: number, salt = 0): number {
  const slot = Number.isFinite(n) ? Math.trunc(n) : 0, key = Number.isFinite(salt) ? Math.trunc(salt) : 0;
  const kept = hashed.get(key);
  if (kept && kept.n === slot) return kept.value;
  const u64 = (x: bigint) => BigInt.asUintN(64, x);
  let z = u64(BigInt(slot) * 0x9e3779b1n + BigInt(key) * 0x85ebca6bn + 0x9e3779b97f4a7c15n);
  z = u64((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n);
  z = u64((z ^ (z >> 27n)) * 0x94d049bb133111ebn);
  z ^= z >> 31n;
  const value = Number(z >> 11n) / 2 ** 53;
  hashed.set(key, { n: slot, value });
  return value;
}

/** Progress 0...1 of a once-per-period event of the given length at a hashed offset, null otherwise. */
export function event(t: number, period: number, length: number, salt: number): number | null {
  const n = Math.floor(t / period);
  const local = t - n * period;
  const start = hash(n, salt) * (period - length);
  if (local >= start && local < start + length) return (local - start) / length;
  return null;
}

/**
 * How closed the lids are at `t`, 0...1, with the blinks of the slots of `period` seconds: asymmetric (down in a third of the time it
 * takes to come up) and sometimes doubled (the app's `PetLife.blinkClosure`).
 */
export function blinkClosure(t: number, period: number, length: number, salt: number): number {
  const shape = (u: number) => (u < 0.34 ? ramp(u, 0, 0.34) : 1 - ramp(u, 0.34, 1));
  let closed = 0;
  const u = event(t, period, length, salt);
  if (u !== null) closed = shape(u);
  // The second of a double blink follows the first by a heartbeat, in one slot in five.
  const echo = t - (length + 0.13);
  if (hash(Math.floor(echo / period), salt + 5) < 0.2) {
    const e = event(echo, period, length, salt);
    if (e !== null) closed = Math.max(closed, shape(e));
  }
  return closed;
}

/** Piecewise smooth interpolation through `(time, value)` keys, easing in and out of each one. */
export function keyframe(u: number, keys: [number, number][]): number {
  const first = keys[0];
  if (!first) return 0;
  if (u <= first[0]) return first[1];
  for (let i = 1; i < keys.length; i++) {
    const b = keys[i]!;
    if (u <= b[0]) {
      const a = keys[i - 1]!;
      return a[1] + (b[1] - a[1]) * smooth((u - a[0]) / (b[0] - a[0]));
    }
  }
  return keys[keys.length - 1]![1];
}

const labelled = (p: Pose, action: Action): Pose => { const r = p; r.action = p.action === 'sit' ? 'sit' : action; return r; };

// MARK: Rigs (authored facing right)

/**
 * Front-facing sit, the character's home pose: it breathes and its tail drifts, and nothing else. `alert` is the on-duty
 * posture while the terminal works: eyes a little wider, ears forward.
 */
export function sit(t: number, alert = 0): Pose {
  const p = basePose();
  const breath = Math.sin(t * 1.7) * 0.25;
  p.chest.ry += breath; p.head.y += breath * 0.6;
  const sway = Math.sin(t * 1.1);
  p.tail.p3.x += sway * 0.55; p.tail.p3.y += sway * 0.4; p.tail.c2.y += Math.sin(t * 1.1 + 1) * 0.5;
  if (alert > 0) { p.eyes *= 1 + 0.12 * alert; p.earL -= 0.1 * alert; p.earR -= 0.1 * alert; }
  return p;
}

/** Half the foot travel of a stride, in rig units. */
export const HALF_STRIDE = 5;

/**
 * One foot at gait angle `ph`: how far it is along its stride (-1 back ... 1 forward) and how high it is lifted (0...1). A foot
 * is down for half the cycle and slides back along a straight line, so seen from the ground it stays still.
 */
export function gait(ph: number): { swing: number; lift: number } {
  let p = (ph - Math.PI / 2) / (2 * Math.PI);
  p -= Math.floor(p);
  if (p < 0.5) return { swing: 1 - 4 * p, lift: 0 };
  const s = (p - 0.5) * 2;
  return { swing: -1 + 2 * smooth(s), lift: Math.sin(s * Math.PI) };
}

/** Four-legged stand/walk. `phase` is the gait angle, `amp` scales the stride (0 stands still). */
export function walk(phase: number, amp: number, t: number): Pose {
  const p = basePose();
  p.action = 'walk';
  const bob = amp * Math.cos(2 * phase) * 0.45;
  p.haunch = oval(-6.6, 12.4 + bob, 7.6, 5.4); p.chest = oval(4.4, 12.9 + bob, 7.3, 5.8);
  p.head = v(12.4, 19.4 + bob * 1.4); p.headScale = 0.82;
  p.look = v(1.3, -0.2);
  // Hip x, gait phase offset (diagonal pairs move together), knee bend.
  const setup: [number, number, number][] = [[-9.6, 0, -1.8], [6.0, Math.PI, 1.2], [-6.8, Math.PI, -1.8], [8.6, 0, 1.2]];
  setup.forEach((s, i) => {
    const step = gait(phase + s[1]);
    const swing = amp * HALF_STRIDE * step.swing, lift = amp * 3.2 * step.lift;
    const hip = v(s[0], 8.4 + bob), foot = v(s[0] + swing, lift);
    p.legs[i as 0 | 1 | 2 | 3] = limb(hip, v((hip.x + foot.x) / 2 + s[2] * (1 + lift / 4), (hip.y + foot.y) / 2), foot, 3.1);
  });
  const sway = Math.sin(t * 2.2);
  p.tail = { p0: v(-12.5, 14), c1: v(-18, 13), c2: v(-19.5 + sway, 19), p3: v(-16 + sway * 1.5, 25 + sway), width: 3.5 };
  return p;
}

/** Play-bow: chest down, rear up, front paws reaching out. */
export function bow(t: number): Pose {
  const p = walk(0, 0, t);
  p.action = 'stretch';
  const wiggle = Math.sin(t * 3);
  p.haunch = oval(-6.6, 14.6, 7.8, 6.4, -0.42);
  p.chest = oval(4.0, 9.3, 7.6, 5.0, -0.38);
  p.head = v(13.6, 7.6); p.headScale = 0.86;
  p.tilt = -0.12; p.eyes = 0.15; p.earL = 0.2; p.earR = 0.2; p.look = v(1.8, -0.2);
  const reach = 15.5 + 2 * Math.sin(t * 2);
  p.legs[1] = limb(v(6, 5.4), v(11, 1.6), v(reach, 1.3), 3.1);
  p.legs[3] = limb(v(8.6, 5.4), v(13, 1.6), v(reach + 2, 1.3), 3.1);
  p.legs[0] = limb(v(-9.6, 13.4), v(-11, 7), v(-9.1, 0.2), 3.1);
  p.legs[2] = limb(v(-6.8, 13.4), v(-8.2, 7), v(-6.3, 0.2), 3.1);
  p.tail = { p0: v(-12.8, 17), c1: v(-17, 18), c2: v(-16.5 + wiggle, 24), p3: v(-17.5 + 1.2 * wiggle, 27.5), width: 3.5 };
  return p;
}

/** The second half of a cat's stretch: standing, the back arched high, the head low, the tail hanging in a hook. */
export function arch(t: number, tremble = 0): Pose {
  const p = walk(0, 0, t);
  p.action = 'stretch';
  p.haunch = oval(-5.4, 15.4, 7.6, 5.6, 0.52);
  p.chest = oval(4.8, 15.0, 7.4, 5.6, -0.5);
  p.head = v(11.2, 13.0 + tremble * 0.25); p.headScale = 0.84;
  p.tilt = -0.34; p.eyes = 0.12; p.earL = 0.34; p.earR = 0.3; p.look = v(1.2, -0.8);
  p.legs[0] = limb(v(-8.6, 11.6), v(-9.4, 5.8), v(-9.2, 0.2), 3.1);
  p.legs[2] = limb(v(-5.8, 11.6), v(-6.4, 5.8), v(-6.0, 0.2), 3.1);
  p.legs[1] = limb(v(5.6, 11.4), v(6.6, 5.8), v(7.2, 0.2), 3.1);
  p.legs[3] = limb(v(8.0, 11.4), v(9.0, 5.8), v(9.4, 0.2), 3.1);
  p.tail = { p0: v(-10.8, 16.4), c1: v(-15.8, 15.2), c2: v(-17.6 + tremble * 0.6, 9.0), p3: v(-16.2, 3.8 + tremble * 0.5), width: 3.5 };
  return p;
}

/**
 * Lying down, seen from the side and facing right. `rest` 1 closes the eyes and tucks the head; `curl` 1 draws the whole cat in on
 * itself, the tail round the front of the face. `asleep` 1 slows the breathing right down.
 */
export function loaf(rest: number, curl: number, t: number, asleep = 0): Pose {
  const p = basePose();
  p.action = 'sleep';
  const breath = (Math.sin(t * 2.1) * (1 - asleep) + Math.sin(t * 0.95) * asleep) * (0.45 + 0.2 * curl);
  p.haunch = oval(-3.2 + 1.7 * curl, 5.0 + 0.4 * curl, 10.4 + 0.2 * curl, 5.2 + 0.4 * curl + breath * 0.6);
  p.chest = oval(4.8 + 0.8 * curl, 4.7 + 0.2 * curl, 8.2 - 0.2 * curl, 4.8 - 0.2 * curl + breath * 0.5);
  p.head = v(9.6 + 1.4 * curl, 7.4 - 1.4 * rest - 2.0 * curl + breath * 0.3); p.headScale = 0.86 - 0.02 * curl;
  p.tilt = -0.18 * rest - 0.32 * curl; p.eyes = 1 - rest; p.earL = 0.35 * rest + 0.1 * curl; p.earR = 0.25 * rest + 0.1 * curl; p.look = v(0.6, -0.2);
  p.legs = [
    { hip: v(-6, 3), knee: v(-6, 2.5), foot: v(-6, 2), width: 3 }, { hip: v(8, 3), knee: v(8, 2.4), foot: v(8, 1.8), width: 3 },
    { hip: v(-2, 3), knee: v(-2, 2.5), foot: v(-2, 2), width: 3 }, { hip: v(11, 3.5), knee: v(11, 2.65), foot: v(11, 1.8), width: 3 },
  ];
  const open = { p0: v(-11.5, 4.2), c1: v(-17.5, 1), c2: v(-19, 0.8), p3: v(-13.5, 0.5) };
  const wrapped = { p0: v(-11.5, 4.4), c1: v(-18.5, 0.6), c2: v(3.5, -0.9), p3: v(15.5, 2.0) };
  p.tail = { p0: lerpV(open.p0, wrapped.p0, curl), c1: lerpV(open.c1, wrapped.c1, curl), c2: lerpV(open.c2, wrapped.c2, curl), p3: lerpV(open.p3, wrapped.p3, curl), width: 3.2 };
  return p;
}

/** Sitting and batting a bouncing ball with the near front paw. */
export function play(t: number, intensity: number, alert = 0): Pose {
  const p = sit(t, alert);
  p.action = 'play';
  const hop = Math.abs(Math.sin(t * 3.6));
  const swat = Math.max(0, Math.sin(t * 3.6 - 0.9));
  p.ball = v(18.5 + 0.8 * Math.sin(t * 1.8), 2.2 + 8.5 * hop * intensity); p.ballSize = intensity;
  p.look.x += 1.6 * intensity; p.look.y += (0.9 - 1.5 * hop) * intensity; p.tilt += -0.08 * intensity + 0.06 * swat * intensity;
  p.legs[3] = lerpLimb(p.legs[3], limb(v(4.2, 9.5), v(10 + 2 * swat, 8), v(9.5 + 4 * swat, 8.3 + 5 * swat), 3.4), intensity);
  p.chest.cx += 0.8 * intensity; p.head.x += 0.8 * intensity;
  const wag = Math.sin(t * 7.5) * intensity;
  p.tail.p3.y += 2 * wag; p.tail.p3.x += 1.5 * wag; p.tail.c2.y += 2.5 * wag;
  return p;
}

/** Sitting with one paw raised, waving. */
export function wave(t: number, amount: number, alert = 0): Pose {
  const p = sit(t, alert);
  p.action = 'wave';
  const w = Math.sin(t * 8);
  p.legs[3] = lerpLimb(p.legs[3], limb(v(4.2, 11), v(9 + 0.5 * w, 16), v(10.5 + 1.8 * w, 21), 3.4), amount);
  p.tilt += -0.1 * amount; p.eyes = Math.min(p.eyes, 1 - 0.25 * amount);
  return p;
}

/** Held by the scruff for the drag ghost: legs dangling, eyes wide. */
export function lifted(t: number): Pose {
  const p = sit(t);
  const sway = Math.sin(t * 3);
  p.haunch = oval(0, 9.5, 8.6, 7.8); p.chest = oval(0, 15.5, 6.2, 8.2);
  p.head = v(0, 21.4); p.eyes = 1.18; p.earL = 0.12; p.earR = 0.12; p.look = v(0, -0.5);
  p.legs = [
    limb(v(-5, 6), v(-5.5 + sway * 0.5, 2), v(-5.4 + sway, -1.6), 3), limb(v(-3.4, 9), v(-3.8, 4), v(-3.4 - sway, -1.2), 3.4),
    limb(v(5, 6), v(5.5 + sway * 0.5, 2), v(5.4 + sway, -1.6), 3), limb(v(3.4, 9), v(3.8, 4), v(3.4 - sway, -1.2), 3.4),
  ];
  p.tail = { p0: v(-4, 4), c1: v(-9, -2), c2: v(-12 + sway * 2, -4), p3: v(-10 + sway * 3, -9), width: 3.5 };
  return p;
}

// MARK: Gestures

/** Crouch and landing compression: the body sinks onto its feet and widens a little, the head dips and the ears fold back. */
export function squash(p: Pose, c: number, ears = 0.18): Pose {
  const r = clonePose(p);
  r.haunch.ry -= 1.4 * c; r.haunch.cy -= 1.4 * c; r.haunch.rx += 0.6 * c;
  r.chest.ry -= 1.0 * c; r.chest.cy -= 2.0 * c;
  r.head.y -= 2.7 * c;
  r.earL += ears * c; r.earR += ears * c;
  r.tail.p3.y -= 1.6 * c; r.tail.c2.y -= 1.0 * c;
  r.legs[1].foot.x -= 0.4 * c; r.legs[3].foot.x += 0.4 * c;
  return r;
}

export interface Gaze { dx: number; dy: number }
export const gaze = (dx = 0, dy = 0): Gaze => {
  const tame = (n: number) => (Number.isFinite(n) ? Math.min(1, Math.max(-1, n)) : 0);
  return { dx: tame(dx), dy: tame(dy) };
};

/** How long the pointer has to linger before the first slow blink, and how often it comes after that. */
export const SLOW_BLINK_AFTER = 2.6, SLOW_BLINK_EVERY = 8.0;

/**
 * The cat noticing the pointer: it looks at it, tips its head a little and sniffs. Only the head, eyes and ears move, within
 * small fixed limits. Left alone with the pointer for a while it settles, and now and then gives the slow blink cats keep for
 * those they trust.
 */
export function curious(base: Pose, g: Gaze, amount: number, age: number, sniff = true): Pose {
  if (amount <= 0) return base;
  const p = clonePose(base);
  p.action = 'curious';
  let lean = g.dx;
  if (Math.abs(lean) < 0.35) lean = lean < 0 ? -0.35 : 0.35;
  p.look.x = base.look.x + 2.0 * g.dx; p.look.y = base.look.y + 1.1 * g.dy;
  p.head.x += 1.3 * g.dx; p.head.y += 0.7 * Math.max(0, g.dy);
  p.tilt = base.tilt - 0.14 * lean;
  p.earL -= 0.16 + (g.dx < 0 ? 0.2 * -g.dx : 0); p.earR -= 0.16 + (g.dx > 0 ? 0.2 * g.dx : 0);
  p.eyes *= 1.12; p.headScale *= 1.02;
  if (sniff) {
    // Three quick pulses of the nose: the head lifts and nudges forward, the eyes narrow a touch.
    const q = (age - 0.3) / 0.2;
    if (q >= 0 && q < 3) {
      const pulse = Math.sin((q - Math.floor(q)) * Math.PI);
      p.head.y += 1.0 * pulse; p.head.x += 0.5 * pulse * (lean >= 0 ? 1 : -1);
      p.headScale += 0.02 * pulse; p.eyes *= 1 - 0.25 * pulse;
      p.earL -= 0.04 * pulse; p.earR -= 0.04 * pulse;
    }
    // The slow blink: the lids come down over half a second, rest, and rise again, every eight seconds or so.
    const slow = age - SLOW_BLINK_AFTER;
    if (slow > 0) {
      const local = slow % SLOW_BLINK_EVERY;
      p.eyes *= 1 - 0.92 * ramp(local, 0, 0.55) * (1 - ramp(local, 0.8, 1.45));
    }
  }
  return blend(base, p, amount);
}

export const GROOM_LENGTH = 2.7;

/**
 * Sitting, the cat lifts the near front paw to its mouth, licks it and wipes its face twice, eyes half closed and head tipped
 * toward the paw. Variant 1 washes its chest instead: the head dips down to it and bobs with each lick.
 */
export function groom(u: number, t: number, alert = 0, variant = 0): Pose {
  const d = GROOM_LENGTH;
  const p = sit(t, alert);
  p.action = 'groom';
  const raise = ramp(u, 0, 0.5) * (1 - ramp(u, d - 0.55, d));
  if (variant === 1) {
    const dip = ramp(u, 0, 0.55) * (1 - ramp(u, d - 0.6, d));
    const lick = u >= 0.7 && u < d - 0.6 ? Math.sin(((u - 0.7) / 0.43) * 2 * Math.PI) : 0;
    p.head.y -= 3.4 * dip + 0.55 * Math.max(0, lick) * dip; p.head.x += 0.5 * dip;
    p.tilt += 0.07 * dip + 0.05 * lick * dip;
    p.eyes = Math.min(p.eyes, 1 - 0.88 * dip);
    p.earL += 0.12 * dip; p.earR += 0.12 * dip;
    p.chest.ry -= 0.5 * dip; p.chest.cy -= 0.5 * dip;
    p.headScale -= 0.02 * dip;
    return p;
  }
  const lick = u >= 0.5 && u < 1.05 ? Math.sin(((u - 0.5) / 0.55) * 2 * Math.PI * 2) : 0;
  const w = (u - 1.05) / 0.55;
  const wipe = w >= 0 && w < 2 ? (1 - Math.cos(w * 2 * Math.PI)) / 2 : 0;
  const mouth = limb(v(4.6, 11.4), v(9.4, 12.6), v(3.6, 15.8), 3.4);
  const arm = lerpLimb(p.legs[3], mouth, raise);
  arm.foot.x += 6.0 * wipe * raise; arm.foot.y += 6.2 * wipe * raise;
  arm.knee.x += 1.4 * wipe * raise; arm.knee.y += 2.2 * wipe * raise;
  arm.foot.y += 0.35 * lick * raise;
  p.legs[3] = arm;
  p.tilt += -0.13 * raise - 0.04 * wipe * raise;
  p.head.x += 0.7 * raise; p.head.y += -0.55 * raise - 0.35 * Math.max(0, lick) * raise;
  p.eyes = Math.min(p.eyes, 1 - 0.8 * raise);
  p.earL += 0.1 * raise; p.earR += 0.2 * raise;
  p.chest.cx += 0.3 * raise;
  return p;
}

export const GLANCE_LENGTH = 3.4;

/**
 * A quiet look from the sit; only the face moves. Variant 0 looks round, to one side and then the other; 1 and 2 listen to
 * something off to the right or the left; 3 follows something small across the sky.
 */
export function glance(u: number, t: number, alert = 0, variant = 0): Pose {
  const p = sit(t, alert);
  p.action = 'glance';
  switch (variant) {
    case 1:
    case 2: {
      const dir = variant === 1 ? 1 : -1;
      const h = hold(u / GLANCE_LENGTH, 0.14, 0.7);
      const ears = ramp(u, 0, 0.3) * (1 - ramp(u, 2.4, 3.0));
      p.look.x += 1.7 * dir * ramp(u, 0.05, 0.4) * (1 - ramp(u, 2.5, 3.1));
      p.head.x += 0.9 * dir * h; p.tilt += -0.1 * dir * h;
      if (dir > 0) { p.earR -= 0.4 * ears; p.earL += 0.12 * ears; } else { p.earL -= 0.4 * ears; p.earR += 0.12 * ears; }
      p.eyes *= 1 + 0.08 * ears;
      const flick = Math.sin(Math.max(0, Math.min(1, (u - 1.3) / 0.45)) * Math.PI * 2) * ears;
      if (dir > 0) p.earR -= 0.12 * flick; else p.earL -= 0.12 * flick;
      break;
    }
    case 3: {
      const h = ramp(u, 0, 0.5) * (1 - ramp(u, 2.7, GLANCE_LENGTH));
      const across = ramp(u, 0.5, 2.3) * 2 - 1;
      p.head.y += 1.2 * h; p.look.y += 1.0 * h; p.look.x += 1.7 * across * h;
      p.head.x += 0.8 * across * h; p.tilt += -0.1 * across * h;
      p.earL -= 0.2 * h; p.earR -= 0.2 * h; p.eyes *= 1 + 0.08 * h;
      break;
    }
    default: {
      const side = keyframe(u, [[0, 0], [0.45, 1], [1.4, 1], [1.95, -1], [2.9, -1], [GLANCE_LENGTH, 0]]);
      p.look.x += 1.9 * side; p.look.y += 0.2 * Math.abs(side);
      p.head.x += 0.9 * side;
      p.tilt += -0.08 * side;
      p.earR -= 0.14 * Math.max(0, side); p.earL -= 0.14 * Math.max(0, -side);
      p.eyes *= 1 + 0.06 * Math.abs(side);
    }
  }
  return p;
}

export const PEEK_LENGTH = 5.0;

/** Where the whole cat sits, in rig units, at each beat of a peek, for a ledge at `ledge` (the lowest visible y). */
export function peekHeights(ledge: number): { hidden: number; ears: number; face: number } {
  const head = basePose().head.y;
  return { hidden: ledge - head - 15, ears: ledge + 5 - head - 12.2, face: ledge + 4.6 - head };
}

/** The cat ducks behind the edge (`ledge`), then comes up: first the ears, then the face, with a paw hooked over the edge, looks around and slips back out. */
export function peek(u: number, t: number, ledge: number, shift = 3.5): Pose {
  const heights = peekHeights(ledge);
  const keys: [number, number][] = [[0, 0], [0.6, heights.hidden], [0.9, heights.hidden], [1.4, heights.ears], [2.1, heights.ears], [2.65, heights.face], [3.95, heights.face], [PEEK_LENGTH, 0]];
  const p = sit(t);
  p.action = 'peek';
  p.y = keyframe(u, keys);
  p.x = keyframe(u, [[0, 0], [0.6, shift], [4.3, shift], [PEEK_LENGTH, 0]]);
  const ducking = ramp(u, 0, 0.4) * (1 - ramp(u, 0.7, 1.1));
  const earsUp = ramp(u, 1.0, 1.4) * (1 - ramp(u, 4.0, 4.6));
  const face = ramp(u, 2.2, 2.7) * (1 - ramp(u, 3.7, 4.2));
  p.look.y += -1.0 * ducking;
  p.eyes *= 1 + 0.1 * earsUp;
  p.earL -= 0.1 * earsUp; p.earR -= 0.1 * earsUp;
  if (u > 1.5 && u < 2.0) { const k = Math.sin(((u - 1.5) / 0.5) * Math.PI * 3); p.earL -= 0.3 * k; p.earR += 0.15 * k; }
  const around = ramp(u, 2.7, 3.0) * (1 - ramp(u, 3.5, 3.9));
  const sweep = Math.sin(((u - 2.7) / 1.0) * Math.PI * 2);
  p.look.x += 1.8 * sweep * around; p.head.x += 1.0 * sweep * around; p.tilt += -0.1 * sweep * around;
  const paw = ramp(u, 2.8, 3.1) * (1 - ramp(u, 3.65, 3.95));
  const tap = u >= 3.1 && u < 3.7 ? Math.sin(((u - 3.1) / 0.3) * Math.PI) : 0;
  const edge = ledge - heights.face;
  const hook = limb(v(4.4, 11), v(8.8, edge + 1.5), v(10.6, edge + 3.4 + 1.5 * tap), 3.6);
  p.legs[3] = lerpLimb(p.legs[3], hook, paw * face);
  return p;
}

export type Cheer = 'hop' | 'doubleHop' | 'content';
export const CELEBRATE_LENGTH = 1.25;
export const cheerLength = (style: Cheer): number => (style === 'hop' ? CELEBRATE_LENGTH : style === 'doubleHop' ? 2.0 : 2.3);

/**
 * A finished task. The hop is one small jump: a little crouch, the jump with a cheer, a soft landing and a glint. The double hop is
 * two, the second higher. The content cheer stays put: it sits up tall, squints with pleasure, and its tail rises in a slow curl.
 */
export function celebrate(u: number, t: number, hop = 4, style: Cheer = 'hop'): Pose {
  switch (style) {
    case 'hop': return hopping(u, t, [[0, hop]], CELEBRATE_LENGTH);
    case 'doubleHop': return hopping(u, t, [[0, hop * 0.7], [0.85, hop * 1.15]], cheerLength('doubleHop'));
    default: {
      const p = sit(t);
      p.action = 'celebrate';
      const pleased = ramp(u, 0, 0.5) * (1 - ramp(u, 1.6, 2.3));
      p.head.y += 1.1 * pleased + 0.25 * Math.sin(u * 3.2) * pleased; p.chest.ry += 0.7 * pleased; p.headScale += 0.02 * pleased;
      p.eyes *= 1 - 0.74 * pleased;
      p.earL -= 0.16 * pleased; p.earR -= 0.16 * pleased;
      p.tilt += -0.07 * pleased;
      const curl = ramp(u, 0.1, 0.8) * (1 - ramp(u, 1.7, 2.3));
      p.tail.p3 = lerpV(p.tail.p3, v(-9.0 + 1.6 * Math.sin(u * 3.4), 25.5), curl);
      p.tail.c2 = lerpV(p.tail.c2, v(-17.5, 17.5), curl);
      p.sparkle = u > 0.5 && u < 1.7 ? (u - 0.5) / 1.2 : 0;
      return p;
    }
  }
}

function hopping(u: number, t: number, hops: [number, number][], end: number): Pose {
  let p = sit(t);
  p.action = 'celebrate';
  let squashing = 0, landed = 0, lift = 0, air = 0;
  for (const [start, height] of hops) {
    const local = u - start;
    const crouch = ramp(local, 0, 0.22) * (1 - ramp(local, 0.22, 0.31));
    const flight = (local - 0.30) / 0.46;
    const flying = flight > 0 && flight < 1 ? 4 * flight * (1 - flight) : 0;
    const landing = ramp(local, 0.74, 0.86) * (1 - ramp(local, 0.86, 1.12));
    squashing += crouch + 1.25 * landing; landed += landing; lift += height * flying; air = Math.max(air, flying);
  }
  const joy = ramp(u, 0.26, 0.4) * (1 - ramp(u, end - 0.3, end - 0.05));
  p = squash(p, Math.min(1.4, squashing), 0.18 + 0.1 * Math.min(1, landed));
  p.y = lift;
  p.chest.ry += 0.7 * air; p.head.y += 1.1 * air;
  p.eyes *= 1 - 0.78 * joy;
  p.earL -= 0.2 * joy; p.earR -= 0.2 * joy;
  p.tilt += -0.08 * joy;
  p.tail.p3.y += 5 * joy; p.tail.c2.y += 3 * joy; p.tail.p3.x += 1.2 * joy;
  p.legs[3] = lerpLimb(p.legs[3], limb(v(4.2, 11), v(8.4, 12.4), v(11.6, 17.2), 3.3), air);
  p.legs[1] = lerpLimb(p.legs[1], limb(v(-4.2, 11), v(-8.4, 12.4), v(-11.6, 17.2), 3.3), air);
  for (const i of [0, 2] as const) p.legs[i].foot.y -= 1.2 * air;
  const last = hops[hops.length - 1];
  const glint = (last ? last[0] : 0) + 0.4;
  p.sparkle = u > glint && u < end - 0.13 ? (u - glint) / (end - 0.13 - glint) : 0;
  return p;
}

export const LAND_LENGTH = 1.0;

/** Put down again after being carried: it drops from `drop` rig units up with its legs still dangling, lands in a soft squash, blinks and settles. */
export function land(u: number, t: number, drop = 9): Pose {
  const fall = 0.3;
  const s = Math.min(1, Math.max(0, u / fall));
  const air = lifted(t);
  air.tail = sit(t).tail;
  let p = blend(air, sit(t), ramp(u, 0.1, fall));
  p.action = 'land';
  p.y = drop * (1 - s * s);
  const impact = ramp(u, fall, fall + 0.1) * (1 - ramp(u, fall + 0.1, fall + 0.36));
  p = squash(p, 1.2 * impact, 0.26);
  if (u > fall && u < fall + 0.2) p.eyes *= 1 - 0.85 * Math.sin(((u - fall) / 0.2) * Math.PI);
  if (u > fall + 0.14 && u < fall + 0.42) p.y += 0.8 * Math.sin(((u - fall - 0.14) / 0.28) * Math.PI);
  return p;
}

export const YAWN_LENGTH = 3.6;

/** A deeper breath in, then the mouth opens wide as the head tips up and the eyes squeeze shut, a tremble at the top, the mouth closes, the head shakes once. */
export function yawn(u: number, t: number): Pose {
  const p = sit(t);
  p.action = 'yawn';
  const inhale = bump(u, 0, 0.95);
  const open = ramp(u, 0.55, 1.2) * (1 - ramp(u, 2.3, 2.95));
  const lids = ramp(u, 0.62, 1.1) * (1 - ramp(u, 2.55, 3.2));
  const tremble = open * Math.sin(u * 46) * ramp(u, 1.35, 1.7) * (1 - ramp(u, 2.1, 2.4));
  p.mouth = open * (0.95 + 0.05 * Math.sin(u * 5));
  p.head.y += 1.3 * open + 0.4 * inhale + 0.12 * tremble;
  p.headScale += 0.035 * open;
  p.eyes *= 1 - 0.94 * lids;
  p.earL += 0.28 * open; p.earR += 0.28 * open;
  p.chest.ry += 0.5 * inhale + 0.7 * open; p.chest.rx += 0.3 * open;
  p.tail.p3.y += 1.2 * open;
  p.tilt += 0.12 * ringing(u, 3.0, 3.2, 4.5);
  return p;
}

export const SCRATCH_LENGTH = 2.7;

/** Sitting, the cat tips its head toward the near hind leg, which comes up beside the ear and scratches it fast, eyes shut with pleasure. */
export function scratch(u: number, t: number): Pose {
  const p = sit(t);
  p.action = 'scratch';
  const d = SCRATCH_LENGTH;
  const up = ramp(u, 0, 0.55) * (1 - ramp(u, d - 0.95, d - 0.4));
  const stroke = ramp(u, 0.5, 0.75) * (1 - ramp(u, d - 1.2, d - 0.95));
  const s = Math.sin(u * 58);
  const target = limb(v(6.8, 5.4), v(14.6, 9.2), v(10.6 + 1.1 * s * stroke, 17.2 + 1.5 * s * stroke), 3.7);
  p.legs[2] = lerpLimb(p.legs[2], target, up);
  p.tilt += -0.3 * up + 0.025 * s * stroke;
  p.head.x += 1.5 * up; p.head.y -= 0.9 * up;
  p.eyes *= 1 - 0.8 * up;
  p.earR += 0.3 * up; p.earL -= 0.06 * up;
  p.chest.cx += -0.6 * up + 0.35 * s * stroke;
  p.haunch.cx += -0.5 * up;
  const shake = ringing(u, d - 0.9, 3.6, 4.0);
  p.tilt += 0.13 * shake; p.earL -= 0.18 * Math.max(0, shake); p.earR += 0.1 * shake;
  return p;
}

export const STARTLE_LENGTH = 2.9;

/** Something it cannot see makes a noise: a small jump, the eyes wide, the ears flat and the tail puffed; then it freezes looking toward it, relaxes, blinks, and shakes it off. */
export function startle(u: number, t: number, variant = 0): Pose {
  let p = sit(t);
  p.action = 'startle';
  const side = variant === 0 ? 1 : -1;
  const d = STARTLE_LENGTH;
  const flight = u / 0.34;
  const air = flight > 0 && flight < 1 ? 4 * flight * (1 - flight) : 0;
  const landing = ramp(u, 0.3, 0.42) * (1 - ramp(u, 0.42, 0.8));
  const alarm = ramp(u, 0, 0.1) * (1 - ramp(u, 1.2, 2.0));
  const freeze = ramp(u, 0.35, 0.7) * (1 - ramp(u, 1.7, 2.3));
  const puff = ramp(u, 0, 0.12) * (1 - ramp(u, 1.1, 2.5));
  p = squash(p, 0.9 * landing, 0.1);
  p.y = 2.7 * air;
  p.chest.ry += 0.9 * air; p.head.y += 0.8 * air;
  p.eyes *= 1 + 0.26 * alarm;
  const flat = ramp(u, 0, 0.1) * (1 - ramp(u, 0.3, 0.55));
  p.earL += 0.34 * flat; p.earR += 0.34 * flat;
  if (side > 0) { p.earR -= 0.38 * freeze; p.earL += 0.1 * freeze; } else { p.earL -= 0.38 * freeze; p.earR += 0.1 * freeze; }
  p.look.x += 1.9 * side * freeze; p.head.x += 1.0 * side * freeze; p.tilt += -0.1 * side * freeze;
  p.head.y += 0.9 * freeze;
  p.tail.width += 1.8 * puff;
  p.tail.p3.y += 4.2 * puff; p.tail.c2.y += 2.4 * puff; p.tail.p3.x += 1.6 * puff;
  p.eyes *= 1 - 0.9 * bump(u, 2.0, 2.6);
  p.tilt += 0.12 * ringing(u, d - 0.55, 3.4, 4.2);
  return p;
}

export const TAILPLAY_LENGTH = 3.6;

/** The tail comes round to the front of the feet; the cat looks down at it, its tip flicking, and swats at it twice; the tail whips back out of reach and the cat looks innocent. */
export function tailPlay(u: number, t: number): Pose {
  const p = sit(t);
  p.action = 'tailPlay';
  const d = TAILPLAY_LENGTH;
  const engage = ramp(u, 0, 1.0) * (1 - ramp(u, d - 1.1, d - 0.2));
  const flick = Math.sin(u * 13) * ramp(u, 1.0, 1.3) * (1 - ramp(u, 2.5, 2.9));
  const low = { p0: v(-5.5, 3.5), c1: v(-16, 1.5), c2: v(-17, 0.6), p3: v(-11, 0.8) };
  const front = { p0: v(-5.5, 3.5), c1: v(-15.5, 1.0), c2: v(3.0, -1.8), p3: v(11.6 + 0.9 * flick, 6.4 + 2.2 * flick) };
  const at = (a: typeof low, b: typeof low, k: number) => ({ p0: lerpV(a.p0, b.p0, k), c1: lerpV(a.c1, b.c1, k), c2: lerpV(a.c2, b.c2, k), p3: lerpV(a.p3, b.p3, k), width: 3.5 });
  const rest = p.tail;
  p.tail = engage < 0.5 ? at(rest, low, engage * 2) : at(low, front, (engage - 0.5) * 2);
  const look = ramp(u, 0.5, 1.2) * (1 - ramp(u, d - 1.2, d - 0.5));
  p.head.y -= 1.5 * look; p.look.x += 1.3 * look; p.look.y += -1.0 * look + 0.4 * flick * look;
  p.tilt += -0.08 * look; p.earL -= 0.14 * look; p.earR -= 0.14 * look; p.eyes *= 1 + 0.1 * look;
  for (const start of [1.45, 2.05]) {
    const local = (u - start) / 0.42;
    if (!(local > 0 && local < 1)) continue;
    const swat = Math.sin(local * Math.PI);
    const paw = limb(v(4.4, 7.6), v(9.2, 6.2), v(10.0 + 2.0 * swat, 3.0 + 3.0 * swat), 3.4);
    p.legs[3] = lerpLimb(p.legs[3], paw, swat);
    p.chest.cx += 0.5 * swat; p.head.x += 0.5 * swat;
  }
  p.eyes *= 1 - 0.85 * bump(u, d - 0.9, d - 0.15);
  return p;
}

/**
 * The whole stretch of a cat that has got up: `bowed` reaches the front legs forward with the rear up, `arched` arches the back high
 * (and `shiver` trembles at the top of it). Both 0 is the plain stand it starts from.
 */
export function stretching(t: number, bowed: number, arched: number, shiver = 0): Pose {
  return blend(blend(walk(0, 0, t), bow(t), bowed), arch(t, shiver), arched);
}

/** Lying down in a loaf, awake: it settles onto its belly, its eyes soften and slow-blink, an ear turns now and then, and in variant 1 it kneads the floor; then it gets up again. */
export function loafing(u: number, d: number, t: number, variant = 0, facing = 1): Pose {
  const base = sit(t);
  let target = loaf(0, 0, t);
  target.action = 'loaf';
  const settled = ramp(u, 1.5, 2.6) * (1 - ramp(u, d - 2.6, d - 1.6));
  target.eyes = 1 - 0.3 * settled;
  const blink = event(u, 6.5, 1.3, 31);
  if (blink !== null) target.eyes *= 1 - 0.92 * bump(blink, 0, 1) * settled;
  const flick = event(u, 8.0, 0.5, 33);
  if (flick !== null) target.earL -= 0.3 * Math.sin(Math.PI * flick) * settled;
  target.earL += 0.1 * settled; target.earR += 0.06 * settled;
  target.tail.p3.y += 0.9 * Math.sin(t * 1.3) * settled;
  const knead = variant === 1 ? ramp(u, 3.0, 3.9) * (1 - ramp(u, d - 4.6, d - 3.7)) : 0;
  if (knead > 0) {
    const beat = Math.sin(u * 5.8);
    const far = Math.max(0, beat), near = Math.max(0, -beat);
    target.legs[1] = lerpLimb(limb(v(8, 3.2), v(12.4, 3.2 + 0.4 * far), v(16.2 + 0.8 * far, 1.8 + 3.2 * far), 3), target.legs[1], 1 - knead);
    target.legs[3] = lerpLimb(limb(v(11, 3.5), v(14.6, 3.4 + 0.4 * near), v(18.2 + 0.8 * near, 1.8 + 3.2 * near), 3), target.legs[3], 1 - knead);
    target.head.y -= 0.45 * knead * (far + near);
    target.eyes *= 1 - 0.55 * knead;
  }
  if (facing < 0) target = mirror(target);
  return labelled(u < d / 2 ? staged(base, target, ramp(u, 0, 1.9)) : staged(target, base, ramp(u, d - 1.9, d), 'legsFirst'), 'loaf');
}

// MARK: Hunt

export const huntLength = (variant: number): number => (variant === 0 ? 9.4 : 9.8);

/** A cat flat on the ground with its rear in the air, all of it ready to spring. `w` rocks the rear from side to side before the pounce. */
export function crouch(t: number, w = 0): Pose {
  const p = walk(0, 0, t);
  p.action = 'hunt';
  p.haunch = oval(-4.8 + 1.0 * w, 10.2, 7.2, 5.3, -0.14);
  p.chest = oval(3.2, 7.2, 6.8, 4.4, -0.28);
  p.head = v(10.2, 8.8); p.headScale = 0.84; p.tilt = -0.06;
  p.eyes = 1.22; p.earL = -0.2; p.earR = -0.2; p.look = v(1.9, -0.3);
  p.legs[0] = limb(v(-7.4, 9.4), v(-4.6, 4.6), v(-7.6 + 0.7 * w, 0.5), 3.1);
  p.legs[2] = limb(v(-4.8, 9.4), v(-2.2, 4.8), v(-5.2 - 0.7 * w, 0.5), 3.1);
  p.legs[1] = limb(v(4.4, 7.0), v(7.4, 4.0), v(9.8, 0.6), 3.1);
  p.legs[3] = limb(v(6.6, 7.0), v(9.4, 4.0), v(12.0, 0.8), 3.1);
  p.tail = { p0: v(-9.6, 11.6), c1: v(-13.2, 10.8), c2: v(-13.8 + 1.4 * w, 9.2), p3: v(-12.6 + 2.0 * w, 7.4 + 1.2 * w), width: 3.5 };
  return p;
}

/** Where the speck is, `u` seconds into the hunt. */
export function mote(u: number, variant: number): { point: V2; size: number } {
  const appear = ramp(u, 0, 0.7);
  const fly = v(14.8 + 3.0 * Math.sin(u * 1.7 + 0.4), 21.5 + 5.0 * Math.sin(u * 2.3) + 2.6 * Math.sin(u * 0.9));
  const land_ = ramp(u, 3.5, 4.4);
  const rest = v(19.2 + 0.3 * Math.sin(u * 11) * land_, 2.5 + 0.3 * Math.sin(u * 13) * land_);
  let point = lerpV(fly, rest, land_);
  let size = appear;
  if (variant === 0) {
    size *= 1 - ramp(u, 7.0, 7.18);
  } else {
    const escape = ramp(u, 7.0, 7.7);
    point = lerpV(point, v(19.0, 19.0 + 2.0 * Math.sin(u * 8)), escape);
    size *= 1 - ramp(u, 7.5, 8.2);
  }
  return { point, size };
}

/** The whole hunt: it spots a speck, follows it with its eyes and head, drops into a crouch, wiggles, springs; the speck is caught or gets away; then it sits up again. */
export function hunt(u: number, d: number, t: number, variant = 0, facing = 1, shift = 0, lunge = 0): Pose {
  const base = sit(t);
  const m = mote(u, variant);
  const f = facing;
  const watch = clonePose(base);
  const seen = ramp(u, 0.3, 0.9);
  const dx = Math.min(1, Math.max(-1, (m.point.x - 3) / 14)), dy = Math.min(1, Math.max(-1, (m.point.y - 19) / 9));
  watch.look.x += 1.9 * dx * seen * f; watch.look.y += 1.0 * dy * seen;
  watch.head.x += 1.2 * dx * seen * f; watch.head.y += 0.9 * Math.max(0, dy) * seen;
  watch.tilt += -0.12 * dx * seen * f;
  watch.earL -= 0.2 * seen; watch.earR -= 0.2 * seen; watch.eyes *= 1 + 0.16 * seen;
  watch.tail.p3.y += 2.0 * Math.sin(u * 9) * seen * ramp(u, 1.5, 2.5);
  watch.tail.p3.x += 1.0 * Math.sin(u * 7) * seen * ramp(u, 1.5, 2.5);
  const wiggleAmount = ramp(u, 5.35, 5.75) * (1 - ramp(u, 6.45, 6.75));
  const w = Math.sin(u * 33) * wiggleAmount;
  let crouched = crouch(t, w);
  crouched.tail.p3.y += 0.9 * Math.sin(u * 8) * ramp(u, 4.4, 5);
  if (f < 0) crouched = mirror(crouched);
  let p = u < 8.2 ? staged(watch, crouched, ramp(u, 3.7, 4.9)) : staged(crouched, base, ramp(u, 8.2, d), 'legsFirst');
  const low = ramp(u, 3.7, 4.9) * (1 - ramp(u, 8.2, d));
  p.x += shift * low * f;
  const sink = ramp(u, 6.62, 6.86) * (1 - ramp(u, 6.86, 6.9));
  const flight = (u - 6.88) / 0.52;
  const airborne = flight > 0 && flight < 1 ? 4 * flight * (1 - flight) : 0;
  const reach = ramp(u, 6.88, 7.15) * (1 - ramp(u, 7.7, 8.4));
  const impact = ramp(u, 7.28, 7.38) * (1 - ramp(u, 7.38, 7.75));
  if (u > 6.5 && u < d) {
    p.haunch.cx -= 0.9 * sink * f; p.chest.cx -= 0.4 * sink * f; p.head.y -= 0.5 * sink;
    p.y += 3.4 * airborne - 0.6 * impact;
    p.x += lunge * f * ramp(u, 6.88, 7.3) * (1 - ramp(u, 8.0, 8.9));
    p.head.x += 1.4 * reach * f; p.head.y += 0.8 * airborne;
    p.legs[1].foot = lerpV(p.legs[1].foot, v(15.6 * f, 1.2 + 2.2 * airborne), reach);
    p.legs[1].knee = lerpV(p.legs[1].knee, v(11.0 * f, 3.8 + 1.5 * airborne), reach);
    p.legs[3].foot = lerpV(p.legs[3].foot, v(17.4 * f, 1.0 + 2.6 * airborne), reach);
    p.legs[3].knee = lerpV(p.legs[3].knee, v(12.6 * f, 3.8 + 1.5 * airborne), reach);
    p.legs[0].foot.x -= 2.2 * airborne * f; p.legs[2].foot.x -= 2.2 * airborne * f;
  }
  if (variant === 0) {
    const round = ramp(u, 7.7, 8.0) * (1 - ramp(u, 8.9, 9.2));
    p.look.x += 1.8 * Math.sin((u - 7.8) * 3.2) * round; p.head.x += 0.8 * Math.sin((u - 7.8) * 3.2) * round;
    p.eyes *= 1 - 0.85 * bump(u, 8.5, 9.1);
  } else {
    const follow = ramp(u, 7.0, 7.5) * (1 - ramp(u, 8.0, 8.5));
    p.look.y += 1.2 * follow; p.head.y += 1.3 * follow;
    const baffled = ramp(u, 8.3, 8.8) * (1 - ramp(u, 9.3, 9.7));
    p.tilt += -0.16 * baffled * f; p.look.x += -0.5 * baffled * f;
  }
  p.mote = v(m.point.x * f, m.point.y); p.moteSize = m.size;
  p.action = low > 0.5 ? 'hunt' : 'sit';
  return labelled(p, 'hunt');
}

// MARK: Routines

/** One in-place action, `u` seconds in; poses ease out of and back into the idle sit. */
export function perform(action: Action, u: number, d: number, t: number, opts: { facing?: number; alert?: number; shift?: number; variant?: number } = {}): Pose {
  const { facing: f = 1, alert = 0, shift = 0, variant = 0 } = opts;
  const base = sit(t, alert);
  const face = (p: Pose) => (f < 0 ? mirror(p) : p);
  switch (action) {
    case 'stretch': {
      const bowed = ramp(u, 0.8, 1.6) * (1 - ramp(u, d - 3.4, d - 2.5));
      const arched = ramp(u, d - 3.6, d - 2.8) * (1 - ramp(u, d - 1.9, d - 1.1));
      const shiver = arched * Math.sin(t * 38) * ramp(u, d - 3.0, d - 2.6);
      let target = stretching(t, bowed, arched, shiver);
      target.x = shift * Math.max(bowed, arched) * (f < 0 ? -1 : 1);
      target = face(target);
      return labelled(u < d / 2 ? staged(base, target, ramp(u, 0, 0.8)) : staged(target, base, ramp(u, d - 0.8, d), 'legsFirst'), 'stretch');
    }
    case 'sleep': {
      const rest = ramp(u, 1.6, 2.9) * (1 - ramp(u, d - 3.4, d - 2.2));
      const curl = ramp(u, 3.0, 4.7) * (1 - ramp(u, d - 4.3, d - 3.0));
      const asleep = rest * curl;
      let target = loaf(rest, curl, t, asleep);
      const dream = event(u, 9.5, 0.7, 77);
      if (dream !== null && asleep > 0.6) {
        const twitch = Math.sin(Math.PI * dream) * asleep;
        target.earR -= 0.32 * twitch; target.legs[3].foot.x += 0.9 * twitch; target.legs[3].foot.y += 0.5 * twitch; target.tail.p3.y += 1.3 * twitch;
      }
      target.zAlpha = ramp(u, 3.1, 4.1) * (1 - ramp(u, d - 3.0, d - 2.0)); target.zRise = (u * 0.3) % 1;
      target = face(target);
      return labelled(u < d / 2 ? staged(base, target, ramp(u, 0, 1.6)) : staged(target, base, ramp(u, d - 1.4, d), 'legsFirst'), 'sleep');
    }
    case 'play': {
      const i = ramp(u, 0.3, 1) * (1 - ramp(u, d - 1, d - 0.3));
      const p = play(t, i, alert); p.x = shift * i;
      return p;
    }
    case 'wave': return wave(t, ramp(u, 0.2, 0.7) * (1 - ramp(u, d - 0.7, d - 0.2)), alert);
    case 'groom': return groom(u, t, alert, variant);
    case 'glance': return glance(u, t, alert, variant);
    case 'yawn': return yawn(u, t);
    case 'scratch': return scratch(u, t);
    case 'startle': return startle(u, t, variant);
    case 'tailPlay': return tailPlay(u, t);
    case 'loaf': return loafing(u, d, t, variant, f);
    case 'hunt': return hunt(u, d, t, variant, f, shift, 0);
    default: return base;
  }
}

/**
 * The cat's reaction to an alert: sitting tall with the ears forward, eyes wide and the head turned toward the bell, tail
 * flicking for a moment (`age` is the seconds since it began). `base`, whatever the cat was doing, eases into it by `amount`.
 * It also mews once, a small mouth, as it looks.
 */
export function perked(base: Pose, t: number, amount: number, age: number): Pose {
  if (amount <= 0) return base;
  const p = sit(t);
  p.eyes *= 1.18;
  p.earL -= 0.26; p.earR -= 0.26;
  p.head.y += 1.2; p.headScale = 1.05; p.chest.ry += 0.7;
  p.look = v(1.8, -0.7); p.tilt = -0.11;
  const flick = Math.sin(age * 17) * Math.exp(-age * 2.2);
  p.tail.p3.y += 4 * flick; p.tail.p3.x += 1.6 * flick; p.tail.c2.y += 2.4 * flick;
  const mew = (age - 0.22) / 0.46;
  if (mew > 0 && mew < 1) { p.mouth = 0.5 * Math.sin(mew * Math.PI); p.head.y += 0.5 * p.mouth; }
  const start = clonePose(base);
  start.zAlpha *= 1 - Math.min(1, amount * 3);
  p.x = base.x;
  return blend(start, p, amount);
}

// MARK: Sleep and waking (the app's `PetWake.swift`, and the `.sleep` routine above)
//
// Nothing here is a pose of its own: a sleeping cat is `perform('sleep')` with a nap that never ends, the way the app puts a cat to
// bed, and waking chains the app's own poses (`loaf`, `bow`, `arch`, `sit`) with its own staging. Only the moments are the page's.

/** The seconds into a never-ending nap at which a cat put to bed is found: deep asleep (the app's `bedtimeAge`). */
export const BEDTIME_AGE = 8.0;
/** How long a nap that only a touch or the light ends lasts, in seconds: longer than any night. */
export const BEDTIME_NAP = 1e9;

/** The beats of a gentle waking, in seconds from the moment the cat is woken: the app's `PetWakeBeats`, about four seconds in all. */
export const WAKE = {
  /** With the light in its eyes the cat squints first, for this long: ears back, head tucked. */
  squintLead: 1.0,
  /** An ear flicks, and again. */
  earFlick: [0.04, 0.36],
  earFlickAgain: [0.38, 0.7],
  /** The z's of the dream are gone by this time. */
  zFade: 0.8,
  /** How open the eyes are, by time: a crack (0.55), a heavy lid sinking again (0.1), open (0.9), and wide. */
  eyes: [[0, 0], [0.3, 0], [0.95, 0.55], [1.2, 0.55], [1.6, 0.1], [2.0, 0.9], [2.6, 1]] as [number, number][],
  /** Lying, the head comes up a little. */
  lyingUp: [0.5, 1.4],
  /** The stretch: it rises into the bow (the front legs forward, the rear up), arches its back out of it, and comes back to a stand. */
  bow: [1.4, 2.2],
  arch: [2.4, 2.95],
  standUp: [2.95, 3.25],
  /** The yawn: the mouth opens as it rises into the bow and holds through the arch, and closes as it comes back to a stand. */
  yawnOpens: [2.0, 2.45],
  yawnCloses: [2.95, 3.3],
  /** Sitting back down (legs first, as the cat's own stretch ends), and the slow blink of a cat that has settled. */
  sitting: [3.05, 3.75],
  slowBlink: [3.45, 3.97],
  length: 4.0,
} as const;

/** How long the waking lasts: four seconds, and the second of squinting before it for a cat woken by the light (`squint` > 0). */
export const wakeLength = (squint = 0): number => WAKE.length + (squint > 0 ? WAKE.squintLead : 0);

/** A cat that is asleep, `age` seconds into a nap `length` long (the pose the app's director gives a napping cat), facing right. */
export const asleepAt = (age: number, t: number, length = BEDTIME_NAP): Pose => perform('sleep', age, length, t);

/**
 * The cat `raw` seconds after it was woken, from the nap it was in (`sleptAge` seconds into one `sleptLength` long) to the idle sit.
 * It does not sit up at once: an ear flicks twice, its eyes open slowly (a crack, a heavy lid sinking again, then open), its head
 * comes up and it stretches (front legs out and the rear up, then the back arched, as its own stretch does), yawns as it does, comes
 * back to a stand, sits down and, settled, blinks slowly. `squint` (0...1) is a cat woken by the light: it squints first for a second (ears flat, head tucked) and then wakes
 * the same way. Every beat begins where the one before ended: it begins at the nap's own pose and ends at the sit.
 */
export function waking(raw: number, t: number, sleptAge: number, sleptLength: number, squint = 0): Pose {
  const lead = squint > 0 ? WAKE.squintLead : 0;
  const u = raw - lead;
  const asleep = perform('sleep', sleptAge, sleptLength, t);
  const span = (r: readonly [number, number]): number => ramp(u, r[0], r[1]);

  // The glare: the cat flinches (the head lifts for a moment, an eye cracks open and shuts again), and tucks against it: ears back,
  // head down, eyes slits, the dream's z's gone. It holds that through the squint and lets go of it over the first second of waking.
  // Every number is within what the cat's own poses use (a nap's ears are 0.45).
  const glare = squint * (raw < lead ? ramp(raw, 0.08, 0.45) : 1 - ramp(u, 0, 0.9));
  const flinch = squint * bump(raw, 0, 0.36);
  const squinting = (p: Pose): Pose => {
    if (!(glare > 0 || flinch > 0)) return p;
    const q = clonePose(p);
    q.earL += 0.2 * glare; q.earR += 0.2 * glare;
    q.head.y += 0.8 * flinch - 0.5 * glare;
    q.tilt -= 0.05 * glare;
    q.eyes = Math.max(q.eyes * (1 - 0.5 * glare), 0.2 * glare) + 0.25 * flinch;
    q.zAlpha *= 1 - squint * ramp(raw, 0, 0.3);
    return q;
  };
  // The squint before the waking: the sleeper, scrunched against the light.
  if (u < 0) return squinting(asleep);

  const lying = loaf(0, 0, t);
  const seated = sit(t);
  // Lying: the head comes up a little. An ear flicks, and flicks again.
  let p = staged(asleep, lying, 0.55 * span(WAKE.lyingUp));
  p.earR -= 0.55 * bump(u, WAKE.earFlick[0], WAKE.earFlick[1]) + 0.4 * bump(u, WAKE.earFlickAgain[0], WAKE.earFlickAgain[1]);
  // The stretch, as the cat's own does it: the bow, the arch out of it, the stand it comes back to. It rises into the bow from lying,
  // and sits down from the stand (legs first).
  const archAmount = span(WAKE.arch), standAmount = span(WAKE.standUp);
  const shiver = archAmount * (1 - standAmount) * Math.sin(t * 38) * ramp(u, WAKE.arch[0] + 0.15, WAKE.arch[0] + 0.35);
  const up = bow(t), hooked = arch(t, shiver), standing = walk(0, 0, t);
  const stretch = blend(blend(up, hooked, archAmount), standing, standAmount);
  // The tail swings from up to hooked down and back up (a blend would slide its points across and fold it into a stub on the way).
  stretch.tail = swungTail(swungTail(up.tail, hooked.tail, archAmount), standing.tail, standAmount);
  const rise = span(WAKE.bow);
  if (rise > 0) {
    // Its parts rise together (the rear lifts as the front reaches out), and the tail lifts off the floor by swinging.
    const lyingTail = p.tail;
    p = blend(p, stretch, rise);
    p.tail = swungTail(lyingTail, stretch.tail, rise);
  }
  p = staged(p, seated, span(WAKE.sitting), 'legsFirst');
  // The yawn, through the stretch, with the amplitudes of the cat's own yawn (`yawn`): the mouth opens, the head tips up, the ears go
  // back and the eyes squeeze shut.
  const yawnAmount = span(WAKE.yawnOpens) * (1 - span(WAKE.yawnCloses));
  p.mouth = 0.97 * yawnAmount;
  p.head.y += 1.3 * yawnAmount; p.headScale += 0.035 * yawnAmount;
  p.earL += 0.28 * yawnAmount; p.earR += 0.28 * yawnAmount;
  // The eyes, in fits: they open and sink and open; squeezed shut by the yawn; and the slow blink at the end.
  let eyes = keyframe(u, WAKE.eyes);
  eyes *= 1 - 0.94 * yawnAmount;
  eyes *= 1 - 0.96 * bump(u, WAKE.slowBlink[0], WAKE.slowBlink[1]);
  p.eyes = asleep.eyes + (1 - asleep.eyes) * eyes;
  // The z's thin out at once.
  p.zAlpha = asleep.zAlpha * (1 - ramp(u, 0, WAKE.zFade));
  p.action = u < WAKE.bow[0] ? 'sleep' : 'stretch';
  if (u >= WAKE.length) return seated;
  return squinting(p);
}

/** The pose of a sleeping cat that is not allowed to move (Reduce Motion, the animations off): curled up, its eyes shut, a few z's. */
export function asleepPose(): Pose {
  const p = loaf(1, 1, 0, 1);
  p.zAlpha = 0.6; p.zRise = 0.35;
  return p;
}

/** The step between asleep and sitting when nothing may move: lying on its belly, awake, the eyes half open (the waking's own lying pose and its crack of an eye). */
export function wakeStill(): Pose {
  const p = loaf(0, 0, 0);
  p.eyes = WAKE.eyes[2]![1];
  return p;
}

/** How long a stir takes: a sleeper that notices something. */
export const STIR_LENGTH = 2.6;

/**
 * A sleeper that notices something (a pointer come close): it twitches as it does when it dreams (the same ear, paw and tail
 * the nap's dreams move), a lid cracks open a little and looks, and it settles back. `age` is how far into its nap it is; the
 * twitch, the lift of the head and the crack of the eyes are the app's own amounts.
 */
export function stirred(u: number, t: number, age: number): Pose {
  const p = asleepAt(age, t);
  const twitch = Math.sin(Math.PI * Math.min(1, u / 0.7)) * (u < 0.7 ? 1 : 0);
  p.earR -= 0.32 * twitch; p.legs[3].foot.x += 0.9 * twitch; p.legs[3].foot.y += 0.5 * twitch; p.tail.p3.y += 1.3 * twitch;
  const crack = ramp(u, 0.6, 1.2) * (1 - ramp(u, 1.8, 2.5));
  p.eyes = Math.max(p.eyes, 0.4 * crack);
  p.head.y += 1.4 * 0.4 * crack;
  return p;
}

// MARK: The sad cat (the app's `PetSad.swift`: the question before quitting)

/** The tear's schedule: the first wells up at `TEAR_FIRST` seconds, runs for `TEAR_LENGTH`, and a new one follows every `TEAR_EVERY`. */
export const TEAR_FIRST = 0.9, TEAR_LENGTH = 2.1, TEAR_EVERY = 6.4;
/** A slow blink every this many seconds (its lids come down over `SAD_BLINK_LENGTH`). */
export const SAD_BLINK_EVERY = 4.6, SAD_BLINK_LENGTH = 0.5;
/** How long the cat takes to droop when the scene begins. */
export const SAD_ENTRANCE = 0.85;
/**
 * How far the drooped cat reaches on its stage, in rig units: its limp tail runs well to the left of where the sitting cat's tail
 * curls, so the scene draws it shifted right by `SAD_SHIFT` and fits its width (`SAD_REACH`) to the stage.
 */
export const SAD_REACH = 33.6, SAD_SHIFT = 3.6;

/** How far the tear has run at `t` (0 before it wells and between tears). */
export function tearProgress(t: number): number {
  if (t < TEAR_FIRST) return 0;
  const local = (t - TEAR_FIRST) % TEAR_EVERY;
  return local < TEAR_LENGTH ? local / TEAR_LENGTH : 0;
}

/**
 * The sad cat `t` seconds into its scene, drooped by `amount` (0 is the idle sit, 1 is all the way down: the entrance eases it in,
 * head and ears first). A pure function of `t`, like the app's.
 */
export function sad(t: number, amount = 1): Pose {
  const base = sit(t);
  if (!(amount > 0)) return base;
  // It breathes slowly.
  const p = sit(t * 0.6);
  p.action = 'sad';
  // Slumped: the head hangs low and leans, the chest sinks a little and the haunch spreads under it.
  p.head.y -= 2.8; p.head.x += 0.3; p.headScale = 0.97; p.tilt = -0.12;
  p.chest.ry -= 0.7; p.chest.cy -= 1.0; p.haunch.rx += 0.5;
  // The ears fold out and down.
  p.earL = 0.6; p.earR = 0.6;
  // Heavy, wet eyes, looking down.
  p.eyes = 0.74; p.look = v(-0.25, -0.95); p.glisten = 1;
  // The tail lies limp along the ground, its tip just curling up.
  const sway = Math.sin(t * 0.8);
  p.tail = { p0: v(-5.5, 3.5), c1: v(-12.5, 2.4), c2: v(-17.4, 1.0 + 0.25 * sway), p3: v(-18.6 + 0.4 * sway, 1.9 + 0.5 * sway), width: 3.5 };

  // Its small life, which is slow: a long blink, a sigh now and then, an ear that lifts for a moment (hope) and falls again.
  p.eyes *= 1 - blinkClosure(t, SAD_BLINK_EVERY, SAD_BLINK_LENGTH, 311) * 0.92;
  const sigh = event(t, 7.5, 2.4, 301);
  if (sigh !== null) {
    const inhale = bump(sigh, 0, 0.55), out = ramp(sigh, 0.5, 0.72) * (1 - ramp(sigh, 0.86, 1));
    p.chest.ry += 0.9 * inhale; p.head.y += 0.45 * inhale - 0.7 * out;
    p.mouth = 0.15 * out;
  }
  const hope = event(t, 9.0, 0.9, 331);
  if (hope !== null) p.earR -= 0.3 * Math.sin(Math.PI * hope);
  p.tear = tearProgress(t);

  return staged(base, p, amount);
}

/** The sad cat's entrance: how far it has drooped `t` seconds after its scene began. */
export const sadAmount = (t: number, delay = 0.1): number => ramp(t, delay, delay + SAD_ENTRANCE);

/** What the cat shows when it must not move (Reduce Motion): a fixed pose for the state, instead of a movement. */
export function staticPose(opts: { working?: boolean; attention?: boolean; asleep?: boolean } = {}): Pose {
  if (opts.asleep) return asleepPose();
  if (opts.attention) return perked(basePose(), 0, 1, 10);
  if (opts.working) return sit(0, 1);
  return basePose();
}

export const DEG = 180 / Math.PI;
