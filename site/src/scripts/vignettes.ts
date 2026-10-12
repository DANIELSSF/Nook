import { CatActor, runCat, type GestureKind } from '../cat/actor';
import * as A from '../cat/anim';
import { wakeButton } from '../cat/slumber';
import { env } from './env';
import { makeBubble } from './personality';

interface Say { mew: string[]; cheer: string[]; wake: string[]; woke: string[]; light: string[]; sleepy: string[] }
const pick = (l: string[]) => l[Math.floor(Math.random() * l.length)] ?? '';

/**
 * The small scenes where the cat appears again: it peeks over the edge at the top of "what it does not do", it sits by the
 * download and celebrates when you press the button, and it sleeps at the foot of the page.
 */
export function initVignettes(): void {
  document.querySelectorAll<HTMLElement>('[data-vignette]').forEach((el) => {
    const kind = el.dataset['vignette'];
    const svg = el.querySelector<SVGSVGElement>('svg.cat');
    if (!svg) return;
    const parsed = el.dataset['strings'] ? (JSON.parse(el.dataset['strings']) as { say: Say; wakeLabel?: string }) : null;
    const strings = parsed?.say ?? null;
    const bubbleEl = el.querySelector<HTMLElement>('[data-bubble]');
    const bubble = bubbleEl ? makeBubble(bubbleEl) : null;
    const say = (list: string[] | undefined) => { if (bubble && list) bubble(pick(list)); };

    if (kind === 'peek') {
      // It sleeps with the page's cat (curled up on the card's edge); awake, it peeks.
      const actor = new CatActor(svg, { pointer: true, activity: 1.5, gestures: ['peek'], ledge: 0, sleeps: true, still: () => A.peek(3.2, 0, 0) });
      runCat(actor, el);
      el.addEventListener('click', () => { if (actor.asleep) actor.poke(); });
      if (!env.reduced) {
        // The first peek comes soon after the section scrolls in.
        const io = new IntersectionObserver((e) => { if (e.some((x) => x.isIntersecting)) { io.disconnect(); window.setTimeout(() => actor.start('peek'), 700); } }, { threshold: 0.6 });
        io.observe(el);
      }
      return;
    }

    if (kind === 'download') {
      const gestures: GestureKind[] = ['glance', 'groom', 'yawn', 'stretch', 'tailPlay', 'startle', 'scratch', 'wave', 'play'];
      const actor = new CatActor(svg, {
        pointer: true, activity: 0.9, gestures, hop: 6, sleeps: true,
        onSay: (k) => say(strings ? (k === 'cheer' ? strings.cheer : k === 'wake' ? strings.wake : k === 'woke' ? strings.woke : k === 'light' ? strings.light : k === 'sleepy' ? strings.sleepy : strings.mew) : undefined),
      });
      runCat(actor, el);
      const cat = el.querySelector<HTMLElement>('.dcard__cat');
      cat?.addEventListener('click', () => actor.poke());
      cat?.addEventListener('pointerenter', () => actor.setHover(true));
      cat?.addEventListener('pointerleave', () => actor.setHover(false));
      // While it sleeps the same element is how a keyboard wakes it.
      if (cat && parsed?.wakeLabel) wakeButton(cat, parsed.wakeLabel);
      // Pressing any download button makes it happy (a cat that sleeps sleeps through it).
      document.querySelectorAll<HTMLElement>('[data-download]').forEach((a) => a.addEventListener('click', () => {
        if (actor.drowsy) return;
        if (!env.reduced) actor.celebrate(); else say(strings?.cheer);
      }));
      return;
    }

    if (kind === 'sleep') {
      const actor = new CatActor(svg, {
        pointer: false, activity: 0, gestures: ['nap'],
        onSay: (k) => say(strings ? (k === 'wake' ? strings.wake : strings.sleepy) : undefined),
      });
      runCat(actor, el);
      if (env.reduced) { actor.freeze(A.asleepPose()); } else {
        // It naps; woken, it looks up for a moment and goes back to sleep.
        let napping = false;
        const nap = () => { if (el.isConnected && !napping) { napping = true; actor.start('nap'); window.setTimeout(() => { napping = false; }, 1200); } };
        window.setInterval(() => { if (!env.hidden && !actor.busy) nap(); }, 1800);
        nap();
      }
      const cat = el.querySelector<HTMLElement>('.footer__nap-cat');
      cat?.addEventListener('click', () => { actor.poke(); });
      return;
    }
  });
}
