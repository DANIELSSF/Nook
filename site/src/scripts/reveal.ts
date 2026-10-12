import { env } from './env';

/** Things marked `.reveal` ease in once, as they come into view (with motion reduced they only fade in; see base.css). */
export function initReveal(): void {
  const items = document.querySelectorAll<HTMLElement>('.reveal');
  if (!items.length) return;
  if (!('IntersectionObserver' in window)) { items.forEach((el) => el.classList.add('is-in')); return; }
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      (e.target as HTMLElement).classList.add('is-in');
      io.unobserve(e.target);
    }
  }, { rootMargin: '0px 0px -9% 0px', threshold: 0.08 });
  items.forEach((el) => io.observe(el));
  // If motion becomes unwelcome while the page is open, show whatever is still waiting.
  env.on('motion', () => { if (env.reduced) items.forEach((el) => { el.classList.add('is-in'); io.unobserve(el); }); });
}
