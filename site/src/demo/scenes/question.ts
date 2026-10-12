import type { SceneDef } from '../types';

/**
 * "Responde en el momento": the island is collapsed while the visitor works elsewhere; it drops a small amber notice, the
 * visitor clicks it, the question opens as a card with every option, and one click answers it.
 */
export default function question(_c: unknown): SceneDef {
  return {
    id: 'question',
    islands: { island: 'collapsed' },
    cursorStart: { x: 300, y: 250 },
    hold: 1.8,
    steps: [
      { do: 'set', target: 'dots', vars: { attr: { 'data-on': 'true' } } },
      { do: 'caption', n: 0 },
      { do: 'wait', t: 0.9 },
      // The notice drops.
      { do: 'island', state: 'peek', t: 0.8 },
      { do: 'show', target: 'peek', fx: 'drop', t: 0.5, with: true, delay: 0.2 },
      { do: 'show', target: 'tab-0-q', fx: 'pop', t: 0.3, with: true, delay: 0.3 },
      { do: 'cat', action: 'perk', with: true, delay: 0.2 },
      { do: 'wait', t: 1.2 },
      { do: 'move', to: { el: 'peek', at: [0.5, 0.5] }, t: 1.1 },
      { do: 'click', press: 'peek' },
      // The island opens on the question.
      { do: 'hide', target: 'peek', fx: 'fade', t: 0.25, with: true, delay: 0.1 },
      { do: 'island', state: 'open', t: 0.95, with: true, delay: 0.1 },
      { do: 'show', target: 'card', fx: 'rise', t: 0.5, delay: 0.55, with: true },
      { do: 'caption', n: 1 },
      { do: 'zoom', to: { el: 'card', at: [0.5, 0.45] }, scale: 1.3, t: 1.1, with: true, delay: 0.3 },
      { do: 'wait', t: 1.6 },
      // An option.
      { do: 'caption', n: 2 },
      { do: 'move', to: { el: 'opt-1', at: [0.45, 0.5] }, t: 0.9 },
      { do: 'class', target: 'opt-1', add: 'is-hover', with: true, delay: 0.75 },
      { do: 'label', name: 'poster' },
      { do: 'wait', t: 0.4 },
      { do: 'click', press: 'opt-1' },
      { do: 'keys', keys: ['2'], t: 0.9, with: true },
      { do: 'class', target: 'opt-1', add: 'is-chosen', with: true, delay: 0.1 },
      { do: 'wait', t: 0.35 },
      { do: 'hide', target: 'card', fx: 'fade', t: 0.35 },
      { do: 'show', target: 'composer', fx: 'fade', t: 0.4, with: true },
      { do: 'hide', target: 'tab-0-q', fx: 'pop', t: 0.3, with: true },
      { do: 'show', target: 'm-answer', fx: 'rise', t: 0.4, with: true },
      { do: 'show', target: 'm-reply', fx: 'rise', t: 0.4, delay: 0.55 },
      { do: 'scroll', list: 'list', to: 'm-reply', t: 0.5, with: true },
      { do: 'zoom', to: 'fit', t: 1.1, delay: 0.6 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.5, with: true },
      { do: 'wait', t: 0.8 },
    ],
  };
}
