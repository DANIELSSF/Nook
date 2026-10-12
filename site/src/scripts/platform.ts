/** Whether the visitor is on a Mac. iPads report themselves as Macs, so touch gives them away. */
export function isMac(): boolean {
  const uad = (navigator as unknown as { userAgentData?: { platform?: string } }).userAgentData;
  if (uad?.platform) return /mac/i.test(uad.platform);
  const ua = navigator.userAgent || '';
  if (/iPhone|iPad|iPod/.test(ua)) return false;
  if (/Mac/i.test(navigator.platform || '') && navigator.maxTouchPoints > 1) return false;
  return /Mac/i.test(navigator.platform || '') || /Macintosh/.test(ua);
}

/** A gentle note for visitors who are not on a Mac: the download is still there, the note says what it needs. */
export function initPlatform(): void {
  if (isMac()) return;
  document.documentElement.classList.add('not-mac');
  document.querySelectorAll<HTMLElement>('[data-nonmac]').forEach((el) => { el.hidden = false; });
}

/** After pressing a download button, say thanks (once the download has been asked for). */
export function initDownloadThanks(): void {
  const thanks = document.querySelector<HTMLElement>('[data-thanks]');
  document.querySelectorAll<HTMLElement>('[data-download]').forEach((a) => a.addEventListener('click', () => {
    if (!thanks) return;
    thanks.hidden = false;
    // A polite live region: re-inserting the text makes it announce again.
    const text = thanks.textContent ?? '';
    thanks.textContent = '';
    window.setTimeout(() => { thanks.textContent = text; }, 40);
  }));
}
