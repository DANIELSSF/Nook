import type { Anchor } from './types';

/**
 * Where things are on the scene, in the scene's own pixels. It adds up `offsetLeft/offsetTop` along the offset-parent chain
 * instead of reading bounding boxes, so it is the same whatever the camera, a tween or a transform is doing at the moment.
 */
export class Geometry {
  private cache = new Map<string, HTMLElement | null>();
  constructor(private scene: HTMLElement) {}

  el(name: string): HTMLElement | null {
    if (!this.cache.has(name)) this.cache.set(name, this.scene.querySelector<HTMLElement>(`[data-t="${name}"]`));
    return this.cache.get(name) ?? null;
  }

  rect(name: string): { x: number; y: number; w: number; h: number } {
    const el = this.el(name);
    if (!el) throw new Error(`demo: no element named "${name}"`);
    return this.rectOf(el);
  }

  rectOf(el: HTMLElement): { x: number; y: number; w: number; h: number } {
    let x = 0, y = 0;
    let node: HTMLElement | null = el;
    while (node && node !== this.scene) {
      x += node.offsetLeft; y += node.offsetTop;
      const parent = node.offsetParent as HTMLElement | null;
      if (!parent) break;
      // offsetLeft is relative to the offset parent's padding edge; its own border is not in it.
      x += parent === this.scene ? 0 : parent.clientLeft;
      y += parent === this.scene ? 0 : parent.clientTop;
      node = parent;
    }
    return { x, y, w: el.offsetWidth, h: el.offsetHeight };
  }

  point(a: Anchor): { x: number; y: number } {
    if (typeof a === 'string') { const r = this.rect(a); return { x: r.x + r.w / 2, y: r.y + r.h / 2 }; }
    if ('el' in a) {
      const r = this.rect(a.el);
      const [fx, fy] = a.at ?? [0.5, 0.5];
      return { x: r.x + r.w * fx + (a.dx ?? 0), y: r.y + r.h * fy + (a.dy ?? 0) };
    }
    return { x: a.x, y: a.y };
  }

  /** The element an anchor points at, if it points at one. */
  anchorEl(a: Anchor): HTMLElement | null {
    if (typeof a === 'string') return this.el(a);
    if ('el' in a) return this.el(a.el);
    return null;
  }
}
