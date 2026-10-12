import type { SceneDef } from '../types';
import { env } from '../../scripts/env';

interface Copy { greetings: { morning: string; afternoon: string; night: string } }

/** The app's own line for the hour: Buenos días from 6 to 12, Buenas tardes from 13 to 19, Buenas noches the rest of the day. */
const overline = (hour: number, g: Copy['greetings']): string => (hour >= 6 && hour < 13 ? g.morning : hour >= 13 && hour < 20 ? g.afternoon : g.night);

/**
 * "Para empezar": the first time Nook runs the cat waves and says who it is and what it does; «Empezar» leaves the home, which is what
 * the island shows with no tab: the cat on its stage (it looks where the cursor goes), a line for the hour and three cards. A card
 * opens a session (the cat hops, the card shows it is on its way) and the island fills with that session's tab.
 */
export default function home(c: Copy): SceneDef {
  return {
    id: 'home',
    islands: { island: 'open' },
    cursorStart: { x: 590, y: 360 },
    hold: 1.8,
    steps: [
      { do: 'caption', n: 0 },
      // The greeting: the cat waves and says hello; the cursor goes to «Empezar» while it does.
      { do: 'cat', action: 'wave', target: 'welcome-cat', at: 0.5 },
      { do: 'show', target: 'welcome-cat-bubble', fx: 'pop', t: 0.35, at: 0.9 },
      { do: 'hide', target: 'welcome-cat-bubble', fx: 'fade', t: 0.3, at: 4.0 },
      { do: 'move', to: 'start', t: 1.1, at: 2.7 },
      { do: 'class', target: 'start', add: 'is-hover', at: 3.65 },
      { do: 'click', press: 'start', at: 4.0 },
      // The home.
      { do: 'text', target: 'over', text: overline(env.hour, c.greetings), with: true },
      { do: 'hide', target: 'welcome', fx: 'fade', t: 0.3, with: true, delay: 0.12 },
      { do: 'caption', n: 1, with: true, delay: 0.2 },
      { do: 'show', target: 'home', fx: 'rise', t: 0.5, with: true, delay: 0.3 },
      { do: 'wait', t: 1.1 },
      { do: 'label', name: 'poster' },
      // The cursor goes to the first card, and the cat looks at it.
      { do: 'move', to: { el: 'card-0', at: [0.5, 0.5] }, t: 1.0 },
      { do: 'class', target: 'card-0', add: 'is-hover', with: true, delay: 0.85 },
      { do: 'wait', t: 0.45 },
      // «Claude Code»: the cat hops, the card shows it is on its way.
      { do: 'caption', n: 2 },
      { do: 'click', press: 'card-0' },
      { do: 'cat', action: 'celebrate', target: 'home-cat', with: true, delay: 0.1 },
      { do: 'class', target: 'card-0', add: 'is-opening', with: true, delay: 0.1 },
      { do: 'class', target: ['card-1', 'card-2'], add: 'is-dimmed', with: true, delay: 0.1 },
      { do: 'wait', t: 1.3 },
      // The home goes, and the island fills with the new tab.
      { do: 'hide', target: 'home', fx: 'fade', t: 0.35 },
      { do: 'class', target: 'island', remove: 'is-home', with: true },
      { do: 'show', target: 'tab-0', fx: 'pop', t: 0.4, with: true, delay: 0.25 },
      { do: 'hide', target: '@cursor', fx: 'fade', t: 0.4, with: true, delay: 0.3 },
      { do: 'wait', t: 1.0 },
    ],
  };
}
