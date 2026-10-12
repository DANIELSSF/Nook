import { standaloneCat } from '../cat/render';

import { asleepPose, sit } from '../cat/anim';

/**
 * The site's icon: the cat on the app's own dark tile (the app icon's colour). `awake` sits; `asleep` lies curled with its z's:
 * the tab shows it while the page is in the background.
 */
export function iconSvg(mood: 'awake' | 'asleep', opts: { square?: boolean } = {}): string {
  const awake = mood === 'awake';
  const { css, group } = standaloneCat(undefined, awake ? sit(0.4) : asleepPose());
  // The sitting cat is 31 units tall; the sleeping one is wide and low.
  const place = awake ? 'translate(32 54) scale(1.32) translate(0 -34)' : 'translate(31 56) scale(1.05) translate(0 -34)';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64"><title>Nook</title><style>${css}</style><rect width="64" height="64" rx="${opts.square ? 0 : 15}" fill="#1b2120"/><circle cx="32" cy="32" r="25" fill="none" stroke="#27332f" stroke-width="0.7"/><g transform="${place}">${group}</g></svg>`;
}

/** The same icon with a little padding of its own, for platforms that do not round it. */
export const iconPngSize = 180;

