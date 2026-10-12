import { rng } from './rng';

/**
 * Typing with a human cadence: keys come at uneven intervals, words end with a longer breath, punctuation with a longer one,
 * and now and then the typist stops to think. The plan is a list of times (seconds from the start) at which each character
 * has been typed, made once from a seed, so playing, seeking and replaying all show the same text at the same moment.
 */
export interface TypePlan {
  /** `times[i]` is when the first `i + 1` characters are on screen. */
  times: number[];
  total: number;
}

export function planTyping(text: string, cps = 14, seed = 7): TypePlan {
  const next = rng(seed ^ text.length * 2654435761);
  const base = 1 / cps;
  const times: number[] = [];
  let t = 0.18 + next() * 0.12;
  const chars = Array.from(text);
  chars.forEach((ch, i) => {
    t += base * (0.55 + next() * 0.9);
    times.push(t);
    const after = chars[i + 1];
    if (ch === ' ') {
      t += base * (0.3 + next() * 0.9);
      if (next() < 0.07) t += 0.28 + next() * 0.3;
    } else if (/[,;:]/.test(ch)) t += base * (1.8 + next() * 2.4);
    else if (/[.!?¿¡…]/.test(ch) && after === undefined) t += 0.1;
    else if (/[.!?]/.test(ch)) t += base * (2.4 + next() * 3);
  });
  return { times, total: times.length ? (times[times.length - 1] as number) + 0.12 : 0 };
}

/** How many characters are on screen `elapsed` seconds in. */
export function typedCount(plan: TypePlan, elapsed: number): number {
  let lo = 0, hi = plan.times.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if ((plan.times[mid] as number) <= elapsed) lo = mid + 1; else hi = mid;
  }
  return lo;
}
