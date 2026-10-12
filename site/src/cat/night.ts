/**
 * When the cat sleeps. The night is one constant, in the visitor's local hours: from `from` (inclusive) to `to` (exclusive). The
 * inline script in the layout reads the same numbers, so a cat that is to start the visit asleep is already drawn asleep on the
 * first paint. Nothing here touches the page, so the build can import it too.
 */
export const NIGHT = { from: 23, to: 6 } as const;

export const isNight = (hour: number): boolean => hour >= NIGHT.from || hour < NIGHT.to;

/** sessionStorage key. Once the cat has been woken it stays awake for the rest of the visit, a reload included. */
export const AWAKE_KEY = 'nook-cat';

/** Seconds of quiet (no move, key or scroll) after which an awake cat dozes off again, at night and in the dark. */
export const DOZE_AFTER = 4 * 60;

const search = (): string => (typeof location === 'undefined' ? '' : location.search);

/**
 * Test hook: `?hora=23` (or `?hour=23`) makes it that hour of the night for the cat and its greetings, whatever the clock says, so
 * every state can be checked at any time of day.
 */
export function hourOverride(query: string = search()): number | null {
  const m = /[?&](?:hora|hour)=(\d{1,2})(?:&|$)/.exec(query);
  const hour = m ? Number(m[1]) : NaN;
  return hour >= 0 && hour <= 23 ? hour : null;
}

/** The hour it is for the cat now: the test override, or the visitor's clock. */
export const hourNow = (): number => hourOverride() ?? new Date().getHours();

/** Test hook: `?doze=5` shortens the long quiet before the cat dozes off to five seconds. */
export function dozeAfter(query: string = search()): number {
  const m = /[?&]doze=(\d{1,4})(?:&|$)/.exec(query);
  return m ? Number(m[1]) : DOZE_AFTER;
}
