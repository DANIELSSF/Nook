import type { SceneDef } from '../types';

interface Copy { typed: string; working: string; done: string }

/**
 * "Mira trabajar a tu IA": the cursor goes to the cat and the island opens; a message is typed and sent; Claude's tools
 * appear one by one, then an edit with red and green lines, then the answer, and the cat celebrates.
 */
export default function follow(c: Copy): SceneDef {
  return {
    id: 'follow',
    islands: { island: 'collapsed' },
    cursorStart: { x: 690, y: 330 },
    hold: 1.8,
    steps: [
      { do: 'hide', target: ['m-user', 'm-tool1', 'm-out1', 'm-tool2', 'm-out2', 'm-diff', 'm-answer'], fx: 'fade', t: 0.01 },
      { do: 'caption', n: 0 },
      { do: 'wait', t: 0.35 },
      // The pointer goes to the cat and the island opens.
      { do: 'move', to: { el: 'cat', at: [0.5, 0.55] }, t: 1.25 },
      { do: 'island', state: 'open', t: 0.95 },
      { do: 'wait', t: 0.15 },
      // A message.
      { do: 'caption', n: 1 },
      { do: 'click', to: { el: 'field', at: [0.3, 0.2] }, press: 'composer', zoom: 1.4 },
      { do: 'class', target: 'composer', add: 'is-focus', with: true, delay: 0.5 },
      { do: 'wait', t: 0.1 },
      { do: 'type', target: 'typed', text: c.typed, cps: 22 },
      { do: 'class', target: 'send', add: 'is-ready' },
      { do: 'wait', t: 0.2 },
      { do: 'keys', keys: ['↵'], t: 1.0 },
      { do: 'class', target: 'send', add: 'is-press', delay: 0.05 },
      { do: 'text', target: 'typed', text: '', with: true, delay: 0.08 },
      { do: 'class', target: 'send', remove: 'is-ready is-press', with: true, delay: 0.2 },
      { do: 'show', target: 'm-user', fx: 'rise', t: 0.45 },
      { do: 'show', target: 'm-tag', fx: 'fade', t: 0.25, with: true },
      { do: 'scroll', list: 'list', to: 'm-user', t: 0.55, with: true },
      { do: 'cat', action: 'work', with: true },
      { do: 'set', target: 'dots', vars: { attr: { 'data-on': 'true' } }, with: true },
      { do: 'class', target: 'status', add: 'is-busy', with: true },
      { do: 'text', target: 'status-text', text: c.working, with: true },
      { do: 'hide', target: 'm-tag', fx: 'fade', t: 0.3, with: true, delay: 0.9 },
      // Claude works.
      { do: 'caption', n: 2 },
      { do: 'zoom', to: { el: 'convo', at: [0.5, 0.2] }, scale: 1.2, t: 1.0 },
      { do: 'wait', t: 0.45 },
      { do: 'show', target: 'm-tool1', fx: 'rise', t: 0.35 },
      { do: 'scroll', list: 'list', to: 'm-tool1', t: 0.45, with: true },
      { do: 'show', target: 'm-out1', fx: 'rise', t: 0.35, with: true, delay: 0.3 },
      { do: 'scroll', list: 'list', to: 'm-out1', t: 0.45, with: true, delay: 0.3 },
      { do: 'wait', t: 0.7 },
      { do: 'show', target: 'm-tool2', fx: 'rise', t: 0.35 },
      { do: 'scroll', list: 'list', to: 'm-tool2', t: 0.45, with: true },
      { do: 'show', target: 'm-out2', fx: 'rise', t: 0.35, with: true, delay: 0.3 },
      { do: 'scroll', list: 'list', to: 'm-out2', t: 0.45, with: true, delay: 0.3 },
      { do: 'wait', t: 0.7 },
      { do: 'caption', n: 3 },
      { do: 'show', target: 'm-diff', fx: 'rise', t: 0.5 },
      { do: 'scroll', list: 'list', to: 'm-diff', t: 0.6, with: true },
      { do: 'wait', t: 1.2 },
      // Done.
      { do: 'caption', n: 4 },
      { do: 'show', target: 'm-answer', fx: 'rise' },
      { do: 'scroll', list: 'list', to: 'm-answer', t: 0.6, with: true },
      { do: 'label', name: 'poster' },
      { do: 'set', target: 'dots', vars: { attr: { 'data-on': 'false' } }, with: true },
      { do: 'class', target: 'status', remove: 'is-busy', with: true },
      { do: 'text', target: 'status-text', text: c.done, with: true },
      { do: 'cat', action: 'rest', with: true },
      { do: 'cat', action: 'celebrate', with: true, delay: 0.1 },
      { do: 'zoom', to: 'fit', t: 1.1, delay: 0.4 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.5, with: true },
      { do: 'wait', t: 0.6 },
    ],
  };
}
