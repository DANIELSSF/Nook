import { CatActor, runCat, type GestureKind, type Personality } from '../cat/actor';
import type { AccessoryId, CoatId, Look } from '../cat/render';
import { isNight } from '../cat/night';
import { slumber, wakeButton } from '../cat/slumber';
import { env } from './env';

interface Say { mew: string[]; cheer: string[]; wake: string[]; woke: string[]; light: string[]; sleepy: string[]; night: string; morning: string; day: string; evening: string; late: string }

/** A line the cat says, as a small bubble over it. Screen readers get it as a polite status. */
export function makeBubble(el: HTMLElement): (text: string, ms?: number) => void {
  let timer = 0;
  return (text, ms = 2400) => {
    el.textContent = text;
    el.classList.add('is-on');
    window.clearTimeout(timer);
    timer = window.setTimeout(() => el.classList.remove('is-on'), ms);
  };
}

const pick = (list: string[]): string => list[Math.floor(Math.random() * list.length)] ?? '';

/** The cat's own stage: it lives here with a full set of gestures, and the controls change who it is. */
export function initPersonality(root: HTMLElement): void {
  const strings = JSON.parse(root.dataset['strings'] ?? '{}') as { say: Say; wakeLabel: string };
  const say = strings.say;
  const svg = root.querySelector<SVGSVGElement>('[data-cat-stage-cat] svg.cat');
  const stage = root.querySelector<HTMLElement>('[data-cat-stage]');
  const bubbleEl = root.querySelector<HTMLElement>('[data-bubble]');
  if (!svg || !stage || !bubbleEl) return;
  const bubble = makeBubble(bubbleEl);
  let look: Look = { coat: 'snow', accessory: 'none' };
  const actor = new CatActor(svg, {
    look, pointer: true, activity: 1.15, hop: 5, sleeps: true,
    onSay: (kind) => bubble(kind === 'cheer' ? pick(say.cheer) : kind === 'wake' ? pick(say.wake) : kind === 'woke' ? pick(say.woke) : kind === 'light' ? pick(say.light) : kind === 'sleepy' ? pick(say.sleepy) : pick(say.mew)),
  });
  runCat(actor, stage);

  // Say hello once, in the voice of the hour. A cat that is asleep says nothing (the hint says it sleeps), and when it is woken what
  // it says is the waking; the hour's greeting is for a cat that is up.
  const night = isNight(env.hour);
  let greeted = false;
  const io = new IntersectionObserver((entries) => {
    if (greeted || !entries.some((e) => e.isIntersecting)) return;
    greeted = true;
    io.disconnect();
    if (slumber.asleep) return;
    window.setTimeout(() => {
      if (actor.drowsy) return;
      // The hour's words follow the app's own greeting: tardes until 20:00, noches after it, and the sleepy line once the night's sleep begins.
      bubble(say[night ? 'night' : env.dayPart === 'morning' ? 'morning' : env.dayPart === 'evening' ? (env.hour >= 20 ? 'late' : 'evening') : 'day'], 3200);
    }, 900);
    if (!env.reduced && env.dayPart === 'morning') window.setTimeout(() => actor.start('stretch'), 3600);
    if (!env.reduced && night) window.setTimeout(() => actor.start('yawn'), 3600);
  }, { threshold: 0.6 });
  io.observe(stage);

  const catEl = root.querySelector<HTMLElement>('[data-cat-stage-cat]');
  catEl?.addEventListener('pointerenter', () => actor.setHover(true));
  catEl?.addEventListener('pointerleave', () => actor.setHover(false));
  catEl?.addEventListener('click', () => actor.poke());
  catEl?.setAttribute('tabindex', '0');
  catEl?.setAttribute('role', 'button');
  catEl?.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); actor.poke(); } });
  // While it sleeps the same button is how a keyboard wakes it.
  if (catEl) wakeButton(catEl, strings.wakeLabel);

  // Gestures: with motion reduced there is nothing for them to do, so they are switched off (the note beside them says why).
  const gestureButtons = root.querySelectorAll<HTMLButtonElement>('[data-gesture]');
  const syncGestures = () => gestureButtons.forEach((b) => { b.disabled = env.reduced; });
  syncGestures();
  env.on('motion', syncGestures);
  gestureButtons.forEach((b) => b.addEventListener('click', () => {
    if (env.reduced) return;
    const g = b.dataset['gesture'] as string;
    const go = () => { if (g === 'celebrate') actor.celebrate(); else actor.start(g as GestureKind); };
    // A sleeper is woken first (slowly, as always) and does what was asked once it is up.
    if (actor.drowsy) { actor.whenAwake(go); slumber.wake('touch'); actor.wake('touch'); } else go();
  }));

  // Who it is: carácter, coat, accessory.
  const radios = (attr: string, apply: (value: string) => void) => {
    const group = root.querySelectorAll<HTMLButtonElement>(`[data-${attr}]`);
    group.forEach((b) => b.addEventListener('click', () => {
      group.forEach((o) => o.setAttribute('aria-checked', String(o === b)));
      apply(b.dataset[attr] as string);
    }));
    // Arrow keys move through a radio group, as they should.
    group.forEach((b, i) => b.addEventListener('keydown', (e) => {
      if (!['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp'].includes(e.key)) return;
      e.preventDefault();
      const next = group[(i + (e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : group.length - 1)) % group.length] as HTMLButtonElement;
      next.focus(); next.click();
    }));
  };
  // Whoever the visitor picks is who the cat is, whatever the hour.
  radios('character', (v) => { actor.setNightLook(false); actor.setPersonality(v as Personality); });
  radios('coat', (v) => { look = { ...look, coat: v as CoatId }; actor.setLook(look); });
  radios('accessory', (v) => { look = { ...look, accessory: v as AccessoryId }; actor.setLook(look); });
}
