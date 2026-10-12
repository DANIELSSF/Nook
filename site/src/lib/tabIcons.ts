/**
 * The icons a tab can wear beside its name: a TypeScript port of the app's `TabIconArt` (TabIcons.swift).
 *
 * An icon is a few pieces of plain geometry (discs, rings, bars, polygons) in a 10 x 10 box with y pointing down. It is drawn in
 * the tab's colour and is calm: one soft movement, never a flash. `shapes(icon, null)` is the icon at rest, which is also its
 * movement at time zero (only the orbit's trail, which has nothing to trail behind at rest, appears with the movement). The same
 * function makes the still picture on the server (the editor's grid) and the moving one in the browser (`demo/liveIcons.ts`),
 * so an icon is the same drawing before and after the script runs.
 *
 * The numbers are the app's: if an icon changes there, change it here.
 */
export type TabIconName =
  | 'dot' | 'half' | 'orbit' | 'bars' | 'spark' | 'gem' | 'heart' | 'bolt'
  | 'leaf' | 'moon' | 'wave' | 'paw' | 'flame' | 'star' | 'code' | 'sun';

/** The picker's order, and the app's. */
export const TAB_ICONS: readonly TabIconName[] = [
  'dot', 'half', 'orbit', 'bars', 'spark', 'gem', 'heart', 'bolt', 'leaf', 'moon', 'wave', 'paw', 'flame', 'star', 'code', 'sun',
];

type Pt = readonly [number, number];
export type Shape =
  | { k: 'disc'; c: Pt; r: number; o: number }
  | { k: 'ring'; c: Pt; r: number; w: number; o: number }
  | { k: 'bar'; x: number; y: number; w: number; h: number; o: number }
  | { k: 'poly'; p: Pt[]; o: number };

// How long one turn, one pulse or one flip takes, in seconds. Slow on purpose: these sit in the corner of the eye.
const HALF_TURN = 2.8;
const ORBIT_TURN = 2.4;
const BARS_CYCLE = 1.8;
const SPARK_CYCLE = 2.2;
const GEM_TURN = 3.0;
const HEART_BEAT = 1.7;
const BOLT_CYCLE = 1.8;
const LEAF_SWAY = 2.8;
const MOON_CYCLE = 3.4;
const WAVE_CYCLE = 2.4;
const PAW_CYCLE = 2.0;
const FLAME_CYCLE = 1.9;
const STAR_TURN = 9.0;
const CODE_CYCLE = 2.2;
const SUN_TURN = 12.0;

const C: Pt = [5, 5];
const TAU = Math.PI * 2;

const frac = (v: number): number => v - Math.floor(v);
const disc = (c: Pt, r: number, o = 1): Shape => ({ k: 'disc', c, r, o });
const poly = (p: Pt[], o = 1): Shape => ({ k: 'poly', p, o });
const dist = (a: Pt, b: Pt): number => Math.hypot(a[0] - b[0], a[1] - b[1]);

function onCircle(radius: number, degrees: number): Pt {
  const a = (degrees * Math.PI) / 180;
  return [C[0] + radius * Math.cos(a), C[1] + radius * Math.sin(a)];
}

/** A smooth bump that is zero outside `from..to`: 0 at both ends, 1 in the middle. What a beat, a dip or a tap is made of. */
function bump(u: number, from: number, to: number): number {
  if (u < from || u >= to) return 0;
  const s = Math.sin((Math.PI * (u - from)) / (to - from));
  return s * s;
}

/** A line from `p` to `q` as a polygon, `width` thick. */
function stroke(p: Pt, q: Pt, width: number): Pt[] {
  const dx = q[0] - p[0], dy = q[1] - p[1];
  const len = Math.hypot(dx, dy);
  const nx = (-dy / len) * (width / 2), ny = (dx / len) * (width / 2);
  return [[p[0] + nx, p[1] + ny], [q[0] + nx, q[1] + ny], [q[0] - nx, q[1] - ny], [p[0] - nx, p[1] - ny]];
}

function rotated(points: Pt[], pivot: Pt, degrees: number): Pt[] {
  const a = (degrees * Math.PI) / 180;
  const c = Math.cos(a), s = Math.sin(a);
  return points.map(([x, y]) => [pivot[0] + (x - pivot[0]) * c - (y - pivot[1]) * s, pivot[1] + (x - pivot[0]) * s + (y - pivot[1]) * c] as Pt);
}

/** `points` clipped to the half-plane above or below the horizontal line `y` (the bolt is cut in two there). */
function clipped(points: Pt[], y: number, keepAbove: boolean): Pt[] {
  const inside = (p: Pt) => (keepAbove ? p[1] <= y : p[1] >= y);
  const cut = (a: Pt, b: Pt): Pt => { const k = (y - a[1]) / (b[1] - a[1]); return [a[0] + (b[0] - a[0]) * k, y]; };
  const out: Pt[] = [];
  points.forEach((a, i) => {
    const b = points[(i + 1) % points.length] as Pt;
    if (inside(a)) out.push(a);
    if (inside(a) !== inside(b)) out.push(cut(a, b));
  });
  return out;
}

/** A quadratic curve's points from `p0` to `p2`, bent toward `p1`. */
function curve(p0: Pt, p1: Pt, p2: Pt, steps: number): Pt[] {
  return Array.from({ length: steps + 1 }, (_, i) => {
    const u = i / steps, v = 1 - u;
    return [v * v * p0[0] + 2 * v * u * p1[0] + u * u * p2[0], v * v * p0[1] + 2 * v * u * p1[1] + u * u * p2[1]] as Pt;
  });
}

// MARK: The first six

/** Half of a disc, from `start` degrees (measured clockwise from the right) for 180 degrees. */
const halfDisc = (radius: number, start: number): Pt[] => Array.from({ length: 37 }, (_, i) => onCircle(radius, start + (180 * i) / 36));

/** A four-pointed star with its points up, down, left and right, its sides curving in toward the middle. */
function star4(radius: number, pinch: number): Pt[] {
  const points: Pt[] = [];
  const steps = 20;
  for (let tip = 0; tip < 4; tip++) {
    const from = tip * 90 - 90, to = from + 90;
    const start = onCircle(radius, from), end = onCircle(radius, to);
    const control = onCircle(radius * pinch, from + 45);
    for (let step = 0; step < steps; step++) {
      const u = step / steps;
      const a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u;
      points.push([a * start[0] + b * control[0] + c * end[0], a * start[1] + b * control[1] + c * end[1]]);
    }
  }
  return points;
}

// MARK: The newer ones

/** A heart, 8 wide and centred on the origin, from the classic curve. */
const HEART: Pt[] = (() => {
  const raw: Pt[] = Array.from({ length: 48 }, (_, i) => {
    const a = (TAU * i) / 48;
    return [16 * Math.sin(a) ** 3, -(13 * Math.cos(a) - 5 * Math.cos(2 * a) - 2 * Math.cos(3 * a) - Math.cos(4 * a))] as Pt;
  });
  const xs = raw.map((p) => p[0]), ys = raw.map((p) => p[1]);
  const scale = 8 / (Math.max(...xs) - Math.min(...xs));
  const mx = (Math.max(...xs) + Math.min(...xs)) / 2, my = (Math.max(...ys) + Math.min(...ys)) / 2;
  return raw.map((p) => [(p[0] - mx) * scale, (p[1] - my) * scale] as Pt);
})();

const BOLT: Pt[] = [[6.4, 0.4], [2.2, 5.6], [4.6, 5.6], [3.4, 9.6], [7.8, 4.2], [5.5, 4.2]];

/** The leaf's two halves (the shaded one is the lower side of its midrib), and its stem. */
const LEAF = (() => {
  const base: Pt = [2.5, 8.6], tip: Pt = [7.9, 2.2];
  const dx = tip[0] - base[0], dy = tip[1] - base[1];
  const length = Math.hypot(dx, dy);
  const nx = -dy / length, ny = dx / length;
  const left: Pt[] = [], right: Pt[] = [];
  for (let i = 0; i <= 14; i++) {
    const v = i / 14;
    const w = 2.15 * Math.sin(Math.PI * Math.pow(v, 0.85)) * (1 - 0.18 * v);
    const cx = base[0] + dx * v, cy = base[1] + dy * v;
    left.push([cx + nx * w, cy + ny * w]);
    right.push([cx - nx * w, cy - ny * w]);
  }
  return { light: [...left, tip, base] as Pt[], shade: [...right.reverse(), base] as Pt[], stem: stroke([1.4, 9.4], [2.9, 7.9], 0.9), pivot: base };
})();

/** The run of points of the circle (`center`, `radius`) that `keep` accepts (the part of one moon circle that is outside, or inside, the other). */
function arc(center: Pt, radius: number, steps: number, keep: (p: Pt) => boolean): Pt[] {
  const all: Pt[] = Array.from({ length: steps }, (_, i) => {
    const a = (TAU * i) / steps;
    return [center[0] + radius * Math.cos(a), center[1] + radius * Math.sin(a)] as Pt;
  });
  const kept = new Set<number>();
  all.forEach((p, i) => { if (keep(p)) kept.add(i); });
  let first = -1;
  for (const i of kept) if (!kept.has((i + steps - 1) % steps)) { first = i; break; }
  if (first < 0) return all.filter(keep);
  const run: Pt[] = [];
  let i = first;
  while (kept.has(i)) { run.push(all[i] as Pt); i = (i + 1) % steps; }
  return run;
}

const PAW_PAD: Pt[] = Array.from({ length: 36 }, (_, i) => {
  const a = (TAU * i) / 36;
  const r = 2.55 + 0.315 * Math.cos(3 * (a - Math.PI / 2));
  return [5 + r * Math.cos(a) * 1.12, 7.05 + r * Math.sin(a) * 0.82] as Pt;
});

/** A flame that is round at the bottom and leans to a point: `bend` pushes its curve toward the tip's side. */
function teardrop(center: Pt, radius: number, tip: Pt, bend: number, o: number): Shape {
  const height = center[1] - tip[1];
  const left = curve([center[0] - radius, center[1]], [center[0] - radius * 0.98 + bend * 0.15, center[1] - height * 0.62], tip, 14);
  const right = curve(tip, [center[0] + radius * 0.9 + bend * 0.9, center[1] - height * 0.42], [center[0] + radius, center[1]], 14);
  const belly: Pt[] = [];
  for (let i = 1; i < 14; i++) {
    const a = (Math.PI * i) / 14;
    belly.push([center[0] + radius * Math.cos(a), center[1] + radius * 0.95 * Math.sin(a)]);
  }
  return poly([...right, ...belly, ...left], o);
}

/** The pieces of `icon` `time` seconds into its movement; `null` is the icon at rest. */
export function shapes(icon: TabIconName, time: number | null): Shape[] {
  const t = time ?? 0;
  switch (icon) {
    case 'dot': return [disc(C, 2.5)];

    case 'half': {
      // A ring and a half of the disc, solid: the half goes round clockwise, starting on the left like a half-filled circle.
      const start = 90 + 360 * frac(t / HALF_TURN);
      return [{ k: 'ring', c: C, r: 4.0, w: 1.15, o: 0.95 }, poly(halfDisc(4.55, start))];
    }

    case 'orbit': {
      // A core, a faint track and a small moon on it, with a short trail while it goes round.
      const radius = 3.55;
      const angle = -50 + 360 * frac(t / ORBIT_TURN);
      const out: Shape[] = [{ k: 'ring', c: C, r: radius, w: 1.0, o: 0.4 }, disc(C, 1.45, 0.95)];
      if (time !== null) {
        for (let behind = 6; behind >= 1; behind--) out.push(disc(onCircle(radius, angle - 9 * behind), 1.2 * (1 - behind / 8), 0.55 * (1 - behind / 7)));
      }
      out.push(disc(onCircle(radius, angle), 1.4));
      return out;
    }

    case 'bars': {
      const width = 1.55, gap = 0.95;
      const heights = [0.0, 1.6, 3.3, 4.9].map((p) => 3.2 + 5.2 * (0.5 + 0.5 * Math.sin((TAU * t) / BARS_CYCLE + p)));
      const left = C[0] - (heights.length * width + (heights.length - 1) * gap) / 2;
      return heights.map((h, i): Shape => ({ k: 'bar', x: left + i * (width + gap), y: C[1] - h / 2, w: width, h, o: 1 }));
    }

    case 'spark': {
      // The star breathes: a little smaller and fainter, then full again.
      const light = 0.5 + 0.5 * Math.cos((TAU * t) / SPARK_CYCLE);
      return [poly(star4(4.8 * (0.78 + 0.22 * light), 0.16), 0.72 + 0.28 * light)];
    }

    case 'gem': {
      // A diamond turning on its vertical axis: it narrows to a sliver and comes back with the other facet in the light.
      const turn = Math.cos((TAU * t) / GEM_TURN);
      const half = Math.max(3.9 * Math.abs(turn), 0.35);
      const top: Pt = [C[0], 0.5], bottom: Pt = [C[0], 9.5];
      const lit = 1.0, shade = 0.62;
      return [poly([top, [C[0] - half, C[1]], bottom], turn >= 0 ? lit : shade), poly([top, [C[0] + half, C[1]], bottom], turn >= 0 ? shade : lit)];
    }

    case 'heart': {
      // It beats twice and rests, as a heart does: a firm beat, a softer one, and a pause.
      const u = frac(t / HEART_BEAT);
      const size = 1 + 0.14 * bump(u, 0, 0.17) + 0.09 * bump(u, 0.24, 0.4);
      return [poly(HEART.map((p) => [5 + p[0] * size, 5.15 + p[1] * size] as Pt))];
    }

    case 'bolt': {
      // The bolt in two halves, a little under half its brightness taken from each in turn: the charge runs down it.
      const u = frac(t / BOLT_CYCLE);
      return [poly(clipped(BOLT, 5, true), 1 - 0.45 * bump(u, 0, 0.5)), poly(clipped(BOLT, 5, false), 1 - 0.45 * bump(u, 0.5, 1))];
    }

    case 'leaf': {
      // It sways on its stem, a few degrees either way.
      const degrees = 13 * Math.sin((TAU * t) / LEAF_SWAY);
      return [poly(rotated(LEAF.light, LEAF.pivot, degrees)), poly(rotated(LEAF.shade, LEAF.pivot, degrees), 0.62), poly(rotated(LEAF.stem, LEAF.pivot, degrees))];
    }

    case 'moon': {
      // A crescent moon whose shadow drifts a little (it waxes and wanes), with a small star beside it that twinkles with it.
      const s = 0.5 - 0.5 * Math.cos((TAU * t) / MOON_CYCLE);
      const outerCenter: Pt = [4.7, 5.35], outerRadius = 4.25;
      const innerCenter: Pt = [outerCenter[0] + 2.0 + 0.6 * s, outerCenter[1] - 1.55 - 0.25 * s], innerRadius = 3.6;
      const outer = arc(outerCenter, outerRadius, 72, (p) => dist(p, innerCenter) >= innerRadius);
      const inner = arc(innerCenter, innerRadius, 90, (p) => dist(p, outerCenter) <= outerRadius);
      const last = outer[outer.length - 1], first = inner[0], end = inner[inner.length - 1];
      if (last && first && end && dist(first, last) > dist(end, last)) inner.reverse();
      return [poly([...outer, ...inner]), disc([7.95, 2.05], 0.8, 1 - 0.55 * s)];
    }

    case 'wave': {
      // Two waves rolling to the left, the farther one fainter.
      const phase = (TAU * t) / WAVE_CYCLE;
      const ribbon = (y: number, shift: number, o: number): Shape => {
        const top: Pt[] = [], bottom: Pt[] = [];
        for (let i = 0; i <= 22; i++) {
          const x = 0.5 + (9.0 * i) / 22;
          const h = y + 1.1 * Math.sin((TAU * (x - 0.5)) / 4.5 - phase + shift);
          top.push([x, h - 0.75]);
          bottom.push([x, h + 0.75]);
        }
        return poly([...top, ...bottom.reverse()], o);
      };
      return [ribbon(3.5, 0, 1), ribbon(6.7, 1.4, 0.6)];
    }

    case 'paw': {
      // A cat's paw. The toes dip one after another, as a paw taps; the pad stays.
      const toes: Pt[] = [[1.9, 4.6], [3.95, 2.45], [6.05, 2.45], [8.1, 4.6]];
      const out = toes.map((c, i): Shape => disc(c, 1.15, 1 - 0.55 * bump(frac(t / PAW_CYCLE - 0.25 * i), 0, 0.25)));
      out.push(poly(PAW_PAD));
      return out;
    }

    case 'flame': {
      // Three tongues, a big one, a lick beside it and a bright core in it. They sway and flicker out of step.
      const sway = Math.sin((TAU * t) / FLAME_CYCLE);
      const flicker = 0.45 * (0.5 - 0.5 * Math.cos((TAU * 2 * t) / FLAME_CYCLE));
      return [
        teardrop([5.3, 6.5], 2.95, [6.0 + 0.75 * sway, 0.7 + flicker], 0.9 + 0.5 * sway, 0.62),
        teardrop([2.9, 7.4], 1.55, [2.2 - 0.35 * sway, 4.1 + flicker * 0.8], -0.3, 0.62),
        teardrop([5.3, 7.55], 1.6, [5.55 + 0.45 * sway, 4.4 + flicker * 0.7], 0.4, 1),
      ];
    }

    case 'star': {
      // A five-pointed star that turns slowly: after a fifth of a turn it looks as it did, so the turn has no seam.
      const turn = (360 * t) / STAR_TURN;
      return [poly(Array.from({ length: 10 }, (_, i) => onCircle(i % 2 === 0 ? 4.85 : 2.0, -90 + 36 * i + turn)))];
    }

    case 'code': {
      // The two brackets breathe apart and together, and the slash a little fainter with them.
      const s = 0.5 - 0.5 * Math.cos((TAU * t) / CODE_CYCLE);
      const apart = 0.55 * s, width = 1.25;
      const out: Shape[] = [];
      for (const sign of [-1, 1]) {
        const tipX = 5 + sign * (3.55 + apart);
        const arm = 5 + sign * (1.5 + apart);
        const top: Pt = [arm, 2.7], middle: Pt = [tipX, 5], bottom: Pt = [arm, 7.3];
        out.push(poly(stroke(top, middle, width)), poly(stroke(middle, bottom, width)), disc(middle, width / 2));
      }
      out.push(poly(stroke([5.75, 1.9], [4.25, 8.1], 1.15), 1 - 0.3 * s));
      return out;
    }

    case 'sun': {
      // A sun whose eight rays turn slowly round it; after an eighth of a turn it looks as it did.
      const turn = (360 * t) / SUN_TURN;
      const out: Shape[] = [disc(C, 2.35)];
      for (let ray = 0; ray < 8; ray++) {
        const degrees = 45 * ray + turn;
        out.push(poly(stroke(onCircle(3.55, degrees), onCircle(4.7, degrees), 1.15)));
      }
      return out;
    }
  }
}

/** Whether the icon moves at all. The dot is the still choice. */
export const moves = (icon: TabIconName): boolean => icon !== 'dot';

const n = (v: number): string => String(Math.round(v * 100) / 100);

/** The SVG elements of `shapes`, to go inside a `viewBox="0 0 10 10"` that fills with `currentColor`. */
export function markup(list: Shape[]): string {
  return list.map((s) => {
    const o = s.o < 1 ? ` opacity="${n(s.o)}"` : '';
    switch (s.k) {
      case 'disc': return `<circle cx="${n(s.c[0])}" cy="${n(s.c[1])}" r="${n(s.r)}"${o}/>`;
      case 'ring': return `<circle cx="${n(s.c[0])}" cy="${n(s.c[1])}" r="${n(s.r)}" fill="none" stroke="currentColor" stroke-width="${n(s.w)}"${o}/>`;
      case 'bar': return `<rect x="${n(s.x)}" y="${n(s.y)}" width="${n(s.w)}" height="${n(s.h)}" rx="${n(s.w / 2)}"${o}/>`;
      case 'poly': return `<polygon points="${s.p.map((p) => `${n(p[0])},${n(p[1])}`).join(' ')}"${o}/>`;
    }
  }).join('');
}

/** The icon's inner markup at `time` (`null`: at rest). */
export const iconMarkup = (icon: TabIconName, time: number | null): string => markup(shapes(icon, time));
