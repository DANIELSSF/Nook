import type { SceneDef } from '../types';

interface Copy { capsuleDone: string; usage: { limits: { pct: number }[] } }

/**
 * "Subagentes y uso": the capsule counts the agents; its list says who does what; one finishes; a click on the gauge grows the
 * island to show the usage card, and its meters fill.
 */
export default function agents(c: Copy): SceneDef {
  const meters = c.usage.limits.map((_, i) => `meter-${i}`);
  return {
    id: 'agents',
    islands: { island: 'open' },
    cursorStart: { x: 690, y: 330 },
    hold: 1.8,
    steps: [
      { do: 'caption', n: 0 },
      { do: 'wait', t: 0.9 },
      // The list.
      { do: 'caption', n: 1 },
      { do: 'click', to: 'capsule', press: 'capsule' },
      { do: 'show', target: 'agents', fx: 'pop', t: 0.35, with: true, delay: 0.1 },
      { do: 'zoom', to: { el: 'agents', at: [0.5, 0.55] }, scale: 1.3, t: 1.1, with: true, delay: 0.3 },
      { do: 'wait', t: 1.6 },
      { do: 'label', name: 'poster' },
      // One agent finishes.
      { do: 'tween', target: 'ad-1', vars: { backgroundColor: '#51d9ad' }, t: 0.4 },
      { do: 'text', target: 'ac-1', text: 'terminó', with: true, delay: 0.1 },
      { do: 'text', target: 'at-1', text: '1:48', with: true, delay: 0.1 },
      { do: 'tween', target: 'cd-1', vars: { backgroundColor: '#51d9ad' }, t: 0.4, with: true },
      { do: 'wait', t: 1.2 },
      { do: 'hide', target: 'agents', fx: 'fade', t: 0.3 },
      // The usage card.
      { do: 'caption', n: 2 },
      { do: 'zoom', to: 'fit', t: 0.9, with: true },
      { do: 'click', to: 'chip-usage', press: 'chip-usage' },
      { do: 'island', state: 'tall', t: 1.0, with: true, delay: 0.1 },
      { do: 'show', target: 'usage', fx: 'rise', t: 0.5, with: true, delay: 0.45 },
      ...meters.map((m, i) => ({ do: 'tween' as const, target: m, from: { scaleX: 0 }, vars: { scaleX: c.usage.limits[i]!.pct / 100 }, t: 1.1, with: true, delay: 0.5 + i * 0.12, ease: 'power3.out' })),
      { do: 'wait', t: 2.0 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.5 },
      { do: 'wait', t: 0.6 },
    ],
  };
}
