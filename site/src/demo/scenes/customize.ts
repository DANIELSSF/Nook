import type { SceneDef } from '../types';

interface Copy { typed: string; colors: string[]; icons: string[] }

/** Rosa, in the editor's order of colors; and Llama, in its order of icons. */
const COLOR = 6;
const ICON = 12;
/** How far the row has moved by then: the shorter name and the slashed speaker leave the first tab about 12 px narrower. */
const NUDGE = -12;

/**
 * "A tu manera": a right click on a tab, "rename and change color", a new name, a color (the user's voice changes with it), an icon
 * that moves while its AI works, and the tab's alert sound switched off (a slashed speaker follows its name); then a tab dragged
 * into its neighbour's place, as in a browser; then Settings, where the island's theme goes from dark to paper (the app's light
 * theme) and back to the system's.
 */
export default function customize(c: Copy): SceneDef {
  const sw = `sw-${COLOR}`;
  const ic = `ic-${ICON}`;
  return {
    id: 'customize',
    islands: { island: 'open' },
    cursorStart: { x: 380, y: 360 },
    hold: 1.4,
    steps: [
      { do: 'caption', n: 0 },
      { do: 'wait', t: 0.3 },
      { do: 'click', to: { el: 'tab-0', at: [0.4, 0.5] }, kind: 'right', press: 'tab-0' },
      { do: 'show', target: 'menu', fx: 'pop', t: 0.25, with: true, delay: 0.1 },
      { do: 'wait', t: 0.35 },
      { do: 'move', to: { el: 'menu-0', at: [0.4, 0.5] }, t: 0.5 },
      { do: 'class', target: 'menu-0', add: 'is-hover', with: true, delay: 0.4 },
      { do: 'wait', t: 0.3 },
      { do: 'click', press: 'menu-0' },
      { do: 'hide', target: 'menu', fx: 'fade', t: 0.2, with: true, delay: 0.12 },
      { do: 'show', target: 'editor', fx: 'pop', t: 0.35, with: true, delay: 0.2 },
      { do: 'caption', n: 1, with: true, delay: 0.3 },
      { do: 'zoom', to: { el: 'editor', at: [0.5, 0.55] }, scale: 1.1, t: 1.0, with: true, delay: 0.25 },
      { do: 'wait', t: 0.45 },
      // A name.
      { do: 'text', target: 'name-field', text: '' },
      { do: 'type', target: 'name-field', text: c.typed, cps: 11 },
      { do: 'text', target: 'tab-0-name', text: c.typed },
      { do: 'wait', t: 0.3 },
      // A color: the voice of the tab, so the island leans toward it.
      { do: 'move', to: sw, t: 0.65 },
      { do: 'class', target: sw, add: 'is-hover', with: true, delay: 0.55 },
      { do: 'click', press: sw },
      { do: 'class', target: 'sw-0', remove: 'is-on', with: true },
      { do: 'class', target: sw, add: 'is-on', remove: 'is-hover', with: true },
      { do: 'text', target: 'color-name', text: c.colors[COLOR] ?? '', with: true },
      { do: 'class', target: ['island', 'editor', 'tab-0'], remove: 'tc-mint', add: 'tc-rose', with: true, delay: 0.1 },
      { do: 'wait', t: 0.5 },
      // An icon, which moves while the AI of the tab works.
      { do: 'caption', n: 2 },
      { do: 'move', to: ic, t: 0.6 },
      { do: 'class', target: ic, add: 'is-hover', with: true, delay: 0.5 },
      { do: 'class', target: `${ic}-svg`, add: 'is-moving', with: true, delay: 0.5 },
      { do: 'click', press: ic },
      { do: 'class', target: 'ic-0', remove: 'is-on', with: true },
      { do: 'class', target: ic, add: 'is-on', with: true },
      { do: 'text', target: 'icon-name', text: c.icons[ICON] ?? '', with: true },
      { do: 'class', target: ['pv-dot', 'tab-0-icon-dot'], remove: 'is-on', with: true },
      { do: 'class', target: ['pv-flame', 'tab-0-icon-flame'], add: 'is-on is-moving', with: true },
      { do: 'wait', t: 0.6 },
      // The tab's alert sound: the switch goes off and the speaker is slashed.
      { do: 'move', to: 'sound-switch', t: 0.65 },
      { do: 'class', target: ic, remove: 'is-hover', with: true, delay: 0.1 },
      { do: 'click', press: 'sound-switch' },
      { do: 'class', target: 'sound-switch', remove: 'is-on', with: true },
      { do: 'class', target: 'sound-row', add: 'is-muted', with: true },
      { do: 'wait', t: 0.8 },
      { do: 'label', name: 'poster' },
      // Done: the editor closes and the tab carries the slashed speaker.
      { do: 'move', to: 'done', t: 0.7 },
      { do: 'class', target: 'done', add: 'is-hover', with: true, delay: 0.6 },
      { do: 'click', press: 'done' },
      { do: 'hide', target: 'editor', fx: 'fade', t: 0.3, with: true, delay: 0.15 },
      { do: 'class', target: 'tab-0-mute', add: 'is-on', with: true, delay: 0.3 },
      { do: 'zoom', to: 'fit', t: 1.0, with: true, delay: 0.2 },
      { do: 'wait', t: 0.45 },
      // Reorder: the cursor takes the last tab and puts it in front of the others, which give way. (The new name and the slashed speaker have
      // moved the tabs a little from where the layout put them when the script was measured, so the first target is nudged by that.)
      { do: 'caption', n: 3 },
      { do: 'zoom', to: { el: 'tabs', at: [0.3, 0.5] }, scale: 1.3, t: 0.9 },
      { do: 'move', to: { el: 'tab-2', at: [0.45, 0.5], dx: NUDGE }, t: 0.85, with: true, delay: 0.25 },
      { do: 'class', target: 'tab-2', add: 'is-hover', with: true, delay: 0.7 },
      { do: 'wait', t: 0.15 },
      { do: 'drag', target: 'tab-2', over: ['tab-1', 'tab-0'], t: 0.95 },
      { do: 'class', target: 'tab-2', remove: 'is-hover', with: true, delay: 0.2 },
      { do: 'wait', t: 0.35 },
      // Settings, under the island: "…", "Ajustes…".
      { do: 'caption', n: 4 },
      { do: 'zoom', to: 'fit', t: 0.9 },
      { do: 'click', to: { el: 'more', at: [0.4, 0.5] }, press: 'more', with: true, delay: 0.1 },
      { do: 'show', target: 'menu2', fx: 'pop', t: 0.25, with: true, delay: 0.1 },
      { do: 'wait', t: 0.3 },
      { do: 'move', to: { el: 'menu2-0', at: [0.4, 0.5] }, t: 0.45 },
      { do: 'class', target: 'menu2-0', add: 'is-hover', with: true, delay: 0.35 },
      { do: 'wait', t: 0.25 },
      { do: 'click', press: 'menu2-0' },
      { do: 'hide', target: 'menu2', fx: 'fade', t: 0.2, with: true, delay: 0.12 },
      { do: 'show', target: 'settings', fx: 'drop', t: 0.4, with: true, delay: 0.2 },
      { do: 'wait', t: 0.7 },
      // Claro: the body of the island turns to paper inside the black shell; the card follows.
      { do: 'move', to: 'theme-1', t: 0.7 },
      { do: 'click', press: 'theme-1' },
      { do: 'class', target: 'theme-0', remove: 'is-on', with: true },
      { do: 'class', target: 'theme-1', add: 'is-on', with: true },
      { do: 'class', target: 'skin', add: 'is-paper', with: true, delay: 0.05 },
      { do: 'wait', t: 1.7 },
      // Sistema: whatever macOS is (dark here).
      { do: 'move', to: 'theme-0', t: 0.7 },
      { do: 'click', press: 'theme-0' },
      { do: 'class', target: 'theme-1', remove: 'is-on', with: true },
      { do: 'class', target: 'theme-0', add: 'is-on', with: true },
      { do: 'class', target: 'skin', remove: 'is-paper', with: true, delay: 0.05 },
      { do: 'wait', t: 0.8 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.4 },
      { do: 'wait', t: 0.4 },
    ],
  };
}
