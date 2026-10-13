/**
 * The film's measures, shared by its markup and its player. The screen is a 14-inch MacBook Pro's, in points; each shot is a box as
 * wide as a feature demo's scene, centred under the notch, so the island in it hangs from the notch at the app's own size.
 */
export const SCREEN = { w: 1512, h: 945 } as const;
export const SHOT = { w: 640, x: (1512 - 640) / 2 } as const;
/** The laptop around the screen: the bezel and the base under the lid, in the same points. */
export const MAC = { bezel: 18, baseW: 1760, baseH: 30 } as const;
