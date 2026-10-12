import { env } from './env';

type Pref = 'auto' | 'light' | 'dark';
const ORDER: Pref[] = ['auto', 'light', 'dark'];
const root = document.documentElement;

function read(): Pref {
  const t = root.dataset['theme'];
  return t === 'light' || t === 'dark' ? t : 'auto';
}

/** The theme toggle: automatic (follows the system), light, dark. The choice lives in localStorage and on <html data-theme>. */
export function initTheme(): void {
  const buttons = document.querySelectorAll<HTMLButtonElement>('[data-theme-toggle]');
  const sync = () => {
    const pref = read();
    buttons.forEach((b) => {
      const labels = JSON.parse(b.dataset['labels'] ?? '{}') as Record<string, string>;
      b.setAttribute('aria-label', (labels['pattern'] ?? '{current}').replace('{current}', labels[pref] ?? pref));
    });
    // The address bar follows a manual choice too.
    let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"][data-manual]');
    if (pref === 'auto') { meta?.remove(); return; }
    if (!meta) { meta = document.createElement('meta'); meta.name = 'theme-color'; meta.dataset['manual'] = ''; document.head.appendChild(meta); }
    meta.content = pref === 'light' ? '#f3f0e9' : '#0a0c0b';
  };
  buttons.forEach((b) => b.addEventListener('click', () => {
    const next = ORDER[(ORDER.indexOf(read()) + 1) % ORDER.length] as Pref;
    const apply = () => {
      if (next === 'auto') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', next);
      try { if (next === 'auto') localStorage.removeItem('nook-theme'); else localStorage.setItem('nook-theme', next); } catch { /* storage may be blocked */ }
      sync();
    };
    // The page cross-fades from one theme to the other where the browser can (a view transition); otherwise it switches at once.
    const doc = document as Document & { startViewTransition?: (cb: () => void) => unknown };
    if (doc.startViewTransition && !env.reduced && !env.hidden) doc.startViewTransition(apply); else apply();
  }));
  sync();
  env.on('theme', sync);
}
