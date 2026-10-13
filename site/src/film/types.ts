import type { IslandStateName } from '../demo/island';
import type { Anchor, Fx, Vars } from '../demo/types';
import type { Cheer } from '../cat/anim';
import type { AccessoryId, CoatId } from '../cat/render';
import type { GestureName } from './cat';

/**
 * The vocabulary of the film's script: the feature demos' steps (`src/demo/types.ts`), read the same way, plus what a film needs on top
 * of them: shots, a camera that moves over a laptop, titles, chapters, and a cat that is directed rather than left to itself.
 *
 * Names are `data-t` inside the shot that is playing (the last `shot` step), or `data-f` of the film itself when they start with `@`
 * (`@cursor`, `@doc`, `@mac`…).
 */
export type Target = string | string[];

interface Timing {
  /** Start together with the previous step instead of after it. */
  with?: boolean;
  /** Start at this time (seconds from the beginning of the film). */
  at?: number;
  /** Start this long after the moment it would have started. */
  delay?: number;
}

/** The part of the frame a camera move puts its subject in: all of it, beside a title (under it on a narrow screen), or under a title. */
export type Into = 'full' | 'side' | 'low';

/** What the camera looks at: an element (or `@mac`, the whole laptop), framed into a part of the frame. */
export interface Aim {
  el: string;
  /** The point of it that goes to the middle of the frame part (0...1 on each axis); its centre by default. */
  at?: [number, number];
  /** Room around it, in screen points. */
  pad?: number;
  into?: Into;
  /** Closer (or farther) than the fit. */
  zoom?: number;
  /** Never farther than this scale (as long as the shot's island still fits the frame part: it always stays whole). */
  min?: number;
  /** A close-up that crops the island on purpose (the cat alone in the notch): the island need not stay whole. */
  crop?: boolean;
  /** The screen point (in screen points, up from its top edge) that sits at the very top of the frame, instead of the centring. */
  top?: number;
  /** The laptop tipped back (rx) or turned (ry), in degrees. */
  rx?: number;
  ry?: number;
}

export type CatAct = 'celebrate' | 'perk' | 'work' | 'rest' | 'nap' | 'blink' | GestureName;

export type Step = Timing & (
  | { do: 'wait'; t: number }
  /** Marks a moment. `poster` is the still frame shown when motion is reduced. */
  | { do: 'label'; name: string }
  /** A chapter begins here: a mark on the progress bar, and an entry of the text alternative. */
  | { do: 'chapter'; id: string }
  /** The shot that plays from here (its names are the ones the steps after it use): cut to it, or cross-fade. */
  | { do: 'shot'; id: string; fx?: 'cut' | 'fade'; t?: number }
  | { do: 'show' | 'hide'; target: Target; fx?: Fx; t?: number; stagger?: number }
  | { do: 'set'; target: Target; vars: Vars }
  | { do: 'tween'; target: Target; vars: Vars; from?: Vars; t?: number; ease?: string }
  | { do: 'class'; target: Target; add?: string; remove?: string }
  | { do: 'text'; target: string; text: string }
  | { do: 'island'; state: IslandStateName; t?: number; ease?: string }
  | { do: 'move'; to: Anchor; t?: number; arc?: number; ease?: string }
  | { do: 'click'; to?: Anchor; kind?: 'left' | 'right'; press?: string }
  | { do: 'carry'; target: string | null; dx?: number; dy?: number }
  | { do: 'drag'; target: string; over: string | string[]; t?: number }
  | { do: 'type'; target: string; text: string; cps?: number; append?: boolean }
  | { do: 'keys'; keys: string[]; t?: number }
  | { do: 'scroll'; list: string; to: string | 'end' | 'start'; t?: number }
  /** Moves the camera to an aim. */
  | { do: 'cam'; aim: Aim; t?: number; ease?: string }
  /** A title comes in word by word, stays `hold` seconds and goes (with `hold` 0 it stays to the end). */
  | { do: 'title'; id: string; hold: number }
  /** Directs a cat (an island's `cat`, a stage cat by its name, or `@studio-cat`). */
  | { do: 'cat'; target: string; act: CatAct; style?: Cheer; variant?: number }
  /** The sad cat's scene on the cat inside `target`, for `t` seconds. */
  | { do: 'sad'; target: string; t: number }
  /** The cat's coat and accessory from here on. */
  | { do: 'dress'; target: string; coat: CoatId; accessory?: AccessoryId }
  /** An alert's bell rings, and its sound is drawn as rings that spread from it, `pulses` times. */
  | { do: 'ring'; target: string; color: string; pulses?: number }
);
