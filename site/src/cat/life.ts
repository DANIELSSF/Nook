/**
 * The cat's small life, ported from the app (`PetLife.swift`): how a cat carries itself (its temperament, from who it is and the
 * hour) and the small movements laid over every pose (blinks, a flick of an ear or the tail, a glance, a shift of weight, a sigh,
 * and the bursts of attention of a cat on duty). They are events at hashed moments of the clock, the app's own, so they happen
 * at the same moments as in the app. It has no DOM: the page's cats use it, and so does `npm run compare:cat`.
 */
import type { Pose } from './pose';
import * as A from './anim';
import type { DayPart } from '../scripts/env';

export type Personality = 'curious' | 'playful' | 'calm' | 'sleepy';

// MARK: Temperament (who the cat is, and the hour)

export interface Temperament {
  eyeOpen: number; earSet: number; blinkEvery: number; blinkLength: number; fidget: number; tailLift: number; headLift: number;
}

export function temperamentOf(personality: Personality, dayPart: DayPart = 'day'): Temperament {
  const t: Temperament = { eyeOpen: 1, earSet: 0, blinkEvery: 7.0, blinkLength: 0.2, fidget: 1, tailLift: 0, headLift: 0 };
  switch (personality) {
    case 'playful': Object.assign(t, { eyeOpen: 1.1, earSet: -0.08, blinkEvery: 6.0, blinkLength: 0.17, fidget: 1.35, tailLift: 2.4, headLift: 0.7 }); break;
    case 'calm': Object.assign(t, { eyeOpen: 0.9, earSet: 0.04, blinkEvery: 8.0, blinkLength: 0.24, fidget: 0.8, headLift: -0.2 }); break;
    case 'sleepy': Object.assign(t, { eyeOpen: 0.66, earSet: 0.13, blinkEvery: 9.0, blinkLength: 0.36, fidget: 0.55, tailLift: -2.0, headLift: -0.7 }); break;
    default: break;
  }
  if (dayPart === 'night') { t.eyeOpen *= 0.92; t.blinkLength *= 1.2; t.fidget *= 0.8; t.earSet += 0.03; t.headLift -= 0.2; }
  else if (dayPart === 'morning') t.fidget *= 1.1;
  return t;
}

// MARK: The small life laid over every pose

const LIFE = { ear: 20.0, listen: 41.0, look: 22.0, flick: 25.0, hook: 30.0, shift: 53.0, tilt: 45.0, onDuty: { look: 12.0, ear: 11.0, tail: 16.0, paw: 26.0 } };

export interface LifeContext {
  time: number; temperament: Temperament; restful: number; quiet: number; rate: number; alert: number;
  /** How big its breathing is against the plain cat's (the app's `breath`): it breathes less visibly while nobody is at the Mac. */
  breath?: number;
}

function posture(p: Pose, tm: Temperament, restful: number): void {
  p.eyes *= 1 - (1 - tm.eyeOpen) * restful;
  p.earL += tm.earSet * restful; p.earR += tm.earSet * restful;
  p.tail.p3.y += tm.tailLift * restful; p.tail.c2.y += tm.tailLift * 0.5 * restful;
  p.head.y += tm.headLift * restful; p.chest.ry += tm.headLift * 0.5 * restful;
}

export function applyLife(p: Pose, c: LifeContext): void {
  const t = c.time, tm = c.temperament;
  const f = tm.fidget * c.rate;
  const still = c.restful * c.quiet;
  const any = c.restful * 0.45 + 0.55 * c.restful * c.quiet;
  posture(p, tm, c.restful);
  const breath = c.breath ?? 1;
  if (breath !== 1 && p.action === 'sit') {
    const b = Math.sin(t * 1.7);
    p.chest.ry += (breath - 1) * 0.25 * b; p.head.y += (breath - 1) * 0.15 * b;
  }

  p.eyes *= 1 - A.blinkClosure(t, tm.blinkEvery / c.rate, tm.blinkLength, 1);
  const slow = A.event(t, 61, 1.5, 11);
  if (slow !== null && tm.fidget < 1.3) p.eyes *= 1 - 0.9 * A.ramp(slow, 0, 0.38) * (1 - A.ramp(slow, 0.62, 1));

  let u = A.event(t, LIFE.ear / f, 0.4, 3);
  if (u !== null) {
    const twitch = Math.sin(Math.PI * u) * 0.45 * any;
    if (A.hash(Math.floor(t / (LIFE.ear / f)), 9) < 0.5) p.earL -= twitch; else p.earR -= twitch;
  }
  u = A.event(t, LIFE.listen / f, 1.5, 14);
  if (u !== null) { const s = A.bump(u, 0, 1) * still; p.earL -= 0.2 * s; p.earR += 0.12 * s; p.tilt += 0.04 * s; }
  u = A.event(t, LIFE.look / f, 2.6, 4);
  if (u !== null) {
    const dir = A.hash(Math.floor(t / (LIFE.look / f)), 8) < 0.5 ? -1 : 1;
    const eyes = A.hold(u, 0.12, 0.85) * any, head = A.hold(u, 0.3, 0.8) * any;
    p.look.x += dir * 1.5 * eyes; p.look.y += 0.35 * eyes;
    p.head.x += dir * 0.55 * head; p.tilt += -dir * 0.07 * head;
  }
  u = A.event(t, LIFE.flick / f, 0.8, 2);
  if (u !== null) {
    const flick = Math.sin(u * Math.PI * 4) * (1 - u) * any;
    p.tail.p3.y += 3.5 * flick; p.tail.p3.x += 1.5 * flick; p.tail.c2.y += 2 * flick;
  }
  u = A.event(t, LIFE.hook / f, 2.4, 21);
  if (u !== null) { const s = A.bump(u, 0, 1) * still; p.tail.p3.y += 2.6 * s; p.tail.p3.x += 2.0 * s; p.tail.c2.y += 1.2 * s; }
  u = A.event(t, LIFE.shift / f, 1.8, 17);
  if (u !== null) {
    const dir = A.hash(Math.floor(t / (LIFE.shift / f)), 18) < 0.5 ? -1 : 1;
    const s = A.bump(u, 0, 1) * still;
    p.haunch.cx += 0.55 * dir * s; p.chest.cx -= 0.25 * dir * s; p.head.x -= 0.2 * dir * s;
  }
  u = A.event(t, 71, 2.6, 19);
  if (u !== null) { const s = A.bump(u, 0, 1) * c.restful; p.chest.ry += 0.8 * s; p.head.y += 0.45 * s; p.earL += 0.06 * s; p.earR += 0.06 * s; }
  u = A.event(t, LIFE.tilt / f, 1.9, 23);
  if (u !== null) {
    const dir = A.hash(Math.floor(t / (LIFE.tilt / f)), 24) < 0.5 ? -1 : 1;
    p.tilt += dir * 0.1 * A.bump(u, 0, 1) * still;
  }
  // On duty: it does not sway all the while, it watches.
  if (c.alert > 0) {
    const a = c.alert * c.restful;
    const busy = c.quiet > 0.5 ? a : 0;
    u = A.event(t, LIFE.onDuty.look, 4, 47);
    if (u !== null) { const g = A.hold(u, 0.15, 0.85) * a; p.look.x += 1.3 * g; p.look.y += 0.2 * g; p.tilt += -0.05 * g; }
    u = A.event(t, LIFE.onDuty.ear, 0.5, 49);
    if (u !== null) p.earR -= 0.3 * Math.sin(Math.PI * u) * a;
    u = A.event(t, LIFE.onDuty.tail, 1.1, 41);
    if (u !== null) { const tap = Math.sin(u * Math.PI * 4) * Math.sin(u * Math.PI) * busy; p.tail.p3.y += 3 * tap; p.tail.p3.x += 2 * tap; p.tail.c2.y += 1.5 * tap; }
    u = A.event(t, LIFE.onDuty.paw, 0.8, 43);
    if (u !== null) { const tap = Math.max(0, Math.sin(u * Math.PI * 3)) * 2.2 * busy; p.legs[3].foot.y += tap; p.legs[3].knee.y += tap * 0.6; }
  }
}
