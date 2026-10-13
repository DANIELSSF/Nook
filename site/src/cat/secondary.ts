/**
 * The cat's follow-through, ported from the app (`PetSecondary.swift`): the parts of a cat that are not driven but follow. The
 * tail's tip lags the body and swings past where it is going, an ear flicks and rings, the head settles after it turns. Each is a
 * damped spring pulled toward where the pose wants it, laid over the finished pose, so every gesture gets it for free and nothing
 * the cat does stops dead. The tail is a chain (its middle follows where its base lags and its tip where its middle lags, so a
 * movement runs down it to the tip, the way a wave runs down a whip), and the ears lag the head's turns and sideways moves.
 *
 * A spring is advanced exactly (the position and velocity after `dt` seconds are the solution of its equation, not a step of an
 * integrator), so it is stable at any frame interval: a resting cat is drawn twenty times a second, a hopping one sixty.
 */
import type { Pose } from './pose';

interface Step { e: number; c: number; s: number; wd: number; zw: number }

/** The coefficients of one kind of spring for one `dt`. */
function step(w: number, zeta: number, dt: number): Step {
  const z = Math.min(zeta, 0.98);
  const wd = w * Math.sqrt(1 - z * z), zw = z * w;
  const a = wd * dt;
  return { e: Math.exp(-zw * dt), c: Math.cos(a), s: Math.sin(a), wd, zw };
}

class Spring {
  x = 0;
  v = 0;

  /** Moves toward `target` and returns where it is now. */
  advance(target: number, k: Step): number {
    const d = this.x - target;
    const b = (this.v + k.zw * d) / k.wd;
    const ac = d * k.c + b * k.s;
    this.x = target + k.e * ac;
    this.v = k.e * (-k.zw * ac + k.wd * (b * k.c - d * k.s));
    return this.x;
  }

  snap(value: number): void { this.x = value; this.v = 0; }
}

const inertia = (a: number, w: number, limit: number): number => Math.max(-limit, Math.min(limit, -a / (w * w)));

export class Secondary {
  private c1x = new Spring(); private c1y = new Spring(); private c2x = new Spring(); private c2y = new Spring();
  private p3x = new Spring(); private p3y = new Spring();
  private earL = new Spring(); private earR = new Spring();
  private headX = new Spring(); private headY = new Spring(); private tilt = new Spring();
  private swing = new Spring();
  private primed = false;
  private body = { x: 0, y: 0, vx: 0, vy: 0 };
  private headVelocity = 0;
  private lastHeadX = 0;
  /** How the drawn head moved: its sideways speed and its turning speed on the last frame, for the ears to lag. */
  private drawnHead = { x: 0, tilt: 0, vx: 0, spin: 0 };
  /** How much of the lag of each link of the tail the next one takes on. */
  static readonly chain = 0.5;

  /** Forget where everything was (the cat reappeared, or the pose jumped): the next frame starts at rest on its pose. */
  reset(): void { this.primed = false; }

  /** Lays the follow-through over `p`. `dt` is the seconds since the last frame; `scale` the pixels per rig unit. */
  apply(p: Pose, rawDt: number, scale: number): void {
    const bodyX = p.x / Math.max(scale, 0.01), bodyY = p.y;
    if (!this.primed) {
      this.primed = true;
      this.c1x.snap(p.tail.c1.x); this.c1y.snap(p.tail.c1.y); this.c2x.snap(p.tail.c2.x); this.c2y.snap(p.tail.c2.y);
      this.p3x.snap(p.tail.p3.x); this.p3y.snap(p.tail.p3.y);
      this.earL.snap(p.earL); this.earR.snap(p.earR); this.headX.snap(p.head.x); this.headY.snap(p.head.y); this.tilt.snap(p.tilt); this.swing.snap(0);
      this.body = { x: bodyX, y: bodyY, vx: 0, vy: 0 }; this.lastHeadX = p.head.x; this.headVelocity = 0;
      this.drawnHead = { x: p.head.x, tilt: p.tilt, vx: 0, spin: 0 };
      return;
    }
    const dt = Math.min(0.25, Math.max(0.001, rawDt));
    // The body's acceleration, from how its place changed.
    const vx = (bodyX - this.body.x) / dt, vy = (bodyY - this.body.y) / dt;
    const ax = (vx - this.body.vx) / dt, ay = (vy - this.body.vy) / dt;
    this.body = { x: bodyX, y: bodyY, vx, vy };

    const tailMid = step(13, 0.55, dt), tailTip = step(10, 0.5, dt), tailBase = step(17, 0.65, dt);
    const ears = step(26, 0.42, dt), head = step(20, 0.62, dt), bell = step(9, 0.22, dt);

    // The tail: the base moves first, the middle a beat later, the tip last and furthest, the way a whip does. Each link is pulled
    // toward where the pose wants it plus a share of how far the link before it is lagging, so the lag runs down to the tip.
    const lagX = inertia(ax, 10, 2.2), lagY = inertia(ay, 10, 2.2), k = Secondary.chain;
    const c1 = { x: this.c1x.advance(p.tail.c1.x, tailBase), y: this.c1y.advance(p.tail.c1.y, tailBase) };
    const c2 = { x: this.c2x.advance(p.tail.c2.x + lagX * 0.5 + k * (c1.x - p.tail.c1.x), tailMid), y: this.c2y.advance(p.tail.c2.y + lagY * 0.5 + k * (c1.y - p.tail.c1.y), tailMid) };
    const tip = { x: this.p3x.advance(p.tail.p3.x + lagX + k * (c2.x - p.tail.c2.x), tailTip), y: this.p3y.advance(p.tail.p3.y + lagY + k * (c2.y - p.tail.c2.y), tailTip) };
    p.tail.c1 = c1; p.tail.c2 = c2; p.tail.p3 = tip;

    // The head settles after it moves, and trails a little behind the body.
    const hx = this.headX.advance(p.head.x + inertia(ax, 20, 0.7) * 0.5, head);
    const hy = this.headY.advance(p.head.y + inertia(ay, 20, 0.7) * 0.5, head);
    p.tilt = this.tilt.advance(p.tilt, head);

    // The ears ring a little after a flick, are thrown back by a hop, and lag the head: a head that speeds up to the right leaves their
    // tips to the left (a turn counterclockwise of the ears), one that starts to turn counterclockwise leaves them clockwise, and they
    // swing back after it. An ear's angle opens it outward, so the same turn opens the left ear and closes the right one.
    const flop = inertia(ay, 26, 0.12) * 0.45;
    const headVX = (hx - this.drawnHead.x) / dt, spin = (p.tilt - this.drawnHead.tilt) / dt;
    const lag = Math.max(-0.08, Math.min(0.08, ((headVX - this.drawnHead.vx) / dt) * 0.001 - ((spin - this.drawnHead.spin) / dt) * 0.006));
    this.drawnHead = { x: hx, tilt: p.tilt, vx: headVX, spin };
    p.earL = this.earL.advance(p.earL - flop + lag, ears); p.earR = this.earR.advance(p.earR - flop - lag, ears);
    // A bell or a bow hangs from the neck: the head's sideways motion and its tilt swing it.
    this.headVelocity = (p.head.x - this.lastHeadX) / dt; this.lastHeadX = p.head.x;
    const pendulum = Math.max(-1, Math.min(1, -p.tilt / 0.7 - this.headVelocity * 0.05 + inertia(ax, 9, 0.6) * 0.4));
    p.swing = this.swing.advance(pendulum, bell);
    p.head = { x: hx, y: hy };
  }
}
