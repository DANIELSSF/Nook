const root = document.documentElement;

/** The footer's motion switch: follow the system (default), or force full or reduced motion. */
export function initMotionToggle(): void {
  const buttons = document.querySelectorAll<HTMLButtonElement>('[data-motion-set]');
  const sync = () => {
    const cur = root.dataset['motion'] ?? 'auto';
    buttons.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset['motionSet'] === cur)));
  };
  buttons.forEach((b) => b.addEventListener('click', () => {
    const v = b.dataset['motionSet'] ?? 'auto';
    if (v === 'auto') root.removeAttribute('data-motion'); else root.setAttribute('data-motion', v);
    try { if (v === 'auto') localStorage.removeItem('nook-motion'); else localStorage.setItem('nook-motion', v); } catch { /* storage may be blocked */ }
    sync();
  }));
  sync();
}
