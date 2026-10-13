import type { FilmPlayer } from './player';

/**
 * Starts the film when it comes within a screen or so of the viewport (the player and its script load then, so the first paint does
 * not wait for them). A link marked `data-film-play` (the hero's «Ver la película») scrolls to it as an anchor does and plays it from
 * the first frame.
 */
export function initFilm(root: HTMLElement): void {
  let booting: Promise<FilmPlayer> | null = null;
  const boot = (): Promise<FilmPlayer> => {
    booting ??= import('./player').then(({ FilmPlayer }) => {
      const player = new FilmPlayer(root);
      player.init();
      // Handy for tuning the script from the console (`__nookFilm`); not part of the shipped page.
      if (import.meta.env.DEV) (window as unknown as { __nookFilm?: FilmPlayer }).__nookFilm = player;
      return player;
    });
    return booting;
  };
  const near = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    near.disconnect();
    void boot();
  }, { rootMargin: '900px 0px' });
  near.observe(root);
  document.querySelectorAll<HTMLAnchorElement>('a[data-film-play]').forEach((a) => a.addEventListener('click', () => {
    void boot().then((p) => p.restart());
  }));
}
