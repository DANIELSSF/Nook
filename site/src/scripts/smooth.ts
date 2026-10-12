import Lenis from 'lenis';
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { env } from './env';

gsap.registerPlugin(ScrollTrigger);

/**
 * Smooth scrolling for mouse wheels, kept in step with ScrollTrigger. Touch screens keep their own (native) scrolling, and
 * nothing smooths the scroll when motion is not welcome.
 */
export function initSmooth(): () => void {
  let lenis: Lenis | null = null;
  let tick: ((t: number) => void) | null = null;

  const start = () => {
    if (lenis || env.reduced || env.touch) return;
    lenis = new Lenis({ lerp: 0.1, wheelMultiplier: 0.95, smoothWheel: true, anchors: { offset: -72 } });
    lenis.on('scroll', ScrollTrigger.update);
    tick = (t) => lenis?.raf(t * 1000);
    gsap.ticker.add(tick);
    gsap.ticker.lagSmoothing(0);
  };
  const stop = () => {
    if (!lenis) return;
    if (tick) gsap.ticker.remove(tick);
    lenis.destroy();
    lenis = null; tick = null;
    gsap.ticker.lagSmoothing(500, 33);
  };
  start();
  const offs = [
    env.on('motion', () => { if (env.reduced) stop(); else start(); }),
    env.on('touch', () => { if (env.touch) stop(); else start(); }),
    // A tab in the background does not need a smooth scroll.
    env.on('visibility', () => { if (env.hidden) lenis?.stop(); else lenis?.start(); }),
  ];
  return () => { offs.forEach((o) => o()); stop(); };
}
