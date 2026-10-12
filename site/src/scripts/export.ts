import { startEnv } from './env';
import { initDemos } from '../demo/manager';

declare global {
  interface Window { __demoStarted?: number; __demoDone?: boolean }
}

/** The export page: starts its one demo from the first frame and says when it has played to the end. */
startEnv();
initDemos(document, {
  once: true,
  onReady: (player) => {
    requestAnimationFrame(() => {
      window.__demoStarted = performance.now();
      player.restart();
      void player.done.then(() => { window.__demoDone = true; });
    });
  },
});
