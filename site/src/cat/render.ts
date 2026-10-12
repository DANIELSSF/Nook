/**
 * Draws a `Pose` as SVG, the way the app's `PetPainter` draws it with Core Graphics. The same `paint` function feeds two
 * sinks: a plain object while Astro renders the static markup at build time, and the live elements in the browser, so the
 * cat in the HTML and the cat on the screen are the same drawing.
 *
 * Rig space has y pointing up with the feet at 0, so the root group flips it (`translate(0 34) scale(1 -1)`).
 */
import { basePose, type Pose, type Limb } from './pose';

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

  // Body.
  const oval = (name: string, o: Pose['haunch']) => {
    set(name, 'rx', r(o.rx)); set(name, 'ry', r(o.ry));
    set(name, 'transform', `translate(${pt(o.cx, o.cy)})${o.angle ? ` rotate(${r(o.angle * DEGREES)})` : ''}`);
  };
  oval('haunch', pose.haunch);
  oval('chest', pose.chest);
  if (coat.stripe) set('flank', 'transform', `translate(${pt(pose.haunch.cx, pose.haunch.cy)})${pose.haunch.angle ? ` rotate(${r(pose.haunch.angle * DEGREES)})` : ''}`);

  // Head: its own frame, so tilt and scale carry the ears, the face and what is worn on it along.
  set('head', 'transform', `translate(${pt(pose.head.x, pose.head.y)}) scale(${r(pose.headScale)}) rotate(${r(pose.tilt * DEGREES)})`);
  for (const side of [-1, 1]) {
    const angle = (side < 0 ? pose.earL : pose.earR) * DEGREES;
    set(side < 0 ? 'earL' : 'earR', 'transform', `translate(${r(side * 5.8)} 4.4) rotate(${r(-side * angle)}) translate(${r(-side * 5.8)} -4.4)`);
  }
  // The eyes: both alike, as the app's painter draws them (`w` widens and `h` shrinks as a lid closes; a closed eye is a line).
  const open = Math.max(0, pose.eyes);
  const w = 2.2 + 0.9 * (1 - Math.min(1, open)), h = Math.max(0.55, 2.9 * open);
  for (const side of [-1, 1]) {
    const name = side < 0 ? 'eyeL' : 'eyeR';
    set(name, 'cx', r(side * 4.3 + pose.look.x)); set(name, 'cy', r(0.3 + pose.look.y));
    set(name, 'rx', r(w / 2)); set(name, 'ry', r(h / 2));
  }
  // A glint at the upper left of each eye, so they look wet; it sits on the pupil and shrinks as a lid closes.
  if (pose.glisten > 0.02) {
    const gr = 0.62 * pose.glisten * Math.min(1, Math.max(0.25, h / 2.9));
    for (const side of [-1, 1]) {
      const name = side < 0 ? 'glint0' : 'glint1';
      set(name, 'display', '');
      set(name, 'cx', r(side * 4.3 + pose.look.x - w * 0.2)); set(name, 'cy', r(0.3 + pose.look.y + h * 0.18)); set(name, 'r', r(gr));
    }
  } else { set('glint0', 'display', 'none'); set('glint1', 'display', 'none'); }
  // A tear wells at the lower lid of the left eye and runs down the cheek, swelling as it goes, gone before the chin.
  if (pose.tear > 0.01) {
    const u = pose.tear, run = u * u * (3 - 2 * u), swell = Math.sin(Math.min(1, u * 1.15) * Math.PI * 0.5);
    const fade = u < 0.82 ? 1 : Math.max(0, 1 - (u - 0.82) / 0.18);
    const tr = 0.5 + 0.35 * swell, tx = -4.5 - 0.45 * run, ty = -1.2 - 5.4 * run;
    const alpha = r(Math.min(1, u * 8) * fade);
    set('tearDrop', 'display', ''); set('tearDrop', 'cx', r(tx)); set('tearDrop', 'cy', r(ty)); set('tearDrop', 'rx', r(tr)); set('tearDrop', 'ry', r(tr * 1.1)); set('tearDrop', 'opacity', alpha);
    set('tearTip', 'display', ''); set('tearTip', 'points', `${r(tx - tr * 0.86)},${r(ty + tr * 0.3)} ${r(tx)},${r(ty + tr * 2.2)} ${r(tx + tr * 0.86)},${r(ty + tr * 0.3)}`); set('tearTip', 'opacity', alpha);
  } else { set('tearDrop', 'display', 'none'); set('tearTip', 'display', 'none'); }
  if (pose.mouth > 0.02) {
    const m = pose.mouth;
    const rx = 1.1 + 1.8 * m, ry = 0.3 + 3.2 * m;
    set('mouth', 'display', '');
    set('mouth', 'cy', r(-3.1 - 0.5 * m)); set('mouth', 'rx', r(rx)); set('mouth', 'ry', r(ry));
  } else set('mouth', 'display', 'none');

  // What hangs from the neck (it swings with the head's own motion) and what sits on the face.
  set('collar', 'display', look.accessory === 'collar' ? '' : 'none');
  set('bow', 'display', look.accessory === 'bow' ? '' : 'none');
  set('glasses', 'display', look.accessory === 'glasses' ? '' : 'none');
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
      {
        p: 'flank', tag: 'path', attrs: {
          class: 'cat-stripe-stroke cat-stripe-only',
          d: 'M-7 3L-5.7 0.5M-7.7 -0.9L-6.5 -3M7 3L5.7 0.5M7.7 -0.9L6.5 -3',
        },
      },
      ...leg(2), ...leg(3),
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
          { p: 'mouth', tag: 'ellipse', attrs: { class: 'cat-eye', cx: '0' } },
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
