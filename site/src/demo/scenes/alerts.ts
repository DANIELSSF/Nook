import type { SceneDef, Step } from '../types';

/**
 * "Con la isla recogida": the visitor works in another app; the island drops a notice for each thing that happens (mint when
 * something finishes, amber for a question, soft red for a failure) and tucks away again, leaving a badge on the notch. A
 * click on a notice opens that tab.
 */
export default function alerts(_c: unknown): SceneDef {
  const notice = (id: 'ok' | 'ask', count: string, cat: 'celebrate' | 'perk', first: boolean): Step[] => [
    { do: 'island', state: 'peek', t: 0.8 },
    { do: 'show', target: `peek-${id}`, fx: 'drop', t: 0.45, with: true, delay: 0.2 },
    { do: 'cat', action: cat, with: true, delay: 0.35 },
    { do: 'wait', t: 1.6 },
    { do: 'hide', target: `peek-${id}`, fx: 'fade', t: 0.25 },
    { do: 'island', state: 'collapsed', t: 0.75, with: true },
    ...(first ? [{ do: 'hide', target: 'dots', fx: 'fade', t: 0.2, with: true } as Step] : []),
    { do: 'text', target: 'badge', text: count, with: true, delay: 0.2 },
    ...(id === 'ask' ? [{ do: 'class', target: 'badge', add: 'badge--ask', with: true, delay: 0.2 } as Step] : []),
    { do: 'show', target: 'badge', fx: 'pop', t: 0.3, with: true, delay: 0.3 },
  ];
  return {
    id: 'alerts',
    islands: { island: 'collapsed' },
    cursorStart: { x: 560, y: 330 },
    hold: 1.8,
    steps: [
      { do: 'caption', n: 0 },
      { do: 'wait', t: 0.6 },
      ...notice('ok', '1', 'celebrate', true),
      { do: 'wait', t: 0.5 },
      { do: 'caption', n: 1 },
      ...notice('ask', '2', 'perk', false),
      { do: 'wait', t: 0.5 },
      { do: 'caption', n: 2 },
      { do: 'island', state: 'peek', t: 0.8 },
      { do: 'show', target: 'peek-fail', fx: 'drop', t: 0.45, with: true, delay: 0.2 },
      { do: 'cat', action: 'perk', with: true, delay: 0.35 },
      { do: 'move', to: { el: 'peek-fail', at: [0.5, 0.5] }, t: 1.2, delay: 0.2 },
      { do: 'label', name: 'poster' },
      { do: 'click', press: 'peek-fail' },
      { do: 'hide', target: 'peek-fail', fx: 'fade', t: 0.25, with: true, delay: 0.1 },
      { do: 'hide', target: 'badge', fx: 'fade', t: 0.2, with: true, delay: 0.1 },
      { do: 'island', state: 'open', t: 0.95, with: true, delay: 0.1 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.5, delay: 0.8 },
      { do: 'wait', t: 1.0 },
    ],
  };
}
