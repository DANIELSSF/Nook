import { es, type Strings } from './es';

/**
 * The language the site is built in. To add one, create `en.ts` with the same shape as `es.ts` (TypeScript checks it against
 * `Strings`) and select it here, or by route when there is more than one.
 */
export const t: Strings = es;
export type { Strings };

/** Fills `{name}` placeholders. */
export const fmt = (text: string, vars: Record<string, string | number>): string =>
  text.replace(/\{(\w+)\}/g, (_, k: string) => String(vars[k] ?? ''));

/** One feature's copy, by its id (the list's order is a matter of the page, not of the scenes that read it). */
export function feature(id: string): Strings['features']['items'][number] {
  const found = t.features.items.find((item) => item.id === id);
  if (!found) throw new Error(`No feature "${id}"`);
  return found;
}
