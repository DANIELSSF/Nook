import type { APIRoute } from 'astro';
import { iconSvg } from '../lib/icons';

export const GET: APIRoute = () => new Response(iconSvg('asleep'), { headers: { 'Content-Type': 'image/svg+xml; charset=utf-8' } });
