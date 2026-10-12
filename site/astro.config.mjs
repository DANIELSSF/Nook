import { defineConfig } from 'astro/config';
import { config } from './src/config.ts';

// Static output for GitHub Pages. `base` and `site` come from src/config.ts.
export default defineConfig({
  site: config.origin,
  base: config.base,
  output: 'static',
  trailingSlash: 'always',
  compressHTML: true,
  build: { inlineStylesheets: 'always' },
  devToolbar: { enabled: false },
});
