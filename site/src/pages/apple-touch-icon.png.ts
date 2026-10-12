import type { APIRoute } from 'astro';
import sharp from 'sharp';
import { iconSvg } from '../lib/icons';

/** The home-screen icon, rendered from the same drawing as the favicon at build time. */
export const GET: APIRoute = async () => {
  const png = await sharp(Buffer.from(iconSvg('awake', { square: true })), { density: 600 }).resize(180, 180).png({ compressionLevel: 9 }).toBuffer();
  return new Response(new Uint8Array(png), { headers: { 'Content-Type': 'image/png' } });
};
