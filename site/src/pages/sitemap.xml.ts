import type { APIRoute } from 'astro';
import { urls } from '../config';

export const GET: APIRoute = () => {
  const day = new Date().toISOString().slice(0, 10);
  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url><loc>${urls.site}</loc><lastmod>${day}</lastmod><changefreq>monthly</changefreq></url>\n</urlset>\n`;
  return new Response(xml, { headers: { 'Content-Type': 'application/xml; charset=utf-8' } });
};
