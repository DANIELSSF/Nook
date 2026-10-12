import { rng } from './rng';

/**
 * The synthetic cursor. It does not jump or glide in a straight line: it leaves along a gentle arc, speeds up, and settles on
 * its target, the way a hand moves a mouse. A path is a quadratic Bézier from where the cursor is to where it is going, bent
 * sideways by a fraction of the distance; the duration grows with the distance (a long reach takes longer than a short one).
 */
export interface Pt { x: number; y: number }

export interface Path { from: Pt; ctrl: Pt; to: Pt; length: number }

export function planPath(from: Pt, to: Pt, seed: number, arc?: number): Path {
  const dx = to.x - from.x, dy = to.y - from.y;
  const length = Math.hypot(dx, dy);
  const next = rng(seed);
  // A short hop barely bends; a long reach bends more. The side it bends to is chosen once, from the seed.
  const side = next() < 0.5 ? -1 : 1;
  const bend = (arc ?? (0.1 + next() * 0.12)) * Math.min(1, length / 220 + 0.25) * side;
  const nx = length ? -dy / length : 0, ny = length ? dx / length : 0;
  const mid = { x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 };
  return { from, ctrl: { x: mid.x + nx * length * bend, y: mid.y + ny * length * bend }, to, length };
}

export function pointAt(p: Path, u: number): Pt {
  const v = 1 - u;
  return {
    x: v * v * p.from.x + 2 * v * u * p.ctrl.x + u * u * p.to.x,
    y: v * v * p.from.y + 2 * v * u * p.ctrl.y + u * u * p.to.y,
  };
}

/** How long a reach of `length` px takes, in seconds. */
export function reachTime(length: number): number {
  return Math.min(1.6, Math.max(0.55, 0.42 + length / 620));
}

export const CURSOR_SVG = `<svg viewBox="0 0 20 26" width="20" height="26" aria-hidden="true" focusable="false"><path d="M2.4 1.7v19.2l5-4.7 3.2 8 3.3-1.3-3.2-7.9h7z" fill="#0b0b0b" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
