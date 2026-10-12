/**
 * The one place that says where Nook lives. Change the owner, the repository,
 * the release asset or the base path here and everything else (download button,
 * GitHub links, canonical URL, sitemap, Astro's `base`) follows.
 */
export const config = {
  /** GitHub account that owns the repository. */
  owner: 'DANIELSSF',
  /** Repository name. */
  repo: 'Nook',
  /** File attached to each GitHub release (the zipped, ad hoc signed app). */
  asset: 'Nook.zip',
  /** Path the site is served from. A GitHub Pages project site lives under `/<repo>/`; use `/` with a custom domain. */
  base: '/Nook/',
  /** Origin of the site (GitHub Pages: `https://<owner>.github.io`). Used for canonical and social URLs. */
  origin: 'https://danielssf.github.io',
  /** Branch the docs links point to. */
  branch: 'main',
} as const;

const repoUrl = `https://github.com/${config.owner}/${config.repo}`;

export const urls = {
  repo: repoUrl,
  releases: `${repoUrl}/releases`,
  /** Direct download of the latest release's asset: the browser saves the zip without visiting GitHub. */
  download: `${repoUrl}/releases/latest/download/${config.asset}`,
  issues: `${repoUrl}/issues`,
  usage: `${repoUrl}/blob/${config.branch}/docs/USAGE.md`,
  privacy: `${repoUrl}/blob/${config.branch}/docs/PRIVACY.md`,
  notices: `${repoUrl}/blob/${config.branch}/THIRD_PARTY_NOTICES.md`,
  readme: `${repoUrl}#readme`,
  site: `${config.origin}${config.base}`,
} as const;
