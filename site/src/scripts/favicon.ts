import { env } from './env';
import { slumber } from '../cat/slumber';

/** While the tab is in the background, or the cat sleeps, the cat in the tab sleeps. */
export function initFavicon(): void {
  const link = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
  if (!link) return;
  const awake = link.href;
  const asleep = awake.replace('favicon.svg', 'favicon-sleep.svg');
  const sync = () => { link.href = env.hidden || slumber.asleep ? asleep : awake; };
  env.on('visibility', sync);
  slumber.on(sync);
  sync();
}
