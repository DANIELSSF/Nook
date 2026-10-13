/**
 * The page's looping CSS animations (the dots that wave while a tab works, the blinking carets, the spinners) live in the hero,
 * the story, the demos and the film. Off screen they would still tick every frame and keep the browser restyling them; this marks each of
 * those parts `is-offscreen` while it is out of view, and base.css holds its animations still until it comes back.
 */
export function initOffscreen(): void {
  if (!('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) (e.target as HTMLElement).classList.toggle('is-offscreen', !e.isIntersecting);
  }, { rootMargin: '120px 0px' });
  document.querySelectorAll<HTMLElement>('[data-hero], [data-stage], [data-demo], [data-film]').forEach((el) => io.observe(el));
}
