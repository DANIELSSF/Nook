import type { SceneDef } from '../types';

interface Copy { typed: string; completed: string; lead: string; path: string }

/**
 * "Escribe a tu manera": a slash opens the command menu and Tab completes it; a file is dragged over the island and its path
 * is written into the message; Enter sends it, whole.
 */
export default function compose(c: Copy): SceneDef {
  return {
    id: 'compose',
    islands: { island: 'open' },
    cursorStart: { x: 690, y: 300 },
    hold: 1.8,
    steps: [
      { do: 'caption', n: 0 },
      { do: 'wait', t: 0.3 },
      { do: 'click', to: { el: 'field', at: [0.3, 0.5] }, press: 'composer' },
      { do: 'class', target: 'composer', add: 'is-focus', with: true, delay: 0.5 },
      { do: 'zoom', to: { el: 'field', at: [0.4, -0.5] }, scale: 1.2, t: 1.1, with: true, delay: 0.3 },
      { do: 'wait', t: 0.25 },
      // A slash opens the menu.
      { do: 'type', target: 'typed', text: c.typed, cps: 4.5 },
      { do: 'show', target: 'slash', fx: 'pop', t: 0.3, with: true, delay: -0.55 },
      { do: 'wait', t: 1.1 },
      { do: 'keys', keys: ['⇥'], t: 0.9 },
      { do: 'text', target: 'typed', text: c.completed, with: true, delay: 0.1 },
      { do: 'hide', target: 'slash', fx: 'fade', t: 0.25, with: true, delay: 0.1 },
      { do: 'wait', t: 0.6 },
      // A file.
      { do: 'caption', n: 1 },
      { do: 'text', target: 'typed', text: '', with: true },
      { do: 'type', target: 'typed', text: c.lead, cps: 12, append: false },
      { do: 'move', to: { x: 640, y: 150 }, t: 0.6, with: true },
      { do: 'show', target: 'filechip', fx: 'pop', t: 0.3, delay: 0.1 },
      { do: 'carry', target: 'filechip', dx: 10, dy: 12 },
      { do: 'zoom', to: 'fit', t: 0.9, with: true },
      { do: 'move', to: { el: 'composer', at: [0.55, 0.45] }, t: 1.3 },
      { do: 'class', target: 'composer', add: 'is-drop', with: true, delay: 0.55 },
      { do: 'wait', t: 0.7 },
      { do: 'label', name: 'poster' },
      { do: 'carry', target: null },
      { do: 'hide', target: 'filechip', fx: 'fade', t: 0.2 },
      { do: 'class', target: 'composer', remove: 'is-drop', with: true },
      { do: 'type', target: 'typed', text: c.path, append: true, cps: 45 },
      { do: 'wait', t: 0.4 },
      // Sent, whole.
      { do: 'caption', n: 2 },
      { do: 'keys', keys: ['↵'], t: 1.0 },
      { do: 'text', target: 'typed', text: '', with: true, delay: 0.1 },
      { do: 'show', target: 'm-user', fx: 'rise', t: 0.45, with: true, delay: 0.1 },
      { do: 'show', target: 'm-tag', fx: 'fade', t: 0.25, with: true, delay: 0.1 },
      { do: 'scroll', list: 'list', to: 'm-user', t: 0.5, with: true, delay: 0.1 },
      { do: 'hide', target: 'm-tag', fx: 'fade', t: 0.3, delay: 0.9 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.5, with: true },
      { do: 'wait', t: 1.0 },
    ],
  };
}
