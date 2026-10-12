/**
 * The cat's rig, ported from the app (`PetPose.swift`). Rig coordinates are "cat units": feet at y 0, centre at x 0,
 * about 31 units tall, y pointing up. A pose is plain numbers, so it can be blended, mirrored and thrown away freely.
 */

export type Action =
  | 'sit' | 'walk' | 'stretch' | 'play' | 'sleep' | 'wave' | 'groom' | 'glance' | 'peek' | 'celebrate' | 'land'
  | 'curious' | 'yawn' | 'loaf' | 'hunt' | 'scratch' | 'startle' | 'tailPlay' | 'sad';

export interface V2 { x: number; y: number }
export interface Oval { cx: number; cy: number; rx: number; ry: number; angle: number }
export interface Limb { hip: V2; knee: V2; foot: V2; width: number }
export interface Tail { p0: V2; c1: V2; c2: V2; p3: V2; width: number }
/** Far hind, far front, near hind, near front. */
export type Legs = [Limb, Limb, Limb, Limb];

export interface Pose {
  action: Action;
  facing: number;
  /** Sideways shift of the whole cat, in rig units. */
  x: number;
  haunch: Oval;
  chest: Oval;
  head: V2;
  headScale: number;
  tilt: number;
  earL: number;
  earR: number;
  eyes: number;
  look: V2;
  legs: Legs;
  tail: Tail;
  ball: V2;
  ballSize: number;
  zAlpha: number;
  zRise: number;
  /** Lifts (+) or lowers (-) the whole cat. */
  y: number;
  sparkle: number;
  mouth: number;
  mote: V2;
  moteSize: number;
  swing: number;
  /** Progress 0...1 of a tear running down the cheek from the left eye; 0 draws none (the sad cat's: the page never shows it). */
  tear: number;
  /** How wet the eyes look, 0...1: a small glint in each. */
  glisten: number;
}

export const v = (x: number, y: number): V2 => ({ x, y });
export const oval = (cx: number, cy: number, rx: number, ry: number, angle = 0): Oval => ({ cx, cy, rx, ry, angle });
export const limb = (hip: V2, knee: V2, foot: V2, width = 3.2): Limb => ({ hip, knee, foot, width });
/** A straight limb hanging from `hip` down to `foot`. */
export const straightLimb = (x: number, hip: number, foot: number, width = 3.2): Limb =>
  limb(v(x, hip), v(x, (hip + foot) / 2), v(x, foot), width);

/** The front-facing sit with nothing added: the character's home pose. */
export function basePose(): Pose {
  return {
    action: 'sit', facing: 1, x: 0,
    haunch: oval(0, 7.2, 9.6, 7.4), chest: oval(0, 13.5, 6.6, 8.5),
    head: v(0, 19.2), headScale: 1, tilt: 0, earL: 0, earR: 0, eyes: 1, look: v(0, 0),
    legs: [straightLimb(-6.2, 6, 3.5, 3), straightLimb(-3.6, 8, 1.3, 3.8), straightLimb(6.2, 6, 3.5, 3), straightLimb(3.6, 8, 1.3, 3.8)],
    tail: { p0: v(-5.5, 3.5), c1: v(-19, -2), c2: v(-19.5, 9), p3: v(-13, 12), width: 3.5 },
    ball: v(19, 3), ballSize: 0, zAlpha: 0, zRise: 0, y: 0, sparkle: 0, mouth: 0,
    mote: v(18, 18), moteSize: 0, swing: 0, tear: 0, glisten: 0,
  };
}

const cv = (a: V2): V2 => ({ x: a.x, y: a.y });
const co = (a: Oval): Oval => ({ ...a });
const cl = (a: Limb): Limb => ({ hip: cv(a.hip), knee: cv(a.knee), foot: cv(a.foot), width: a.width });

export function clonePose(p: Pose): Pose {
  return {
    ...p,
    haunch: co(p.haunch), chest: co(p.chest), head: cv(p.head), look: cv(p.look),
    legs: [cl(p.legs[0]), cl(p.legs[1]), cl(p.legs[2]), cl(p.legs[3])],
    tail: { p0: cv(p.tail.p0), c1: cv(p.tail.c1), c2: cv(p.tail.c2), p3: cv(p.tail.p3), width: p.tail.width },
    ball: cv(p.ball), mote: cv(p.mote),
  };
}

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const lv = (a: V2, b: V2, t: number): V2 => ({ x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t) });
const lo = (a: Oval, b: Oval, t: number): Oval => ({ cx: lerp(a.cx, b.cx, t), cy: lerp(a.cy, b.cy, t), rx: lerp(a.rx, b.rx, t), ry: lerp(a.ry, b.ry, t), angle: lerp(a.angle, b.angle, t) });
export const lerpLimb = (a: Limb, b: Limb, t: number): Limb => ({ hip: lv(a.hip, b.hip, t), knee: lv(a.knee, b.knee, t), foot: lv(a.foot, b.foot, t), width: lerp(a.width, b.width, t) });
export const lerpV = lv;

/** Blends `a` toward `b` by `t` (0...1). A speck or a ball that is not there has no place: one that fades in or out does it where it is. */
export function blend(a: Pose, b: Pose, tIn: number): Pose {
  const t = Math.min(1, Math.max(0, tIn));
  const r: Pose = {
    action: t >= 0.5 ? b.action : a.action,
    facing: t >= 0.5 ? b.facing : a.facing,
    x: lerp(a.x, b.x, t),
    haunch: lo(a.haunch, b.haunch, t), chest: lo(a.chest, b.chest, t),
    head: lv(a.head, b.head, t), headScale: lerp(a.headScale, b.headScale, t), tilt: lerp(a.tilt, b.tilt, t),
    earL: lerp(a.earL, b.earL, t), earR: lerp(a.earR, b.earR, t), eyes: lerp(a.eyes, b.eyes, t), look: lv(a.look, b.look, t),
    legs: [lerpLimb(a.legs[0], b.legs[0], t), lerpLimb(a.legs[1], b.legs[1], t), lerpLimb(a.legs[2], b.legs[2], t), lerpLimb(a.legs[3], b.legs[3], t)],
    tail: { p0: lv(a.tail.p0, b.tail.p0, t), c1: lv(a.tail.c1, b.tail.c1, t), c2: lv(a.tail.c2, b.tail.c2, t), p3: lv(a.tail.p3, b.tail.p3, t), width: lerp(a.tail.width, b.tail.width, t) },
    ball: lv(a.ball, b.ball, t), ballSize: lerp(a.ballSize, b.ballSize, t),
    zAlpha: lerp(a.zAlpha, b.zAlpha, t), zRise: lerp(a.zRise, b.zRise, t),
    y: lerp(a.y, b.y, t), sparkle: lerp(a.sparkle, b.sparkle, t), mouth: lerp(a.mouth, b.mouth, t),
    mote: lv(a.mote, b.mote, t), moteSize: lerp(a.moteSize, b.moteSize, t), swing: lerp(a.swing, b.swing, t),
    tear: lerp(a.tear, b.tear, t), glisten: lerp(a.glisten, b.glisten, t),
  };
  if (a.moteSize === 0) r.mote = cv(b.mote); else if (b.moteSize === 0) r.mote = cv(a.mote);
  if (a.ballSize === 0) r.ball = cv(b.ball); else if (b.ballSize === 0) r.ball = cv(a.ball);
  return r;
}

/**
 * A tail swung toward `o` about its root (the app's `PetTail.swung`): each control point keeps its distance from the root (blended) and
 * turns the shorter way round, instead of sliding across to where it is in `o`. A slide takes a tail that goes from up to down through
 * a stub; a swing takes it the way a tail goes. Halfway it is `curl` shorter (it curls a little as it swings), which keeps a tail that
 * goes straight out behind the cat inside the room the cat has.
 */
export function swungTail(a: Tail, o: Tail, t: number, curl = 0.3): Tail {
  const root = v(a.p0.x + (o.p0.x - a.p0.x) * t, a.p0.y + (o.p0.y - a.p0.y) * t);
  const shorter = 1 - curl * Math.sin(t * Math.PI);
  const swing = (pa: V2, pb: V2): V2 => {
    const va = v(pa.x - a.p0.x, pa.y - a.p0.y), vb = v(pb.x - o.p0.x, pb.y - o.p0.y);
    const from = Math.atan2(va.y, va.x);
    let turn = Math.atan2(vb.y, vb.x) - from;
    if (turn > Math.PI) turn -= 2 * Math.PI; else if (turn < -Math.PI) turn += 2 * Math.PI;
    const la = Math.hypot(va.x, va.y), lb = Math.hypot(vb.x, vb.y);
    const radius = (la + (lb - la) * t) * shorter, angle = from + turn * t;
    return v(root.x + radius * Math.cos(angle), root.y + radius * Math.sin(angle));
  };
  return { p0: root, c1: swing(a.c1, o.c1), c2: swing(a.c2, o.c2), p3: swing(a.p3, o.p3), width: a.width + (o.width - a.width) * t };
}

/** Poses are authored facing right; this mirrors them to face left. */
export function mirror(p: Pose): Pose {
  const r = clonePose(p);
  const m = (a: V2): V2 => ({ x: -a.x, y: a.y });
  r.facing = -p.facing;
  r.haunch.cx = -p.haunch.cx; r.haunch.angle = -p.haunch.angle;
  r.chest.cx = -p.chest.cx; r.chest.angle = -p.chest.angle;
  r.head = m(p.head); r.tilt = -p.tilt; r.earL = p.earR; r.earR = p.earL; r.look = m(p.look);
  r.legs = p.legs.map((l) => limb(m(l.hip), m(l.knee), m(l.foot), l.width)) as Legs;
  r.tail = { p0: m(p.tail.p0), c1: m(p.tail.c1), c2: m(p.tail.c2), p3: m(p.tail.p3), width: p.tail.width };
  if (p.ballSize > 0) r.ball = m(p.ball);
  if (p.moteSize > 0) r.mote = m(p.mote);
  r.swing = -p.swing;
  return r;
}

export type Order = 'headFirst' | 'legsFirst';

const sm = (t: number) => { const c = Math.min(1, Math.max(0, t)); return c * c * (3 - 2 * c); };

/**
 * Blends toward `o` in stages so a turn reads as anticipation instead of a slide: the head and eyes lead, then the torso,
 * then legs and tail (`legsFirst` runs it backwards, as a walker settling into a sit).
 */
export function staged(a: Pose, o: Pose, tIn: number, order: Order = 'headFirst'): Pose {
  const t = Math.min(1, Math.max(0, tIn));
  const part = (lo_: number, hi: number) => sm((t - lo_) / (hi - lo_));
  const [head, body, legs, tail] = order === 'headFirst'
    ? [part(0, 0.5), part(0.1, 0.75), part(0.2, 0.9), part(0.1, 1)]
    : [part(0.5, 1), part(0.25, 0.9), part(0, 0.7), part(0, 1)];
  const r = blend(a, o, body);
  const h = blend(a, o, head), l = blend(a, o, legs), tl = blend(a, o, tail);
  r.head = h.head; r.headScale = h.headScale; r.tilt = h.tilt; r.earL = h.earL; r.earR = h.earR; r.eyes = h.eyes; r.look = h.look; r.mouth = h.mouth;
  r.legs = l.legs; r.tail = tl.tail;
  if (t >= 0.5) { r.action = o.action; r.facing = o.facing; } else { r.action = a.action; r.facing = a.facing; }
  return r;
}

/** Largest difference between two poses in rig units; used to skip frames that would paint the same picture. */
export function distance(a: Pose, b: Pose): number {
  let d = 0;
  const g = (p: V2, q: V2) => Math.max(Math.abs(p.x - q.x), Math.abs(p.y - q.y));
  const o = (p: Oval, q: Oval) => Math.max(Math.abs(p.cx - q.cx), Math.abs(p.cy - q.cy), Math.abs(p.rx - q.rx), Math.abs(p.ry - q.ry), Math.abs(p.angle - q.angle) * 8);
  const l = (p: Limb, q: Limb) => Math.max(g(p.hip, q.hip), g(p.knee, q.knee), g(p.foot, q.foot), Math.abs(p.width - q.width) * 0.5);
  d = Math.max(d, Math.abs(a.x - b.x), Math.abs(a.y - b.y), o(a.haunch, b.haunch), o(a.chest, b.chest), g(a.head, b.head), g(a.look, b.look));
  d = Math.max(d, Math.abs(a.headScale - b.headScale) * 9.3, Math.abs(a.tilt - b.tilt) * 9.3, Math.abs(a.earL - b.earL) * 8, Math.abs(a.earR - b.earR) * 8, Math.abs(a.eyes - b.eyes) * 1.6);
  for (let i = 0; i < 4; i++) d = Math.max(d, l(a.legs[i]!, b.legs[i]!));
  d = Math.max(d, g(a.tail.p0, b.tail.p0), g(a.tail.c1, b.tail.c1) * 0.5, g(a.tail.c2, b.tail.c2) * 0.5, g(a.tail.p3, b.tail.p3), Math.abs(a.tail.width - b.tail.width) * 0.5);
  if (a.ballSize > 0 || b.ballSize > 0) d = Math.max(d, Math.abs(a.ballSize - b.ballSize) * 2.3, a.ballSize > 0 && b.ballSize > 0 ? g(a.ball, b.ball) : 0);
  if (a.moteSize > 0 || b.moteSize > 0) d = Math.max(d, Math.abs(a.moteSize - b.moteSize) * 1.4, a.moteSize > 0 && b.moteSize > 0 ? g(a.mote, b.mote) : 0);
  d = Math.max(d, Math.abs(a.zAlpha - b.zAlpha) * 3, Math.abs(a.zRise - b.zRise) * 6, Math.abs(a.sparkle - b.sparkle) * 10, Math.abs(a.mouth - b.mouth) * 3.5, Math.abs(a.swing - b.swing) * 3);
  d = Math.max(d, Math.abs(a.tear - b.tear) * 5, Math.abs(a.glisten - b.glisten) * 1.5);
  return d;
}
