import type { Step } from './types';
import type { CoatId } from '../cat/render';
import { env } from '../scripts/env';

/** What the script needs to type, show and say (read as JSON from the markup, Film.astro). */
export interface FilmCopy {
  typed: string;
  working: string;
  done: string;
  compose: { typed: string; completed: string; lead: string; path: string };
  colors: string[];
  icons: string[];
  usage: number[];
  greetings: { morning: string; afternoon: string; night: string };
  coats: { id: CoatId; name: string }[];
  chapters: { id: string; name: string }[];
  controls: { play: string; pause: string; replay: string; replayLabel: string; progress: string; position: string; download: string };
}

/** The app's own line for the hour on its home: Buenos días from 6 to 12, Buenas tardes from 13 to 19, Buenas noches the rest. */
const overline = (hour: number, g: FilmCopy['greetings']): string => (hour >= 6 && hour < 13 ? g.morning : hour >= 13 && hour < 20 ? g.afternoon : g.night);

/** Where the wing's cat sits on the strip of a collapsed island, as a fraction of the strip (island.css: 18 + 572 / 2 − 124 of 572). */
const WING = (18 + 572 / 2 - 124) / 572;
/** Rosa, in the editor's order of colors; and Llama, in its order of icons (as in the customize demo). */
const ROSE = 6;
const FLAME = 12;
/** The customize scene's nudge: the row has moved by the time the last tab is taken (see `src/demo/scenes/customize.ts`). */
const NUDGE = -2;
/** How long the sad cat's scene runs (the quit demo's). */
const SAD = 7.4;
/** The island beside a title: the framing most shots come back to. */
const BESIDE = { el: 'island', into: 'side', pad: 28, min: 0.6 } as const;
/** Back to work in another window: the notch and the window under it, beside a title. */
const DESKTOP = { el: '@doc', at: [0.5, 0.3] as [number, number], into: 'side', pad: 96, min: 0.55 } as const;

/** A chapter's steps, written from its own start, put at `start` on the film's clock. */
const from = (start: number, steps: Step[]): Step[] => steps.map((s) => ({ ...s, at: start + (s.at ?? 0) }));

// MARK: The chapters (each from its own 0; its length is where the next one begins)

/** A black screen and a cat in the notch's wing; the screen wakes and the camera pulls back to the laptop. */
const notch = (): Step[] => [
  { do: 'chapter', id: 'notch' },
  { do: 'shot', id: 'main' },
  { do: 'set', target: '@off', vars: { autoAlpha: 1 } },
  { do: 'set', target: '@night', vars: { autoAlpha: 1 } },
  // The cat at the top of the frame, where a notch is, with nothing above it: the laptop's edge stays out of the picture.
  { do: 'cam', aim: { el: 'strip', at: [WING, 0.5], zoom: 3.3, min: 3.4, top: -13, crop: true }, t: 0 },
  // A slow push on the cat, alone in the dark.
  { do: 'cam', aim: { el: 'strip', at: [WING, 0.5], zoom: 3.65, min: 3.8, top: -12, crop: true }, t: 3.2, ease: 'sine.inOut', at: 0.01 },
  { do: 'cat', target: 'cat', act: 'blink', at: 0.6 },
  { do: 'title', id: 'notch', hold: 2.3, at: 0.9 },
  { do: 'cat', target: 'cat', act: 'glance', at: 1.3 },
  // The screen wakes, the light comes up, and the camera pulls back to the laptop, tipped back a little.
  { do: 'tween', target: '@off', vars: { autoAlpha: 0 }, t: 1.3, ease: 'power2.inOut', at: 3.2 },
  { do: 'cam', aim: { el: '@mac', into: 'low', rx: 14, pad: 30 }, t: 2.7, ease: 'power3.inOut', at: 3.3 },
  { do: 'tween', target: '@night', vars: { autoAlpha: 0 }, t: 1.5, ease: 'power1.inOut', at: 4.0 },
  { do: 'tween', target: '@glare', from: { xPercent: -70 }, vars: { xPercent: 70 }, t: 2.4, ease: 'power2.inOut', at: 4.0 },
  { do: 'title', id: 'brand', hold: 1.95, at: 5.1 },
  { do: 'title', id: 'brandLine', hold: 1.35, at: 5.6 },
  { do: 'cam', aim: { el: '@mac', into: 'low', rx: 6, ry: -4, pad: 30, zoom: 1.04 }, t: 1.7, ease: 'sine.inOut', at: 6.0 },
];

/** The greeting (the cat waves and says hello), the home with no tab, and a card that opens Claude Code. */
const home = (c: FilmCopy): Step[] => [
  { do: 'chapter', id: 'home' },
  { do: 'cam', aim: BESIDE, t: 1.6, ease: 'power3.inOut' },
  { do: 'tween', target: '@dim', vars: { autoAlpha: 0.8 }, t: 1.0, at: 0.8 },
  { do: 'show', target: '@scrim', t: 0.35, at: 1.15 },
  { do: 'title', id: 'home', hold: 2.75, at: 1.45 },
  // The pointer comes to the cat, and the island opens on the greeting.
  { do: 'move', to: { el: 'strip', at: [WING, 0.55] }, t: 1.1, at: 0.6 },
  { do: 'island', state: 'open', t: 0.95, at: 1.7 },
  { do: 'cat', target: 'welcome-cat', act: 'wave', at: 2.2 },
  { do: 'show', target: 'welcome-cat-bubble', fx: 'pop', t: 0.35, at: 2.5 },
  { do: 'hide', target: 'welcome-cat-bubble', fx: 'fade', t: 0.3, at: 4.5 },
  { do: 'move', to: 'start', t: 0.9, at: 3.7 },
  { do: 'class', target: 'start', add: 'is-hover', at: 4.45 },
  { do: 'click', press: 'start', at: 4.8 },
  // The home: the camera comes round to it as the words go.
  { do: 'text', target: 'over', text: overline(env.hour, c.greetings), at: 4.9 },
  { do: 'hide', target: 'welcome', fx: 'fade', t: 0.3, at: 4.95 },
  { do: 'show', target: 'home', fx: 'rise', t: 0.5, at: 5.1 },
  { do: 'cam', aim: { el: 'island', pad: 40, min: 0.62 }, t: 1.3, at: 4.9 },
  { do: 'hide', target: '@scrim', t: 0.6, at: 4.9 },
  { do: 'move', to: { el: 'card-0', at: [0.5, 0.5] }, t: 0.9, at: 5.7 },
  { do: 'class', target: 'card-0', add: 'is-hover', at: 6.45 },
  { do: 'click', press: 'card-0', at: 6.8 },
  { do: 'cat', target: 'home-cat', act: 'celebrate', at: 6.9 },
  { do: 'class', target: 'card-0', add: 'is-opening', at: 6.9 },
  { do: 'class', target: ['card-1', 'card-2'], add: 'is-dimmed', at: 6.9 },
  // The home goes, and the island fills with the new tab.
  { do: 'hide', target: 'home', fx: 'fade', t: 0.35, at: 8.15 },
  { do: 'class', target: 'island', remove: 'is-home', at: 8.15 },
  { do: 'show', target: 'tab-0', fx: 'pop', t: 0.4, at: 8.4 },
  { do: 'show', target: 'm-info', fx: 'fade', t: 0.4, at: 8.5 },
];

/** A message, Claude's tools, an edit in red and green, the answer and the cat's cheer; then two more sessions join this one. */
const follow = (c: FilmCopy): Step[] => [
  { do: 'chapter', id: 'follow' },
  { do: 'cam', aim: BESIDE, t: 1.1 },
  { do: 'show', target: '@scrim', t: 0.35, at: 0.6 },
  { do: 'title', id: 'follow', hold: 2.7, at: 0.8 },
  { do: 'click', to: { el: 'field', at: [0.3, 0.5] }, press: 'composer', at: 0.1 },
  { do: 'class', target: 'composer', add: 'is-focus', at: 0.75 },
  { do: 'type', target: 'typed', text: c.typed, cps: 26, at: 1.0 },
  { do: 'class', target: 'send', add: 'is-ready', at: 2.75 },
  { do: 'keys', keys: ['↵'], t: 1.0, at: 2.9 },
  { do: 'class', target: 'send', add: 'is-press', at: 2.95 },
  { do: 'text', target: 'typed', text: '', at: 3.0 },
  { do: 'class', target: 'send', remove: 'is-ready is-press', at: 3.15 },
  { do: 'show', target: 'm-user', fx: 'rise', t: 0.45, at: 3.05 },
  { do: 'show', target: 'm-tag', fx: 'fade', t: 0.25, at: 3.05 },
  { do: 'cat', target: 'cat', act: 'work', at: 3.05 },
  { do: 'set', target: 'dots', vars: { attr: { 'data-on': 'true' } }, at: 3.05 },
  { do: 'class', target: 'status', add: 'is-busy', at: 3.05 },
  { do: 'text', target: 'status-text', text: c.working, at: 3.05 },
  { do: 'hide', target: 'm-tag', fx: 'fade', t: 0.3, at: 3.9 },
  // Claude works: the camera leans into the conversation.
  { do: 'hide', target: '@scrim', t: 0.6, at: 3.5 },
  { do: 'cam', aim: { el: 'convo', at: [0.5, 0.5], pad: 20, min: 0.7 }, t: 1.1, at: 3.5 },
  { do: 'show', target: 'm-tool1', fx: 'rise', t: 0.35, at: 4.0 },
  { do: 'show', target: 'm-out1', fx: 'rise', t: 0.35, at: 4.3 },
  { do: 'show', target: 'm-tool2', fx: 'rise', t: 0.35, at: 4.85 },
  { do: 'scroll', list: 'list', to: 'm-tool2', t: 0.45, at: 4.85 },
  { do: 'show', target: 'm-out2', fx: 'rise', t: 0.35, at: 5.15 },
  { do: 'show', target: 'm-diff', fx: 'rise', t: 0.5, at: 5.7 },
  { do: 'scroll', list: 'list', to: 'm-diff', t: 0.6, at: 5.7 },
  { do: 'show', target: 'm-answer', fx: 'rise', t: 0.4, at: 6.8 },
  { do: 'scroll', list: 'list', to: 'm-answer', t: 0.6, at: 6.8 },
  { do: 'set', target: 'dots', vars: { attr: { 'data-on': 'false' } }, at: 6.8 },
  { do: 'class', target: 'status', remove: 'is-busy', at: 6.8 },
  { do: 'text', target: 'status-text', text: c.done, at: 6.8 },
  { do: 'cat', target: 'cat', act: 'rest', at: 6.8 },
  { do: 'cat', target: 'cat', act: 'celebrate', at: 6.9 },
  // Every session is a tab: two more join this one.
  { do: 'cam', aim: BESIDE, t: 1.0, at: 7.3 },
  { do: 'show', target: '@scrim', t: 0.35, at: 7.75 },
  { do: 'title', id: 'sessions', hold: 1.25, at: 7.95 },
  { do: 'show', target: 'tab-1', fx: 'pop', t: 0.4, at: 7.8 },
  { do: 'show', target: 'tab-2', fx: 'pop', t: 0.4, at: 8.15 },
  { do: 'label', name: 'poster', at: 8.7 },
  { do: 'move', to: { el: 'tab-2', at: [0.4, 0.5] }, t: 0.8, at: 8.7 },
  { do: 'class', target: 'tab-2', add: 'is-hover', at: 9.4 },
  { do: 'click', press: 'tab-2', at: 9.7 },
];

/** The third session, where Claude sent out its agents: their list, one finishing, and the usage card. */
const agents = (c: FilmCopy): Step[] => [
  { do: 'chapter', id: 'agents' },
  { do: 'shot', id: 'agents', fx: 'fade', t: 0.22 },
  { do: 'cat', target: 'cat', act: 'work' },
  { do: 'title', id: 'agents', hold: 2.5, at: 0.6 },
  { do: 'click', to: 'capsule', press: 'capsule', at: 0.1 },
  { do: 'show', target: 'agents', fx: 'pop', t: 0.35, at: 1.15 },
  { do: 'cam', aim: { el: 'island', at: [0.42, 0.62], into: 'side', pad: 10, zoom: 1.12, min: 0.66 }, t: 1.0, at: 1.2 },
  // One finishes.
  { do: 'tween', target: 'ad-1', vars: { backgroundColor: '#51d9ad' }, t: 0.4, at: 2.3 },
  { do: 'text', target: 'ac-1', text: 'terminó', at: 2.4 },
  { do: 'text', target: 'at-1', text: '1:48', at: 2.4 },
  { do: 'tween', target: 'cd-1', vars: { backgroundColor: '#51d9ad' }, t: 0.4, at: 2.3 },
  { do: 'hide', target: 'agents', fx: 'fade', t: 0.3, at: 3.2 },
  // The usage card.
  { do: 'hide', target: '@scrim', t: 0.6, at: 3.2 },
  { do: 'cam', aim: { el: 'island', at: [0.5, 0.6], pad: 30, min: 0.62 }, t: 1.1, at: 3.2 },
  { do: 'click', to: 'chip-usage', press: 'chip-usage', at: 3.25 },
  { do: 'island', state: 'tall', t: 1.0, at: 4.2 },
  { do: 'show', target: 'usage', fx: 'rise', t: 0.5, at: 4.55 },
  ...c.usage.map((pct, i): Step => ({ do: 'tween', target: `meter-${i}`, from: { scaleX: 0 }, vars: { scaleX: pct / 100 }, t: 1.1, ease: 'power3.out', at: 4.7 + i * 0.12 })),
];

/** Back at work in another window: an amber notice, the question in full, and one click to answer it. */
const question = (): Step[] => [
  { do: 'chapter', id: 'question' },
  { do: 'island', state: 'collapsed', t: 0.7, ease: 'power3.inOut' },
  { do: 'tween', target: '@dim', vars: { autoAlpha: 0.12 }, t: 1.2, at: 0.1 },
  { do: 'cam', aim: DESKTOP, t: 1.3 },
  { do: 'show', target: '@scrim', t: 0.35, at: 0.75 },
  { do: 'move', to: { el: '@doc', at: [0.62, 0.66] }, t: 1.1, at: 0.15 },
  { do: 'shot', id: 'question', at: 0.75 },
  { do: 'title', id: 'question', hold: 2.2, at: 1.1 },
  { do: 'island', state: 'peek', t: 0.8, at: 1.3 },
  { do: 'show', target: 'peek', fx: 'drop', t: 0.5, at: 1.5 },
  { do: 'show', target: 'tab-0-q', fx: 'pop', t: 0.3, at: 1.6 },
  { do: 'cat', target: 'cat', act: 'perk', at: 1.5 },
  { do: 'ring', target: 'bell', color: '#fdc860', pulses: 2, at: 1.6 },
  { do: 'move', to: { el: 'peek', at: [0.5, 0.5] }, t: 0.9, at: 2.6 },
  { do: 'click', press: 'peek', at: 3.6 },
  { do: 'hide', target: 'peek', fx: 'fade', t: 0.25, at: 3.7 },
  { do: 'island', state: 'open', t: 0.95, at: 3.7 },
  { do: 'cam', aim: BESIDE, t: 1.1, at: 3.7 },
  { do: 'tween', target: '@dim', vars: { autoAlpha: 0.8 }, t: 1.0, at: 3.7 },
  { do: 'show', target: 'card', fx: 'rise', t: 0.5, at: 4.25 },
  { do: 'title', id: 'answer', hold: 2.5, at: 4.4 },
  { do: 'move', to: { el: 'opt-1', at: [0.45, 0.5] }, t: 0.8, at: 4.9 },
  { do: 'class', target: 'opt-1', add: 'is-hover', at: 5.6 },
  { do: 'click', press: 'opt-1', at: 5.95 },
  { do: 'keys', keys: ['2'], t: 0.9, at: 5.95 },
  { do: 'class', target: 'opt-1', add: 'is-chosen', at: 6.05 },
  { do: 'hide', target: 'card', fx: 'fade', t: 0.35, at: 6.6 },
  { do: 'hide', target: 'tab-0-q', fx: 'pop', t: 0.3, at: 6.6 },
  { do: 'show', target: 'm-answer', fx: 'rise', t: 0.4, at: 6.65 },
  { do: 'show', target: 'm-reply', fx: 'rise', t: 0.4, at: 7.15 },
  { do: 'scroll', list: 'list', to: 'm-reply', t: 0.5, at: 7.15 },
];

/** With the island tucked away: a finished task (mint, a cheer), then a failure (soft red); each rings, and its sound is drawn. */
const alerts = (): Step[] => [
  { do: 'chapter', id: 'alerts' },
  { do: 'island', state: 'collapsed', t: 0.7, ease: 'power3.inOut' },
  { do: 'tween', target: '@dim', vars: { autoAlpha: 0.12 }, t: 1.2, at: 0.1 },
  { do: 'cam', aim: DESKTOP, t: 1.3 },
  { do: 'move', to: { el: '@doc', at: [0.38, 0.72] }, t: 1.0, at: 0.2 },
  { do: 'shot', id: 'alerts', at: 0.75 },
  { do: 'title', id: 'alerts', hold: 2.0, at: 1.0 },
  { do: 'island', state: 'peek', t: 0.8, at: 1.2 },
  { do: 'show', target: 'peek-ok', fx: 'drop', t: 0.45, at: 1.4 },
  { do: 'cat', target: 'cat', act: 'celebrate', at: 1.55 },
  { do: 'ring', target: 'bell-ok', color: '#51d9ad', pulses: 2, at: 1.5 },
  { do: 'hide', target: 'peek-ok', fx: 'fade', t: 0.25, at: 2.9 },
  { do: 'island', state: 'collapsed', t: 0.75, at: 2.9 },
  { do: 'hide', target: 'dots', fx: 'fade', t: 0.2, at: 2.9 },
  { do: 'show', target: 'badge', fx: 'pop', t: 0.3, at: 3.2 },
  { do: 'title', id: 'sound', hold: 2.9, at: 3.6 },
  { do: 'island', state: 'peek', t: 0.8, at: 3.8 },
  { do: 'show', target: 'peek-fail', fx: 'drop', t: 0.45, at: 4.0 },
  { do: 'cat', target: 'cat', act: 'perk', at: 4.15 },
  { do: 'ring', target: 'bell-fail', color: '#f86a67', pulses: 3, at: 4.1 },
  // A click on the notice opens that tab.
  { do: 'move', to: { el: 'peek-fail', at: [0.5, 0.5] }, t: 0.9, at: 5.0 },
  { do: 'click', press: 'peek-fail', at: 6.0 },
  { do: 'hide', target: 'peek-fail', fx: 'fade', t: 0.25, at: 6.1 },
  { do: 'hide', target: 'badge', fx: 'fade', t: 0.2, at: 6.1 },
  { do: 'island', state: 'open', t: 0.95, at: 6.1 },
  { do: 'cam', aim: BESIDE, t: 1.1, at: 6.1 },
  { do: 'tween', target: '@dim', vars: { autoAlpha: 0.8 }, t: 1.0, at: 6.1 },
];

/** A slash and Tab complete a command; a file dropped on the island writes its path; Enter sends the message whole. */
const compose = (c: FilmCopy): Step[] => [
  { do: 'chapter', id: 'compose' },
  { do: 'shot', id: 'compose', fx: 'fade', t: 0.35 },
  { do: 'title', id: 'compose', hold: 3.0, at: 0.3 },
  { do: 'click', to: { el: 'field', at: [0.3, 0.5] }, press: 'composer', at: 0.1 },
  { do: 'class', target: 'composer', add: 'is-focus', at: 0.8 },
  { do: 'cam', aim: { el: 'composer', at: [0.5, 0.1], into: 'side', pad: 70, min: 0.66 }, t: 1.0, at: 0.6 },
  { do: 'type', target: 'typed', text: c.compose.typed, cps: 4.5, at: 1.1 },
  { do: 'show', target: 'slash', fx: 'pop', t: 0.3, at: 1.5 },
  { do: 'keys', keys: ['⇥'], t: 0.9, at: 2.3 },
  { do: 'text', target: 'typed', text: c.compose.completed, at: 2.4 },
  { do: 'hide', target: 'slash', fx: 'fade', t: 0.25, at: 2.4 },
  // A file, dropped on the island: its path is written into the message.
  { do: 'text', target: 'typed', text: '', at: 2.9 },
  { do: 'type', target: 'typed', text: c.compose.lead, cps: 12, at: 2.9 },
  { do: 'cam', aim: { el: 'island', at: [0.55, 0.55], into: 'side', pad: 40, min: 0.6 }, t: 1.0, at: 3.0 },
  { do: 'move', to: { x: 1150, y: 170 }, t: 0.7, at: 3.0 },
  { do: 'show', target: '@filechip', fx: 'pop', t: 0.3, at: 3.75 },
  { do: 'carry', target: '@filechip', dx: 10, dy: 12, at: 3.75 },
  { do: 'move', to: { el: 'composer', at: [0.55, 0.45] }, t: 1.2, at: 3.9 },
  { do: 'class', target: 'composer', add: 'is-drop', at: 4.55 },
  { do: 'carry', target: null, at: 5.3 },
  { do: 'hide', target: '@filechip', fx: 'fade', t: 0.2, at: 5.3 },
  { do: 'class', target: 'composer', remove: 'is-drop', at: 5.3 },
  { do: 'type', target: 'typed', text: c.compose.path, append: true, cps: 45, at: 5.35 },
  { do: 'keys', keys: ['↵'], t: 1.0, at: 6.55 },
  { do: 'text', target: 'typed', text: '', at: 6.65 },
  { do: 'show', target: 'm-user', fx: 'rise', t: 0.45, at: 6.65 },
  { do: 'show', target: 'm-tag', fx: 'fade', t: 0.25, at: 6.65 },
  { do: 'scroll', list: 'list', to: 'm-user', t: 0.5, at: 6.65 },
  { do: 'hide', target: 'm-tag', fx: 'fade', t: 0.3, at: 7.3 },
];

/** The tab's color (its voice) and an icon that moves while its AI works; a tab dragged into place; the island's light theme. */
const customize = (c: FilmCopy): Step[] => [
  { do: 'chapter', id: 'customize' },
  { do: 'shot', id: 'customize', fx: 'fade', t: 0.35 },
  { do: 'cam', aim: { el: 'editor', at: [0.62, 0.42], into: 'side', pad: 64, min: 0.6 }, t: 1.0 },
  { do: 'title', id: 'customize', hold: 2.8, at: 0.4 },
  { do: 'click', to: { el: 'tab-0', at: [0.4, 0.5] }, kind: 'right', press: 'tab-0', at: 0.1 },
  { do: 'show', target: 'menu', fx: 'pop', t: 0.25, at: 0.95 },
  { do: 'move', to: { el: 'menu-0', at: [0.4, 0.5] }, t: 0.45, at: 1.2 },
  { do: 'class', target: 'menu-0', add: 'is-hover', at: 1.55 },
  { do: 'click', press: 'menu-0', at: 1.75 },
  { do: 'hide', target: 'menu', fx: 'fade', t: 0.2, at: 1.85 },
  { do: 'show', target: 'editor', fx: 'pop', t: 0.35, at: 1.95 },
  { do: 'move', to: `sw-${ROSE}`, t: 0.6, at: 2.35 },
  { do: 'class', target: `sw-${ROSE}`, add: 'is-hover', at: 2.85 },
  { do: 'click', press: `sw-${ROSE}`, at: 3.0 },
  { do: 'class', target: 'sw-0', remove: 'is-on', at: 3.05 },
  { do: 'class', target: `sw-${ROSE}`, add: 'is-on', remove: 'is-hover', at: 3.05 },
  { do: 'text', target: 'color-name', text: c.colors[ROSE] ?? '', at: 3.05 },
  { do: 'class', target: ['island', 'editor', 'tab-0'], remove: 'tc-mint', add: 'tc-rose', at: 3.15 },
  { do: 'move', to: `ic-${FLAME}`, t: 0.55, at: 3.5 },
  { do: 'class', target: `ic-${FLAME}`, add: 'is-hover', at: 3.95 },
  { do: 'class', target: `ic-${FLAME}-svg`, add: 'is-moving', at: 3.95 },
  { do: 'click', press: `ic-${FLAME}`, at: 4.1 },
  { do: 'class', target: 'ic-0', remove: 'is-on', at: 4.15 },
  { do: 'class', target: `ic-${FLAME}`, add: 'is-on', at: 4.15 },
  { do: 'text', target: 'icon-name', text: c.icons[FLAME] ?? '', at: 4.15 },
  { do: 'class', target: ['pv-dot', 'tab-0-icon-dot'], remove: 'is-on', at: 4.15 },
  { do: 'class', target: ['pv-flame', 'tab-0-icon-flame'], add: 'is-on is-moving', at: 4.15 },
  { do: 'move', to: 'done', t: 0.6, at: 4.55 },
  { do: 'class', target: `ic-${FLAME}`, remove: 'is-hover', at: 4.65 },
  { do: 'class', target: 'done', add: 'is-hover', at: 5.05 },
  { do: 'click', press: 'done', at: 5.2 },
  { do: 'hide', target: 'editor', fx: 'fade', t: 0.3, at: 5.35 },
  // Reorder: the last tab is taken to the front, and the others give way.
  { do: 'cam', aim: { el: 'tabs', at: [0.32, 0.5], into: 'side', pad: 36, min: 0.9 }, t: 0.8, at: 5.5 },
  { do: 'title', id: 'reorder', hold: 2.0, at: 5.7 },
  { do: 'move', to: { el: 'tab-2', at: [0.45, 0.5], dx: NUDGE }, t: 0.75, at: 5.6 },
  { do: 'class', target: 'tab-2', add: 'is-hover', at: 6.3 },
  { do: 'drag', target: 'tab-2', over: ['tab-1', 'tab-0'], t: 0.9, at: 6.55 },
  { do: 'class', target: 'tab-2', remove: 'is-hover', at: 7.9 },
  // Settings, under the island: the light theme.
  { do: 'cam', aim: { el: 'island', at: [0.5, 0.92], into: 'side', pad: 40, min: 0.6 }, t: 0.8, at: 8.2 },
  { do: 'title', id: 'theme', hold: 2.7, at: 8.4 },
  { do: 'click', to: { el: 'more', at: [0.4, 0.5] }, press: 'more', at: 8.25 },
  { do: 'show', target: 'menu2', fx: 'pop', t: 0.25, at: 9.25 },
  { do: 'move', to: { el: 'menu2-0', at: [0.4, 0.5] }, t: 0.4, at: 9.5 },
  { do: 'class', target: 'menu2-0', add: 'is-hover', at: 9.8 },
  { do: 'click', press: 'menu2-0', at: 10.0 },
  { do: 'hide', target: 'menu2', fx: 'fade', t: 0.2, at: 10.1 },
  { do: 'show', target: 'settings', fx: 'drop', t: 0.4, at: 10.2 },
  { do: 'move', to: 'theme-1', t: 0.6, at: 10.6 },
  { do: 'click', press: 'theme-1', at: 11.2 },
  { do: 'class', target: 'theme-0', remove: 'is-on', at: 11.3 },
  { do: 'class', target: 'theme-1', add: 'is-on', at: 11.3 },
  { do: 'class', target: 'skin', add: 'is-paper', at: 11.35 },
  { do: 'hide', target: '@cursor', fx: 'fade', t: 0.3, at: 12.4 },
  { do: 'hide', target: '@scrim', t: 0.4, at: 12.4 },
];

/** The cat's close-up on the app's black stage: it breathes and blinks, waves, and tries on its coats. */
const cat = (c: FilmCopy): Step[] => {
  const coats: CoatId[] = c.coats.map((k) => k.id);
  const order = [...coats.slice(1), coats[0]!];
  return [
    { do: 'chapter', id: 'cat' },
    { do: 'shot', id: 'studio' },
    { do: 'title', id: 'breathe', hold: 1.8, at: 0.5 },
    { do: 'cat', target: '@studio-cat', act: 'blink', at: 1.1 },
    { do: 'cat', target: '@studio-cat', act: 'blink', at: 1.9 },
    { do: 'cat', target: '@studio-cat', act: 'wave', at: 2.5 },
    { do: 'title', id: 'wave', hold: 2.2, at: 2.9 },
    { do: 'title', id: 'coats', hold: 2.2, at: 5.7 },
    { do: 'show', target: '@coats', fx: 'rise', t: 0.35, at: 5.9 },
    ...order.flatMap((id, i): Step[] => {
      const at = 6.0 + i * 0.45;
      const prev = i === 0 ? coats[0]! : order[i - 1]!;
      return [
        { do: 'dress', target: '@studio-cat', coat: id, at },
        { do: 'class', target: `@coat-${prev}`, remove: 'is-on', at },
        { do: 'class', target: `@coat-${id}`, add: 'is-on', at },
      ];
    }),
    { do: 'hide', target: '@coats', fx: 'fade', t: 0.3, at: 8.2 },
  ];
};

/** ⌘Q, and the question before quitting with the sad cat; «Quedarme» puts everything back. */
const quit = (): Step[] => [
  { do: 'chapter', id: 'quit' },
  { do: 'shot', id: 'quit' },
  { do: 'cam', aim: BESIDE, t: 0 },
  { do: 'show', target: '@scrim', t: 0.01 },
  { do: 'title', id: 'quit', hold: 3.0, at: 0.4 },
  { do: 'keys', keys: ['⌘', 'Q'], t: 1.0, at: 0.5 },
  { do: 'show', target: 'scrim', fx: 'fade', t: 0.3, at: 1.3 },
  { do: 'show', target: 'quit', fx: 'pop', t: 0.5, at: 1.36 },
  { do: 'sad', target: 'sad-cat', t: SAD, at: 1.3 },
  { do: 'move', to: { el: 'stay', at: [0.5, 0.5] }, t: 0.9, at: 3.6 },
  { do: 'class', target: 'stay', add: 'is-hover', at: 4.35 },
  { do: 'click', press: 'stay', at: 4.8 },
  { do: 'hide', target: 'quit', fx: 'pop', t: 0.28, at: 4.94 },
  { do: 'hide', target: 'scrim', fx: 'fade', t: 0.32, at: 4.94 },
];

/** The island goes back into the notch, the screen dims, and the cat lies down and curls up to sleep. */
const end = (): Step[] => [
  { do: 'chapter', id: 'end' },
  { do: 'hide', target: '@cursor', fx: 'fade', t: 0.4 },
  { do: 'hide', target: '@scrim', t: 0.5 },
  { do: 'island', state: 'collapsed', t: 0.8, ease: 'power3.inOut' },
  { do: 'cam', aim: { el: '@mac', at: [0.5, 0.22], into: 'low', zoom: 2.0, pad: 0, rx: 4 }, t: 2.4, ease: 'power3.inOut', at: 0.2 },
  { do: 'tween', target: '@dim', vars: { autoAlpha: 0 }, t: 1.0, at: 0.2 },
  { do: 'tween', target: '@off', vars: { autoAlpha: 0.55 }, t: 2.2, ease: 'power1.inOut', at: 0.8 },
  { do: 'cat', target: 'cat', act: 'nap', at: 0.9 },
  { do: 'title', id: 'end', hold: 0, at: 1.8 },
  { do: 'title', id: 'endLine', hold: 0, at: 2.4 },
  { do: 'wait', t: 3.4, at: 2.4 },
];

/**
 * The film, chapter by chapter: each chapter is written from its own start and placed where the one before it ends. The chapters are
 * the progress bar's marks, so each begins where the take can be joined cleanly, on a cut or a camera move, with the cats sitting.
 *
 *   0:00.0  El notch          a black screen and a cat in the notch's wing; the screen wakes and the camera pulls back to the laptop.
 *   0:07.6  Para empezar      the greeting (the cat waves), the home, and a card that opens Claude Code.
 *   0:16.6  Sigue su trabajo  a message, Claude's tools, an edit in red and green, the answer, the cat's cheer; two more sessions join.
 *   0:26.6  Subagentes        the capsule's list of agents, one finishing, and the usage card.
 *   0:33.0  Preguntas         an amber notice over another window, the question card, an answer.
 *   0:41.2  Avisos            a finished task and a failure, each with its bell and its sound.
 *   0:48.8  Escribe           a slash command, a file dropped on the island, a message sent whole.
 *   0:56.2  A tu manera       a color, an icon that moves, a tab dragged into place, the light theme.
 *   1:09.0  El gatito         the cat's close-up: it breathes and blinks, waves, and changes coat.
 *   1:17.6  Antes de salir    ⌘Q and the sad cat; «Quedarme».
 *   1:23.4  Buenas noches     the island back in the notch, where the cat falls asleep; the film ends at 1:29.6.
 */
export function script(c: FilmCopy): Step[] {
  const chapters: [number, Step[]][] = [
    [7.6, notch()],
    [9.0, home(c)],
    [10.0, follow(c)],
    [6.4, agents(c)],
    [8.2, question()],
    [7.6, alerts()],
    [7.4, compose(c)],
    [12.8, customize(c)],
    [8.6, cat(c)],
    [5.8, quit()],
    [0, end()],
  ];
  let start = 0;
  return chapters.flatMap(([length, steps]) => { const placed = from(start, steps); start += length; return placed; });
}
