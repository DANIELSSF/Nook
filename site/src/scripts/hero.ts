import { gsap } from 'gsap';
import { IslandController } from '../demo/island';
import { planTyping, typedCount } from '../demo/typing';
import { CatActor, runCat } from '../cat/actor';
import { wakeButton } from '../cat/slumber';
import { env } from './env';

/**
 * The hero's island is the real thing in HTML: it opens from the notch, a message is typed and answered, and the cat does what
 * it does. Afterwards it is yours: the arrow folds it back into the notch, the cat or the notch opens it again, and the cat
 * looks at your pointer.
 */
export function initHero(root: HTMLElement): void {
  const island = root.querySelector<HTMLElement>('[data-island]');
  if (!island) return;
  const ctrl = new IslandController(island);
  const content = island.querySelector<HTMLElement>('.island__content');
  const q = <T extends HTMLElement = HTMLElement>(name: string) => island.querySelector<T>(`[data-t="${name}"]`);
  const hint = root.querySelector<HTMLElement>('[data-hero-hint]');
  const say = hint ? JSON.parse(hint.dataset['say'] ?? '{}') as { mew?: string[]; cheer?: string[]; wake?: string[]; woke?: string[]; light?: string[]; sleepy?: string[] } : {};
  const hintHTML = hint?.innerHTML ?? '';
  let hintTimer = 0;
  const speak = (lines: string[] | undefined) => {
    if (!hint || !lines?.length) return;
    hint.textContent = lines[Math.floor(Math.random() * lines.length)] ?? '';
    hint.classList.add('is-cat');
    window.clearTimeout(hintTimer);
    hintTimer = window.setTimeout(() => { hint.innerHTML = hintHTML; hint.classList.remove('is-cat'); }, 2600);
  };

  const svg = island.querySelector<SVGSVGElement>('[data-cat-host] svg.cat');
  const actor = svg ? new CatActor(svg, {
    // It keeps still and attentive while the first conversation plays; its gestures start afterwards.
    pointer: true, activity: 0, hop: 4, sleeps: true,
    gestures: ['glance', 'groom', 'yawn', 'stretch', 'scratch', 'startle', 'tailPlay', 'loaf', 'hunt', 'play', 'wave', 'nap'],
    onSay: (k) => speak(k === 'cheer' ? say.cheer : k === 'wake' ? say.wake : k === 'woke' ? say.woke : k === 'light' ? say.light : k === 'sleepy' ? say.sleepy : say.mew),
  }) : null;
  if (actor && svg) runCat(actor, island);

  // The state, and how to change it.
  let open = false;
  const setOpen = (next: boolean, instant = false) => {
    if (next === open) return;
    open = next;
    island.dataset['open'] = String(next);
    if (instant || env.reduced) ctrl.set(next ? 'open' : 'collapsed'); else ctrl.to(next ? 'open' : 'collapsed', { duration: next ? 0.95 : 0.7, ease: next ? 'expo.out' : 'power3.inOut' });
    const toggle = island.querySelector<HTMLButtonElement>('[data-island-collapse]');
    toggle?.setAttribute('aria-expanded', String(next));
    if (!next) actor?.setWorking(false);
  };

  island.querySelector('[data-island-collapse]')?.addEventListener('click', (e) => {
    // The strip opens the island when it is closed; this click must not reach it and open it again.
    e.stopPropagation();
    intro?.kill();
    actor?.setActivity(1.2);
    setOpen(false);
  });
  const catHost = island.querySelector<HTMLElement>('[data-cat-host]');
  const hotspot = (el: Element | null) => {
    el?.addEventListener('click', () => { if (!open) setOpen(true); else actor?.poke(); });
    el?.addEventListener('pointerenter', (e) => { actor?.setHover(true); if (!open && (e as PointerEvent).pointerType === 'mouse') setOpen(true); });
    el?.addEventListener('pointerleave', () => actor?.setHover(false));
  };
  hotspot(catHost);
  // The collapsed island is a target too: its strip opens it.
  content?.addEventListener('click', (e) => { if (!open && (e.target as HTMLElement).closest('.island__strip')) setOpen(true); });
  content?.addEventListener('pointerenter', (e) => { if (!open && e.pointerType === 'mouse') setOpen(true); });
  catHost?.setAttribute('tabindex', '0');
  catHost?.setAttribute('role', 'button');
  catHost?.setAttribute('aria-label', root.dataset['catLabel'] ?? '');
  catHost?.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (!open) setOpen(true); else actor?.poke(); } });
  // While it sleeps the same button is how a keyboard wakes it.
  if (catHost) wakeButton(catHost, root.dataset['wakeLabel'] ?? '');

  // The conversation scrolls like a chat: when the messages shown so far are taller than the window, the list slides up so the
  // newest one sits just above the field. Hidden messages keep their place in the layout, so only the shown ones are measured.
  const list = q('list');
  const convo = q('convo');
  let shownUpTo: HTMLElement | null = null;
  const followOffset = (): number => {
    if (!list || !convo || !shownUpTo) return 0;
    const bottom = shownUpTo.offsetTop + shownUpTo.offsetHeight + 8;
    return Math.max(0, bottom - (convo.clientHeight - list.offsetTop));
  };
  const follow = (to: HTMLElement | null, instant = false) => {
    shownUpTo = to;
    if (!list) return;
    const y = -followOffset();
    // Once lines leave by the top they fade out there instead of being cut (hero.css).
    convo?.classList.toggle('is-scrolled', y < 0);
    if (instant || env.reduced) gsap.set(list, { y }); else gsap.to(list, { y, duration: 0.55, ease: 'power3.out', overwrite: 'auto' });
  };

  window.addEventListener('resize', () => { ctrl.refit(); if (shownUpTo) follow(shownUpTo, true); });

  // Motion not welcome: the island is simply open, with the whole conversation (scrolled to its end).
  if (env.reduced) {
    open = true; ctrl.set('open'); island.querySelector('[data-island-collapse]')?.setAttribute('aria-expanded', 'true');
    follow(q('reply2'), true);
    return;
  }

  // The first minute: the island opens from the notch and a message goes back and forth.
  const user = q('user'), tool1 = q('tool1'), tool2 = q('tool2'), reply1 = q('reply1'), reply2 = q('reply2');
  const typed = q('typed'), composer = q('composer'), status = q('status'), statusText = q('status-text'), send = q('send'), dots = q('dots');
  if (!user || !tool1 || !tool2 || !reply1 || !reply2 || !typed || !composer || !statusText || !send) return;
  const text = user.textContent ?? '';
  const doneStatus = statusText.textContent ?? '';
  const busyStatus = root.dataset['busy'] ?? doneStatus;
  const plan = planTyping(text, 21, 11);
  const msgs = [user, tool1, tool2, reply1, reply2];
  gsap.set(msgs, { autoAlpha: 0, y: 8 });
  user.textContent = text;
  ctrl.set('collapsed');
  const step = { v: 0 };
  const intro = gsap.timeline({ delay: 0.85, onComplete: () => { actor?.celebrate(); gsap.delayedCall(3, () => actor?.setActivity(1.2)); } });
  // The island opens from the notch, the field takes focus and a message is typed with a human cadence …
  // A tab in the background stops the conversation where it is; it carries on when you come back.
  env.on('visibility', () => { if (env.hidden) intro.pause(); else intro.resume(); });
  intro.call(() => setOpen(true), [], 0);
  intro.call(() => composer.classList.add('is-focus'), [], 1.25);
  intro.fromTo(step, { v: 0 }, {
    v: plan.total, duration: plan.total, ease: 'none', immediateRender: false,
    onUpdate: () => { typed.textContent = Array.from(text).slice(0, typedCount(plan, step.v)).join(''); },
  }, 1.4);
  // … sent; Claude works (the cat on duty, the dots waving) and answers; the cat celebrates.
  const sendAt = 1.4 + plan.total + 0.5;
  intro.call(() => { send.classList.add('is-ready'); }, [], sendAt - 0.35);
  intro.call(() => { typed.textContent = ''; composer.classList.remove('is-focus'); send.classList.remove('is-ready'); }, [], sendAt);
  intro.to(user, { autoAlpha: 1, y: 0, duration: 0.5, ease: 'power3.out' }, sendAt + 0.05);
  intro.call(() => follow(user), [], sendAt + 0.05);
  intro.call(() => { actor?.setWorking(true); dots?.setAttribute('data-on', 'true'); status?.classList.add('is-busy'); statusText.textContent = busyStatus; }, [], sendAt + 0.3);
  intro.to(tool1, { autoAlpha: 1, y: 0, duration: 0.45, ease: 'power3.out' }, sendAt + 0.9);
  intro.call(() => follow(tool1), [], sendAt + 0.9);
  intro.to(tool2, { autoAlpha: 1, y: 0, duration: 0.45, ease: 'power3.out' }, sendAt + 1.8);
  intro.call(() => follow(tool2), [], sendAt + 1.8);
  intro.call(() => { actor?.setWorking(false); dots?.setAttribute('data-on', 'false'); status?.classList.remove('is-busy'); statusText.textContent = doneStatus; }, [], sendAt + 3.0);
  intro.to(reply1, { autoAlpha: 1, y: 0, duration: 0.5, ease: 'power3.out' }, sendAt + 3.0);
  intro.call(() => follow(reply1), [], sendAt + 3.0);
  intro.to(reply2, { autoAlpha: 1, y: 0, duration: 0.5, ease: 'power3.out' }, sendAt + 3.5);
  intro.call(() => follow(reply2), [], sendAt + 3.5);
}
