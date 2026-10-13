/**
 * Draws a `Pose` as SVG, the way the app's `PetPainter` draws it with Core Graphics. The same `paint` function feeds two
 * sinks: a plain object while Astro renders the static markup at build time, and the live elements in the browser, so the
 * cat in the HTML and the cat on the screen are the same drawing.
 *
 * Rig space has y pointing up with the feet at 0, so the root group flips it (`translate(0 34) scale(1 -1)`).
 */
import { basePose, type Pose, type Limb, type Oval, type V2 } from './pose';

export type CoatId = 'snow' | 'cream' | 'silver' | 'tabby' | 'ginger';
export type AccessoryId = 'none' | 'collar' | 'bow' | 'glasses';
export interface Look { coat: CoatId; accessory: AccessoryId }
export const defaultLook: Look = { coat: 'snow', accessory: 'none' };

export const COATS: Record<CoatId, { fill: string; stripe: string | null }> = {
  snow: { fill: '#ffffff', stripe: null },
  cream: { fill: '#f7e6c2', stripe: null },
  silver: { fill: '#b8c4d6', stripe: null },
  tabby: { fill: '#d1ccc2', stripe: '#5c5754' },
  ginger: { fill: '#f5b06b', stripe: '#b86633' },
};
export const COAT_IDS = Object.keys(COATS) as CoatId[];
export const ACCESSORY_IDS: AccessoryId[] = ['none', 'collar', 'bow', 'glasses'];

/** The accessories' colours, as the painter has them. */
const COLLAR = '#52ba9c', BELL = '#f7cc61', BOW = '#d97857';
/** A tear and the glint in a wet eye: the same cool white-blue and white as the painter's. */
const TEAR = '#99d1ff', GLINT = '#fff';
/** A foot higher than this (rig units) is a paw raised to the face, drawn over the head. */
export const RAISED_ABOVE = 14.5;

/** The nominal box of the sitting cat, in rig units; the drawing may overflow it (hops, sparkles, z's). */
export const BOX = { w: 44, h: 36 };

type Sink = (part: string, attr: string, value: string) => void;

const r = (n: number): string => String(Math.round(n * 100) / 100);
const pt = (x: number, y: number): string => `${r(x)} ${r(y)}`;
const polyline = (...ps: { x: number; y: number }[]): string => ps.map((p) => `${r(p.x)},${r(p.y)}`).join(' ');
const DEGREES = 180 / Math.PI;

// MARK: The torso

/**
 * The cat's body as one figure, as the app's `PetTorso` draws it, number for number. The poses still say where the haunch and the chest
 * are (two ovals), but the outline is the haunch's round rear and the chest's round front joined by a back line above and a belly line
 * below, each one smooth cubic from one oval to the other. Each line starts from the ovals' common tangent on its side and is let down
 * into the waist part of the way to where their outlines cross (less for the back, more for the belly of a cat seen from the side); the
 * ovals' turn against each other is the spine's bend, which rounds one side out over both and draws the other in.
 */
const TORSO = {
  /** How far into the waist the lines are let down: the share of the way from the common tangent to where the ovals cross. */
  waist: 0.4,
  /** The back is let down by this share less, the belly by this more. */
  level: 0.12,
  /** How much each end of a line turns (radians) per radian the chest is turned against the haunch. */
  bend: 0.4,
  /** The furthest a line is let out (radians) over a rounded back, and the furthest share of the way to the notch it is let down. */
  bulge: 0.6, reach: 0.72,
  /** The length of a line's handles, as a share of the distance it spans. */
  handle: 0.38,
};
const TAU = 2 * Math.PI;
const wrap = (a: number): number => { const m = a % TAU; return m < 0 ? m + TAU : m; };

/** The point at parametric angle `t`. */
const ovalPoint = (o: Oval, t: number): V2 => {
  const c = Math.cos(o.angle), s = Math.sin(o.angle), lx = o.rx * Math.cos(t), ly = o.ry * Math.sin(t);
  return { x: o.cx + lx * c - ly * s, y: o.cy + lx * s + ly * c };
};
/** The outline's direction at `t`, counterclockwise (its derivative: not of unit length). */
const ovalDirection = (o: Oval, t: number): V2 => {
  const c = Math.cos(o.angle), s = Math.sin(o.angle), lx = -o.rx * Math.sin(t), ly = o.ry * Math.cos(t);
  return { x: lx * c - ly * s, y: lx * s + ly * c };
};
/** How far the oval reaches along the unit direction (`dx`, `dy`), and the parametric angle of the point that reaches it. */
const support = (o: Oval, dx: number, dy: number): { reach: number; angle: number } => {
  const c = Math.cos(o.angle), s = Math.sin(o.angle);
  const ax = o.rx * (dx * c + dy * s), by = o.ry * (-dx * s + dy * c);
  const k = Math.max(0.000001, Math.sqrt(ax * ax + by * by));
  return { reach: dx * o.cx + dy * o.cy + k, angle: Math.atan2(by, ax) };
};
/** Negative inside the oval, 0 on its outline, positive outside. */
const level = (o: Oval, p: V2): number => {
  const c = Math.cos(o.angle), s = Math.sin(o.angle), dx = p.x - o.cx, dy = p.y - o.cy;
  const lx = (dx * c + dy * s) / o.rx, ly = (-dx * s + dy * c) / o.ry;
  return lx * lx + ly * ly - 1;
};
/** The parametric angle of the point of the outline in the direction of `p` from the centre. */
const parameter = (o: Oval, p: V2): number => {
  const c = Math.cos(o.angle), s = Math.sin(o.angle), dx = p.x - o.cx, dy = p.y - o.cy;
  return Math.atan2((-dx * s + dy * c) / o.ry, (dx * c + dy * s) / o.rx);
};

/** One line's ends: `side` 1 is the back, -1 the belly. `bent` turns both ends toward the waist (positive) or away from it. */
function join(h: Oval, c: Oval, ux: number, uy: number, side: number, bent: number): [number, number] {
  // The common tangent on this side: Newton on the angle of its normal, from the perpendicular to the spine.
  let normal = Math.atan2(side * ux, -side * uy);
  for (let i = 0; i < 6; i++) {
    const dx = Math.cos(normal), dy = Math.sin(normal);
    const a = support(h, dx, dy), b = support(c, dx, dy);
    const pa = ovalPoint(h, a.angle), pb = ovalPoint(c, b.angle);
    const slope = (pa.x - pb.x) * -dy + (pa.y - pb.y) * dx;
    if (Math.abs(slope) < 0.001) break;
    const step = Math.max(-0.5, Math.min(0.5, (a.reach - b.reach) / slope));
    normal -= step;
    if (Math.abs(step) < 0.00001) break;
  }
  const dx = Math.cos(normal), dy = Math.sin(normal);
  const tangentH = support(h, dx, dy).angle, tangentC = support(c, dx, dy).angle;
  // The notch: along the haunch from its tangent point toward the waist, the first point inside the chest.
  const toward = -side;
  let low = 0, high = 0, found = false;
  for (let k = 1; k <= 12; k++) {
    const a = k * 0.26;
    if (level(c, ovalPoint(h, tangentH + toward * a)) <= 0) { low = a - 0.26; high = a; found = true; break; }
  }
  let spanH = 0.6, spanC = 0.6;
  if (found) {
    for (let i = 0; i < 6; i++) {
      const middle = (low + high) / 2;
      if (level(c, ovalPoint(h, tangentH + toward * middle)) <= 0) high = middle; else low = middle;
    }
    spanH = (low + high) / 2;
    spanC = wrap((parameter(c, ovalPoint(h, tangentH + toward * spanH)) - tangentC) * side);
    if (spanC > Math.PI) spanC = 0;
  }
  const share = TORSO.waist - TORSO.level * side * ux;
  const slideH = Math.max(-TORSO.bulge, Math.min(TORSO.reach * spanH, share * spanH + bent));
  const slideC = Math.max(-TORSO.bulge, Math.min(TORSO.reach * spanC, share * spanC + bent));
  return [tangentH + toward * slideH, tangentC + side * slideC];
}

/** An oval's arc counterclockwise from `t0`, as up to four cubics. */
function arc(o: Oval, t0: number, span: number): string {
  const n = Math.max(1, Math.ceil(span / (Math.PI / 2) - 0.000001));
  const d = span / n, k = (4 / 3) * Math.tan(d / 4);
  let out = '';
  for (let i = 0; i < n; i++) {
    const a = t0 + i * d, b = a + d;
    const p0 = ovalPoint(o, a), p3 = ovalPoint(o, b), v0 = ovalDirection(o, a), v3 = ovalDirection(o, b);
    out += `C${pt(p0.x + k * v0.x, p0.y + k * v0.y)} ${pt(p3.x - k * v3.x, p3.y - k * v3.y)} ${pt(p3.x, p3.y)}`;
  }
  return out;
}

/** A back or belly line: from oval `a` at `ta` to oval `b` at `tb`, leaving and arriving along each oval's own tangent. */
function line(a: Oval, ta: number, b: Oval, tb: number): string {
  const p0 = ovalPoint(a, ta), p3 = ovalPoint(b, tb);
  const v0 = ovalDirection(a, ta), v3 = ovalDirection(b, tb);
  const n0 = Math.max(0.000001, Math.sqrt(v0.x * v0.x + v0.y * v0.y)), n3 = Math.max(0.000001, Math.sqrt(v3.x * v3.x + v3.y * v3.y));
  const l = Math.sqrt((p3.x - p0.x) * (p3.x - p0.x) + (p3.y - p0.y) * (p3.y - p0.y)) * TORSO.handle;
  return `C${pt(p0.x + (v0.x / n0) * l, p0.y + (v0.y / n0) * l)} ${pt(p3.x - (v3.x / n3) * l, p3.y - (v3.y / n3) * l)} ${pt(p3.x, p3.y)}`;
}

/** Where the back line leaves the haunch and reaches the chest, and where the belly line does: each oval's parametric angle (the app's `PetTorso.init`). */
export interface TorsoJoins { backHaunch: number; backChest: number; bellyHaunch: number; bellyChest: number }
export function torsoJoins(haunch: Oval, chest: Oval): TorsoJoins {
  let ux = chest.cx - haunch.cx, uy = chest.cy - haunch.cy;
  const length = Math.sqrt(ux * ux + uy * uy);
  if (length < 0.001) { ux = 0; uy = 1; } else { ux /= length; uy /= length; }
  // The spine's bend: how far the chest is turned against the haunch (negative arches the back, positive sags it).
  const bent = TORSO.bend * (chest.angle - haunch.angle);
  const [backHaunch, backChest] = join(haunch, chest, ux, uy, 1, bent);
  const [bellyHaunch, bellyChest] = join(haunch, chest, ux, uy, -1, -bent);
  return { backHaunch, backChest, bellyHaunch, bellyChest };
}

/**
 * The torso's outline as path data, counterclockwise (the app's `PetTorso.trace`): from the back round the haunch's rear to the belly, the
 * belly line, round the chest's front, and the back line home.
 */
export function torsoPath(haunch: Oval, chest: Oval, j: TorsoJoins = torsoJoins(haunch, chest)): string {
  const start = ovalPoint(haunch, j.backHaunch);
  return `M${pt(start.x, start.y)}`
    + arc(haunch, j.backHaunch, wrap(j.bellyHaunch - j.backHaunch))
    + line(haunch, j.bellyHaunch, chest, j.bellyChest)
    + arc(chest, j.bellyChest, wrap(j.backChest - j.bellyChest))
    + line(chest, j.backChest, haunch, j.backHaunch)
    + 'Z';
}

/**
 * The waist: the belly and back lines, closed by a chord across each oval. With the two ovals it covers exactly what the outline does
 * (each chord runs inside its oval, and the ovals lie inside the outline), so the page draws the torso as the ovals plus this.
 */
function torsoWaist(haunch: Oval, chest: Oval, j: TorsoJoins): string {
  const a = ovalPoint(haunch, j.backHaunch), b = ovalPoint(haunch, j.bellyHaunch), c = ovalPoint(chest, j.backChest);
  return `M${pt(a.x, a.y)}L${pt(b.x, b.y)}`
    + line(haunch, j.bellyHaunch, chest, j.bellyChest)
    + `L${pt(c.x, c.y)}`
    + line(chest, j.backChest, haunch, j.backHaunch)
    + 'Z';
}

// MARK: The face

/**
 * The face as the app's `PetFace` lays it out, number for number, in the head's own frame. The poses only say where the cat looks and
 * how its ears are turned, and many layers add to both (a gesture, a perk, the pointer, the cat's own glances, the follow-through); a sum
 * the eye would never make on its own must still draw a cat. So:
 *   - the eyes go where the cat looks up to `eyeKnee`, and past it creep toward `eyeReach`, so they stay in the face;
 *   - the face turns with the eyes by `turnShare` of the way: the mouth, the glasses and a tear go with it, the forehead's stripes half
 *     as far;
 *   - an open mouth keeps `chin` inside the head's outline: a face looking down while it opens wide turns down no further than leaves
 *     the mouth room, the eyes with it;
 *   - an ear pricked forward stands up narrower (the outer corner of its base slides up the head's outline and its tip turns in about
 *     the middle of its base); one laid back folds out about the inner corner of its base. Neither lifts its base off the head, and
 *     both stop short of where an ear can go.
 */
export const FACE = {
  eyeRest: { x: 4.3, y: 0.3 },
  eyeKnee: { x: 1.8, y: 1.0 }, eyeReach: { x: 2.4, y: 1.4 },
  turnShare: 0.6,
  chin: 0.4,
  head: { w: 9.3, h: 7.4 },
  earForward: { knee: 0.3, reach: 0.5 }, earBack: { knee: 0.7, reach: 1.0 },
  earSlide: 1.2,
};
/** Where the outer corner of an ear's base rests: an angle round the head's outline, and how far out on it. */
const EAR_REST = { angle: Math.atan2(1.6 / 7.4, 9.1 / 9.3), out: Math.hypot(9.1 / 9.3, 1.6 / 7.4) };

/** `v` as it is up to `knee` (either way), and past it easing toward `reach`, which it never passes; smooth at the knee. */
export function soft(v: number, knee: number, reach: number): number {
  const a = Math.abs(v);
  if (a <= knee) return v;
  const room = reach - knee;
  const eased = knee + room * Math.tanh((a - knee) / room);
  return v < 0 ? -eased : eased;
}

export interface FaceLayout {
  /** How far both eyes are from where they rest, and how far the face has turned. */
  eyes: V2; turn: V2;
  eyeWidth: number; eyeHeight: number;
  /** The open mouth's centre and radii, or null when it is closed. */
  mouth: { cx: number; cy: number; rx: number; ry: number } | null;
}

/** The face of `pose` (the app's `PetFace.init`). */
export function faceLayout(pose: Pose): FaceLayout {
  const open = Math.max(0, pose.eyes);
  const eyeWidth = 2.2 + 0.9 * (1 - Math.min(1, open)), eyeHeight = Math.max(0.55, 2.9 * open);
  const eyes = { x: soft(pose.look.x, FACE.eyeKnee.x, FACE.eyeReach.x), y: soft(pose.look.y, FACE.eyeKnee.y, FACE.eyeReach.y) };
  const turn = { x: eyes.x * FACE.turnShare, y: eyes.y * FACE.turnShare };
  let mouth: FaceLayout['mouth'] = null;
  if (pose.mouth > 0.02) {
    const m = pose.mouth;
    const rx = 1.1 + 1.8 * m, ry = 0.3 + 3.2 * m;
    const across = turn.x / FACE.head.w;
    // The lowest the mouth's middle may be: its lowest point `chin` inside the head, below where it is across the face.
    const floor = ry - (FACE.head.h - FACE.chin) * Math.sqrt(Math.max(0, 1 - across * across));
    const lift = Math.max(0, floor - (-3.1 - 0.5 * m + turn.y));
    turn.y += lift; eyes.y += lift;
    mouth = { cx: turn.x, cy: -3.1 - 0.5 * m + turn.y, rx, ry };
  }
  return { eyes, turn, eyeWidth, eyeHeight, mouth };
}

/** How far an ear turned `angle` is drawn turned. */
export function earTurn(angle: number): number {
  return angle < 0 ? soft(angle, FACE.earForward.knee, FACE.earForward.reach) : soft(angle, FACE.earBack.knee, FACE.earBack.reach);
}

const rotate = (p: V2, c: V2, angle: number): V2 => {
  if (angle === 0) return p;
  const cs = Math.cos(angle), sn = Math.sin(angle), x = p.x - c.x, y = p.y - c.y;
  return { x: c.x + x * cs - y * sn, y: c.y + x * sn + y * cs };
};

/** The ear on `side` (-1 left, 1 right) turned `angle`: the outer corner of its base, its tip and the inner corner of its base (the app's `PetFace.ear`). */
export function earPoints(side: number, angle: number): [V2, V2, V2] {
  const outer = { x: side * 9.1, y: 1.6 }, tip = { x: side * 7.5, y: 12.2 }, inner = { x: side * 2.2, y: 6.6 };
  const a = earTurn(angle);
  // Counterclockwise is positive: a pricked right ear's tip turns counterclockwise (in), a laid-back one clockwise (out).
  const turn = side * -a;
  if (a < 0) {
    // Pricked: the outer corner slides up along the head's outline, so the ear stands up narrower, and the tip turns in about the middle of the base.
    const along = EAR_REST.angle - FACE.earSlide * a;
    const up = { x: side * FACE.head.w * EAR_REST.out * Math.cos(along), y: FACE.head.h * EAR_REST.out * Math.sin(along) };
    return [up, rotate(tip, { x: side * 5.65, y: 4.1 }, turn), inner];
  }
  // Laid back: the ear folds out about the inner corner of its base, and the outer corner goes down into the head.
  return [rotate(outer, inner, turn), rotate(tip, inner, turn), inner];
}

/** Fills in every attribute that depends on the pose. */
export function paint(pose: Pose, look: Look, set: Sink): void {
  const coat = COATS[look.coat];
  set('body', 'transform', pose.y !== 0 ? `translate(0 ${r(pose.y)})` : '');

  // Tail, behind everything.
  const t = pose.tail;
  set('tail', 'd', `M${pt(t.p0.x, t.p0.y)}C${pt(t.c1.x, t.c1.y)} ${pt(t.c2.x, t.c2.y)} ${pt(t.p3.x, t.p3.y)}`);
  set('tail', 'stroke-width', r(t.width));
  if (coat.stripe) {
    let d = '';
    for (const u of [0.4, 0.58, 0.75, 0.9]) {
      const v = 1 - u;
      const px = v * v * v * t.p0.x + 3 * v * v * u * t.c1.x + 3 * v * u * u * t.c2.x + u * u * u * t.p3.x;
      const py = v * v * v * t.p0.y + 3 * v * v * u * t.c1.y + 3 * v * u * u * t.c2.y + u * u * u * t.p3.y;
      const dx = 3 * v * v * (t.c1.x - t.p0.x) + 6 * v * u * (t.c2.x - t.c1.x) + 3 * u * u * (t.p3.x - t.c2.x);
      const dy = 3 * v * v * (t.c1.y - t.p0.y) + 6 * v * u * (t.c2.y - t.c1.y) + 3 * u * u * (t.p3.y - t.c2.y);
      const len = Math.max(0.001, Math.hypot(dx, dy));
      const nx = (-dy / len) * t.width * 0.5, ny = (dx / len) * t.width * 0.5;
      d += `M${pt(px - nx, py - ny)}L${pt(px + nx, py + ny)}`;
    }
    set('rings', 'd', d);
  }

  // Legs: a foot raised to the face is drawn over the head, with a thin black seam.
  pose.legs.forEach((l: Limb, i) => {
    const raised = l.foot.y > RAISED_ABOVE;
    set(`leg${i}b`, 'display', raised ? 'none' : '');
    set(`leg${i}h`, 'display', raised ? '' : 'none');
    set(`leg${i}f`, 'display', raised ? '' : 'none');
    if (raised) {
      set(`leg${i}h`, 'points', polyline(l.knee, l.foot));
      set(`leg${i}h`, 'stroke-width', r(l.width + 1.9));
      set(`leg${i}f`, 'points', polyline(l.hip, l.knee, l.foot));
      set(`leg${i}f`, 'stroke-width', r(l.width));
    } else {
      set(`leg${i}b`, 'points', polyline(l.hip, l.knee, l.foot));
      set(`leg${i}b`, 'stroke-width', r(l.width));
    }
  });

  // Body: one figure, the haunch and the chest joined by the back and the belly (the app's `PetTorso`). Its round ends are drawn as the
  // ovals themselves, and only the waist between them as a path: Chrome lays a path's edge a little inside where it lays the same
  // curve given as an `<ellipse>` (and where Core Graphics, the app's painter, lays both), so the ends keep the app's exact edge. The
  // three together are the same figure as the app's one outline. The flank's stripes (drawn over the near legs) are cut to that outline.
  const joins = torsoJoins(pose.haunch, pose.chest);
  const oval = (name: string, o: Oval) => {
    set(name, 'rx', r(o.rx)); set(name, 'ry', r(o.ry));
    set(name, 'transform', `translate(${pt(o.cx, o.cy)})${o.angle ? ` rotate(${r(o.angle * DEGREES)})` : ''}`);
  };
  oval('haunch', pose.haunch);
  oval('chest', pose.chest);
  set('waist', 'd', torsoWaist(pose.haunch, pose.chest, joins));
  if (coat.stripe) {
    set('torsoClip', 'd', torsoPath(pose.haunch, pose.chest, joins));
    set('flank', 'transform', `translate(${pt(pose.haunch.cx, pose.haunch.cy)})${pose.haunch.angle ? ` rotate(${r(pose.haunch.angle * DEGREES)})` : ''}`);
  }

  // Head: its own frame, so tilt and scale carry the ears, the face and what is worn on it along. Its scale is kept to four places: it
  // multiplies everything in the head, and rounded to two it put the ear tips (12 units out) up to 0.06 units off the app's.
  set('head', 'transform', `translate(${pt(pose.head.x, pose.head.y)}) scale(${String(Math.round(pose.headScale * 10000) / 10000)}) rotate(${r(pose.tilt * DEGREES)})`);
  // The ears turn as the app's `PetFace.ear` turns them: their bases stay on the head.
  for (const side of [-1, 1]) {
    const [o, tip, i] = earPoints(side, side < 0 ? pose.earL : pose.earR);
    set(side < 0 ? 'earL' : 'earR', 'points', polyline(o, tip, i));
  }
  // The face (the app's `PetFace`): the eyes where the cat looks, kept in the face, and the face turned with them. The forehead's
  // stripes, higher up the head, go half as far as it turns; the glasses, the mouth and a tear go with it.
  const face = faceLayout(pose);
  const turned = (k: number) => (face.turn.x || face.turn.y ? `translate(${pt(face.turn.x * k, face.turn.y * k)})` : '');
  set('forehead', 'transform', turned(0.5));
  // The eyes: both alike, as the app's painter draws them (`w` widens and `h` shrinks as a lid closes; a closed eye is a line).
  const w = face.eyeWidth, h = face.eyeHeight;
  for (const side of [-1, 1]) {
    const name = side < 0 ? 'eyeL' : 'eyeR';
    set(name, 'cx', r(side * FACE.eyeRest.x + face.eyes.x)); set(name, 'cy', r(FACE.eyeRest.y + face.eyes.y));
    set(name, 'rx', r(w / 2)); set(name, 'ry', r(h / 2));
  }
  // A glint at the upper left of each eye, so they look wet; it sits on the pupil and shrinks as a lid closes.
  if (pose.glisten > 0.02) {
    const gr = 0.62 * pose.glisten * Math.min(1, Math.max(0.25, h / 2.9));
    for (const side of [-1, 1]) {
      const name = side < 0 ? 'glint0' : 'glint1';
      set(name, 'display', '');
      set(name, 'cx', r(side * FACE.eyeRest.x + face.eyes.x - w * 0.2)); set(name, 'cy', r(FACE.eyeRest.y + face.eyes.y + h * 0.18)); set(name, 'r', r(gr));
    }
  } else { set('glint0', 'display', 'none'); set('glint1', 'display', 'none'); }
  // A tear wells at the lower lid of the left eye and runs down the cheek, swelling as it goes, gone before the chin. It runs on the face.
  if (pose.tear > 0.01) {
    const u = pose.tear, run = u * u * (3 - 2 * u), swell = Math.sin(Math.min(1, u * 1.15) * Math.PI * 0.5);
    const fade = u < 0.82 ? 1 : Math.max(0, 1 - (u - 0.82) / 0.18);
    const tr = 0.5 + 0.35 * swell, tx = -4.5 - 0.45 * run + face.turn.x, ty = -1.2 - 5.4 * run + face.turn.y;
    const alpha = r(Math.min(1, u * 8) * fade);
    set('tearDrop', 'display', ''); set('tearDrop', 'cx', r(tx)); set('tearDrop', 'cy', r(ty)); set('tearDrop', 'rx', r(tr)); set('tearDrop', 'ry', r(tr * 1.1)); set('tearDrop', 'opacity', alpha);
    set('tearTip', 'display', ''); set('tearTip', 'points', `${r(tx - tr * 0.86)},${r(ty + tr * 0.3)} ${r(tx)},${r(ty + tr * 2.2)} ${r(tx + tr * 0.86)},${r(ty + tr * 0.3)}`); set('tearTip', 'opacity', alpha);
  } else { set('tearDrop', 'display', 'none'); set('tearTip', 'display', 'none'); }
  if (face.mouth) {
    const mo = face.mouth;
    set('mouth', 'display', '');
    set('mouth', 'cx', r(mo.cx)); set('mouth', 'cy', r(mo.cy)); set('mouth', 'rx', r(mo.rx)); set('mouth', 'ry', r(mo.ry));
  } else set('mouth', 'display', 'none');

  // What hangs from the neck (it swings with the head's own motion) and what sits on the face.
  set('collar', 'display', look.accessory === 'collar' ? '' : 'none');
  set('bow', 'display', look.accessory === 'bow' ? '' : 'none');
  set('glasses', 'display', look.accessory === 'glasses' ? '' : 'none');
  set('glasses', 'transform', turned(1));
  if (look.accessory === 'collar') set('bell', 'transform', `translate(0 -7.4) rotate(${r(pose.swing * 0.7 * DEGREES)})`);

  // Toys, the nap's z's and the celebration's glints.
  if (pose.ballSize > 0) {
    set('ball', 'display', ''); set('ball', 'cx', r(pose.ball.x)); set('ball', 'cy', r(pose.ball.y)); set('ball', 'r', r(2.3 * pose.ballSize));
  } else set('ball', 'display', 'none');
  if (pose.moteSize > 0) {
    const mr = 1.45 * pose.moteSize;
    set('mote', 'display', ''); set('mote', 'cx', r(pose.mote.x)); set('mote', 'cy', r(pose.mote.y)); set('mote', 'rx', r(mr)); set('mote', 'ry', r(mr * 0.8));
  } else set('mote', 'display', 'none');
  if (pose.zAlpha > 0.04) {
    for (let i = 0; i < 2; i++) {
      const rise = (pose.zRise + i * 0.5) % 1;
      const size = 1.7 + 0.5 * i + rise * 1.1;
      const ax = pose.head.x + 0.5 + rise * 6, ay = pose.head.y + 7 + rise * 15;
      set(`z${i}`, 'display', '');
      set(`z${i}`, 'points', `${r(ax - size)},${r(ay + size)} ${r(ax + size)},${r(ay + size)} ${r(ax - size)},${r(ay - size)} ${r(ax + size)},${r(ay - size)}`);
      set(`z${i}`, 'opacity', r(Math.min(1, 0.6 * pose.zAlpha * Math.sin(rise * Math.PI))));
    }
  } else { set('z0', 'display', 'none'); set('z1', 'display', 'none'); }
  if (pose.sparkle > 0) {
    const defs: [number, number, number, number, number][] = [[10.6, 9.4, 2.9, 0.0, 0.7], [-10.2, 8.2, 2.1, 0.18, 0.85], [13.2, 2.4, 1.8, 0.3, 1.0]];
    defs.forEach(([dx, dy, size, from, to], i) => {
      const local = (pose.sparkle - from) / (to - from);
      if (!(local > 0 && local < 1)) { set(`sp${i}`, 'display', 'none'); return; }
      const glow = Math.sin(local * Math.PI), s = size * (0.45 + 0.55 * glow), k = s * 0.3;
      const cx = pose.head.x + dx, cy = pose.head.y + dy;
      set(`sp${i}`, 'display', '');
      set(`sp${i}`, 'points', `${r(cx)},${r(cy + s)} ${r(cx + k)},${r(cy + k)} ${r(cx + s)},${r(cy)} ${r(cx + k)},${r(cy - k)} ${r(cx)},${r(cy - s)} ${r(cx - k)},${r(cy - k)} ${r(cx - s)},${r(cy)} ${r(cx - k)},${r(cy + k)}`);
      set(`sp${i}`, 'opacity', r(0.95 * glow));
    });
  } else { set('sp0', 'display', 'none'); set('sp1', 'display', 'none'); set('sp2', 'display', 'none'); }
}

// MARK: Static markup

interface Node { p: string; tag: string; attrs?: Record<string, string>; kids?: Node[]; void?: boolean }

const leg = (i: number): Node[] => [
  { p: `leg${i}b`, tag: 'polyline', attrs: { class: 'cat-stroke' } },
];
const raisedLeg = (i: number): Node[] => [
  { p: `leg${i}h`, tag: 'polyline', attrs: { class: 'cat-seam' } },
  { p: `leg${i}f`, tag: 'polyline', attrs: { class: 'cat-stroke' } },
];

const TREE: Node[] = [
  {
    p: 'body', tag: 'g', kids: [
      { p: 'tail', tag: 'path', attrs: { class: 'cat-stroke' } },
      { p: 'rings', tag: 'path', attrs: { class: 'cat-stripe-stroke cat-stripe-only' } },
      ...leg(0), ...leg(1),
      { p: 'haunch', tag: 'ellipse', attrs: { class: 'cat-fill' } },
      { p: 'chest', tag: 'ellipse', attrs: { class: 'cat-fill' } },
      { p: 'waist', tag: 'path', attrs: { class: 'cat-fill' } },
      ...leg(2), ...leg(3),
      // The flank's stripes go over the near legs where they lie against the body, as the app's painter draws them (under them, a
      // seated cat's near thigh would cover all of one but a curled sliver). Their clip is the torso's own outline; its id is given per
      // cat (`clipIds`), as a page holds many cats.
      { p: 'clip', tag: 'clipPath', kids: [{ p: 'torsoClip', tag: 'path' }] },
      {
        p: 'flankClip', tag: 'g', attrs: { class: 'cat-stripe-only' }, kids: [{
          p: 'flank', tag: 'path', attrs: {
            class: 'cat-stripe-stroke',
            d: 'M-7 3L-5.7 0.5M-7.7 -0.9L-6.5 -3M7 3L5.7 0.5M7.7 -0.9L6.5 -3',
          },
        }],
      },
      {
        p: 'head', tag: 'g', kids: [
          { p: 'skull', tag: 'ellipse', attrs: { class: 'cat-fill', cx: '0', cy: '0', rx: '9.3', ry: '7.4' } },
          { p: 'earL', tag: 'polygon', attrs: { class: 'cat-fill', points: '-9.1,1.6 -7.5,12.2 -2.2,6.6' } },
          { p: 'earR', tag: 'polygon', attrs: { class: 'cat-fill', points: '9.1,1.6 7.5,12.2 2.2,6.6' } },
          { p: 'forehead', tag: 'path', attrs: { class: 'cat-stripe-stroke cat-stripe-only', d: 'M-2.5 6.1L-1.9 3.7M0 6.4L0 3.9M2.5 6.1L1.9 3.7' } },
          {
            p: 'collar', tag: 'g', kids: [
              { p: 'collarBand', tag: 'path', attrs: { fill: 'none', stroke: COLLAR, 'stroke-width': '1.7', 'stroke-linecap': 'round', d: 'M-6.6 -5.5C-3.2 -9.5 3.2 -9.5 6.6 -5.5' } },
              { p: 'bell', tag: 'g', kids: [{ p: 'bellBall', tag: 'circle', attrs: { cx: '0', cy: '-1.85', r: '1.25', fill: BELL } }] },
            ],
          },
          {
            p: 'bow', tag: 'g', attrs: { fill: BOW }, kids: [
              { p: 'bowL', tag: 'polygon', attrs: { points: '0,-8.2 -3.9,-5.9 -3.9,-10.5' } },
              { p: 'bowR', tag: 'polygon', attrs: { points: '0,-8.2 3.9,-5.9 3.9,-10.5' } },
              { p: 'bowKnot', tag: 'circle', attrs: { cx: '0', cy: '-8.2', r: '1' } },
            ],
          },
          { p: 'eyeL', tag: 'ellipse', attrs: { class: 'cat-eye' } },
          { p: 'eyeR', tag: 'ellipse', attrs: { class: 'cat-eye' } },
          { p: 'glint0', tag: 'circle', attrs: { fill: GLINT, 'fill-opacity': '0.95' } },
          { p: 'glint1', tag: 'circle', attrs: { fill: GLINT, 'fill-opacity': '0.95' } },
          { p: 'tearDrop', tag: 'ellipse', attrs: { fill: TEAR } },
          { p: 'tearTip', tag: 'polygon', attrs: { fill: TEAR } },
          { p: 'mouth', tag: 'ellipse', attrs: { class: 'cat-eye' } },
          {
            p: 'glasses', tag: 'g', attrs: { fill: 'none', stroke: '#000', 'stroke-width': '0.75', 'stroke-linecap': 'round' }, kids: [
              { p: 'glassL', tag: 'ellipse', attrs: { cx: '-4.3', cy: '0.3', rx: '3.2', ry: '3.2' } },
              { p: 'glassR', tag: 'ellipse', attrs: { cx: '4.3', cy: '0.3', rx: '3.2', ry: '3.2' } },
              { p: 'glassBridge', tag: 'path', attrs: { d: 'M-1.1 0.9L1.1 0.9' } },
            ],
          },
        ],
      },
      ...raisedLeg(0), ...raisedLeg(1), ...raisedLeg(2), ...raisedLeg(3),
      { p: 'ball', tag: 'circle', attrs: { fill: '#50d9ad', 'fill-opacity': '0.9' } },
      { p: 'mote', tag: 'ellipse', attrs: { fill: '#fff0a8', 'fill-opacity': '0.95' } },
      { p: 'z0', tag: 'polyline', attrs: { class: 'cat-z' } },
      { p: 'z1', tag: 'polyline', attrs: { class: 'cat-z' } },
      { p: 'sp0', tag: 'polygon', attrs: { class: 'cat-fill' } },
      { p: 'sp1', tag: 'polygon', attrs: { class: 'cat-fill' } },
      { p: 'sp2', tag: 'polygon', attrs: { class: 'cat-fill' } },
    ],
  },
];

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');

/** Every cat made here gets its own id for the stripes' clip, so two cats on a page never clip to each other's body. */
let clips = 0;
function clipIds(values: Record<string, Record<string, string>>): void {
  const id = `cat-torso-${++clips}`;
  values['clip'] = { ...(values['clip'] ?? {}), id };
  values['flankClip'] = { ...(values['flankClip'] ?? {}), 'clip-path': `url(#${id})` };
}

function render(nodes: Node[], values: Record<string, Record<string, string>>): string {
  return nodes.map((n) => {
    const merged: Record<string, string> = { ...(n.attrs ?? {}), ...(values[n.p] ?? {}) };
    const attrs = Object.entries(merged).filter(([, v]) => v !== '').map(([k, v]) => ` ${k}="${esc(v)}"`).join('');
    const hidden = merged['display'] === 'none' ? ' style="display:none"' : '';
    const dataAttrs = attrs.replace(/ display="none"/, '');
    return `<${n.tag} data-p="${n.p}"${dataAttrs}${hidden}>${n.kids ? render(n.kids, values) : ''}</${n.tag}>`;
  }).join('');
}

export interface MarkupOptions {
  /** Accessible name. Omit for a decorative cat (`aria-hidden`). */
  title?: string;
  class?: string;
  /** Rig units to pixels. */
  unit?: number;
}

/**
 * The cat for use outside the page's stylesheet (a favicon, a social image): the drawing in rig space with the page's classes
 * written out as a `<style>` with plain colours. The group maps rig space to y-down with the feet at y = 34.
 */
export function standaloneCat(look: Look = defaultLook, pose: Pose = basePose()): { css: string; group: string } {
  const values: Record<string, Record<string, string>> = {};
  paint(pose, look, (part, attr, value) => { (values[part] ??= {})[attr] = value; });
  clipIds(values);
  const coat = COATS[look.coat];
  const stripe = coat.stripe ?? '#555';
  const css = `.cat-fill{fill:${coat.fill}}.cat-stroke{fill:none;stroke:${coat.fill};stroke-linecap:round;stroke-linejoin:round}`
    + `.cat-seam{fill:none;stroke:#000;stroke-linecap:round;stroke-linejoin:round}.cat-eye{fill:#000}`
    + `.cat-z{fill:none;stroke:${coat.fill};stroke-width:1.1}.cat-stripe-stroke{fill:none;stroke:${stripe};stroke-width:.9}`
    + (coat.stripe ? '' : '.cat-stripe-only{display:none}');
  return { css, group: `<g transform="translate(0 34) scale(1 -1)">${render(TREE, values)}</g>` };
}

/** The cat as an SVG string, in `pose` (the home sit by default). */
export function catMarkup(look: Look = defaultLook, pose: Pose = basePose(), opts: MarkupOptions = {}): string {
  const values: Record<string, Record<string, string>> = {};
  paint(pose, look, (part, attr, value) => { (values[part] ??= {})[attr] = value; });
  clipIds(values);
  const coat = COATS[look.coat];
  const style = `--cat-fill:${coat.fill};${coat.stripe ? `--cat-stripe:${coat.stripe};` : ''}${opts.unit ? `--u:${opts.unit}px;` : ''}`;
  const a11y = opts.title ? `role="img" aria-label="${esc(opts.title)}"` : 'aria-hidden="true" focusable="false"';
  return `<svg class="cat ${opts.class ?? ''}${coat.stripe ? ' cat--striped' : ''}" viewBox="-22 0 ${BOX.w} ${BOX.h}" ${a11y} style="${style}" overflow="visible"><g transform="translate(0 34) scale(1 -1)">${render(TREE, values)}</g></svg>`;
}

// MARK: Live view

export interface CatView {
  svg: SVGSVGElement;
  paint(pose: Pose, look: Look): void;
  setLook(look: Look): void;
}

/** Binds the SVG made by `catMarkup` so poses can be painted onto it. Only attributes whose value changed are written. */
export function bindCat(svg: SVGSVGElement): CatView {
  const parts = new Map<string, Element>();
  svg.querySelectorAll('[data-p]').forEach((el) => parts.set(el.getAttribute('data-p')!, el));
  const last = new Map<string, string>();
  const sink: Sink = (part, attr, value) => {
    const key = `${part}|${attr}`;
    if (last.get(key) === value) return;
    last.set(key, value);
    const el = parts.get(part);
    if (!el) return;
    if (attr === 'display') {
      (el as SVGElement).style.display = value;
    } else if (value === '') {
      el.removeAttribute(attr);
    } else {
      el.setAttribute(attr, value);
    }
  };
  // The static markup already shows the first pose: remember what it says so nothing is rewritten needlessly.
  let current: Look = defaultLook;
  const view: CatView = {
    svg,
    paint(pose, look) {
      if (look !== current) view.setLook(look);
      paint(pose, look, sink);
    },
    setLook(look) {
      current = look;
      const coat = COATS[look.coat];
      svg.style.setProperty('--cat-fill', coat.fill);
      if (coat.stripe) svg.style.setProperty('--cat-stripe', coat.stripe); else svg.style.removeProperty('--cat-stripe');
      svg.classList.toggle('cat--striped', !!coat.stripe);
    },
  };
  return view;
}
