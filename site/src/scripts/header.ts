/** Shows the header on narrow screens once the island has left the top, and tells the rest of the page when it has. */
export function initHeader(): void {
  const header = document.querySelector<HTMLElement>('[data-header]');
  if (!header) return;
  const update = () => header.classList.toggle('is-visible', window.scrollY > 320);
  update();
  window.addEventListener('scroll', update, { passive: true });
}
