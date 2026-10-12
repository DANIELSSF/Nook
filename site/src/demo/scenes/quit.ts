import type { SceneDef } from '../types';

/** How long the sad cat's scene runs: the entrance, a tear, a long blink and a sigh, and a second tear as it ends. */
const SAD = 7.4;

/**
 * "Antes de salir": ⌘Q, and the island dims while a card comes up with the sad cat (it droops as the card appears, a tear runs down its
 * cheek, it blinks long and sighs); the cursor goes to «Quedarme», the default, and everything is as it was. The cat's scene is the
 * app's own, played by the `pose` step.
 */
export default function quit(_c: unknown): SceneDef {
  return {
    id: 'quit',
    islands: { island: 'open' },
    cursorStart: { x: 560, y: 350 },
    hold: 1.6,
    steps: [
      { do: 'caption', n: 0 },
      { do: 'wait', t: 1.0 },
      { do: 'keys', keys: ['⌘', 'Q'], t: 1.1 },
      { do: 'wait', t: 0.45 },
      // The island dims, the card springs up and the cat droops.
      { do: 'show', target: 'scrim', fx: 'fade', t: 0.3 },
      { do: 'show', target: 'quit', fx: 'pop', t: 0.5, with: true, delay: 0.06 },
      { do: 'pose', target: 'sad-cat', scene: 'sad', t: SAD, with: true },
      { do: 'caption', n: 1, with: true, delay: 0.5 },
      { do: 'wait', t: 1.5 },
      { do: 'label', name: 'poster' },
      { do: 'wait', t: 1.7 },
      // «Quedarme» is the default: Enter and Esc mean it too.
      { do: 'caption', n: 2 },
      { do: 'move', to: { el: 'stay', at: [0.5, 0.5] }, t: 0.95 },
      { do: 'class', target: 'stay', add: 'is-hover', with: true, delay: 0.8 },
      { do: 'wait', t: 0.4 },
      { do: 'click', press: 'stay' },
      { do: 'hide', target: 'quit', fx: 'pop', t: 0.28, with: true, delay: 0.14 },
      { do: 'hide', target: 'scrim', fx: 'fade', t: 0.32, with: true, delay: 0.14 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.4, delay: 0.5 },
      { do: 'wait', t: 0.4 },
    ],
  };
}
