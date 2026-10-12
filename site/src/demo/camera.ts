/**
 * The camera of a demo: it looks at the scene through the screen. Its state is the scene point at the centre of the screen and
 * a scale, so a move between two states keeps the focus where the eye expects it (the way Recordly's auto-zoom eases in).
 */
export interface Cam { cx: number; cy: number; k: number }

export interface Frame { screenW: number; screenH: number; designW: number; designH: number }

/** The whole scene, as large as fits. */
export function fitCam(f: Frame): Cam {
  const k = Math.min(f.screenW / f.designW, f.screenH / f.designH);
  return { cx: f.designW / 2, cy: f.designH / 2, k };
}

/**
 * A camera for `rect`: as tight as `maxZoom` times the fit allows, with `pad` px of air around it, and at least `minK` (so text
 * stays readable in a small window, where it pans instead of fitting the area). Clamped so the view never leaves the scene.
 */
export function focusCam(f: Frame, rect: { x: number; y: number; w: number; h: number }, opts: { pad?: number; maxZoom?: number; minK?: number } = {}): Cam {
  const fit = fitCam(f);
  const pad = opts.pad ?? 18;
  const byRect = Math.min(f.screenW / (rect.w + pad * 2), f.screenH / (rect.h + pad * 2));
  const maxK = fit.k * (opts.maxZoom ?? 2.2);
  const minK = opts.minK ?? 0.95;
  let k = Math.max(fit.k, Math.min(byRect, maxK));
  // On a small screen the area does not fit at a readable size: show the middle of it at least at `minK`.
  if (k < minK) k = Math.min(minK, maxK);
  return clampCam(f, { cx: rect.x + rect.w / 2, cy: rect.y + rect.h / 2, k });
}

export function clampCam(f: Frame, c: Cam): Cam {
  const halfW = f.screenW / (2 * c.k), halfH = f.screenH / (2 * c.k);
  const cx = halfW * 2 >= f.designW ? f.designW / 2 : Math.min(f.designW - halfW, Math.max(halfW, c.cx));
  const cy = halfH * 2 >= f.designH ? f.designH / 2 : Math.min(f.designH - halfH, Math.max(halfH, c.cy));
  return { cx, cy, k: c.k };
}

export function camTransform(f: Frame, c: Cam): { tx: number; ty: number } {
  return { tx: f.screenW / 2 - c.cx * c.k, ty: f.screenH / 2 - c.cy * c.k };
}
