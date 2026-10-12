import type { IslandStateName } from './island';

/**
 * The vocabulary of a demo script. A scene is a list of steps, written the way you would narrate a screen recording: move the
 * cursor here, click, type this, zoom into that, wait. The player turns the list into one GSAP timeline.
 *
 * Elements are named in the scene's markup with `data-t="name"`; a step refers to them by that name.
 */
export type Target = string | string[];
export type Vars = Record<string, unknown>;
/** How something appears or goes away. */
export type Fx = 'fade' | 'rise' | 'drop' | 'pop' | 'slide';

/** A point on the scene: an element (its centre), a spot inside an element (0...1 on each axis, plus px offsets), or raw scene px. */
export type Anchor = string | { el: string; at?: [number, number]; dx?: number; dy?: number } | { x: number; y: number };

interface Timing {
  /** Start together with the previous step instead of after it. */
  with?: boolean;
  /** Start at this time (seconds from the beginning). */
  at?: number;
  /** Start this long after the moment it would have started. */
  delay?: number;
}

export type Step = Timing & (
  /** Nothing happens for `t` seconds. */
  | { do: 'wait'; t: number }
  /** Marks a moment. `poster` is the still frame shown when motion is reduced. */
  | { do: 'label'; name: string }
  /** Shows the nth caption (0-based) under the screen, or none. */
  | { do: 'caption'; n: number | null }
  | { do: 'show' | 'hide'; target: Target; fx?: Fx; t?: number; stagger?: number }
  | { do: 'set'; target: Target; vars: Vars }
  | { do: 'tween'; target: Target; vars: Vars; from?: Vars; t?: number; ease?: string }
  /** Adds or removes classes (a hover, a pressed state, "the field is focused"). */
  | { do: 'class'; target: Target; add?: string; remove?: string }
  | { do: 'text'; target: string; text: string }
  /** Morphs an island between its states. */
  | { do: 'island'; target?: string; state: IslandStateName; t?: number; ease?: string }
  /** Glides the cursor along an eased arc. */
  | { do: 'move'; to: Anchor; t?: number; arc?: number; ease?: string }
  /** Clicks (moving there first if `to` is given): the cursor presses, a ripple spreads, the element under it is pressed. */
  | { do: 'click'; to?: Anchor; kind?: 'left' | 'right'; press?: string; zoom?: number }
  /** The cursor carries an element (a dragged file) until `null`. */
  | { do: 'carry'; target: string | null; dx?: number; dy?: number }
  /**
   * Drags a tab (any element of a row) sideways past the neighbour (or neighbours, nearest first) `over`, the way the app reorders its
   * tabs: the cursor takes hold, the element lifts and follows it, each neighbour springs aside as it passes, and it settles where it
   * is let go.
   */
  | { do: 'drag'; target: string; over: string | string[]; t?: number }
  /** Types text with a human cadence. */
  | { do: 'type'; target: string; text: string; cps?: number; append?: boolean; seed?: number; zoom?: number }
  /** Keystroke chips at the bottom of the screen, e.g. ['⌘', 'Q'] or ['↵']. */
  | { do: 'keys'; keys: string[]; t?: number }
  /**
   * Eases the camera into an area, or back out to the whole scene ('fit'). `scale` is how much it magnifies the fit. (`click` and
   * `type` take a `zoom` of their own for the common case of "go there and look closely": the camera follows the action.)
   */
  | { do: 'zoom'; to: Anchor | 'fit'; scale?: number; t?: number; ease?: string }
  /** Scrolls a list (the conversation) so that an element is in view. */
  | { do: 'scroll'; list: string; to: string | 'end' | 'start'; t?: number }
  /** Asks the cat of an island (or of a stage: `data-stage-cat`) to react. */
  | { do: 'cat'; action: 'perk' | 'celebrate' | 'work' | 'rest' | 'wave'; target?: string }
  /**
   * Plays one of the cat's scenes on the cat inside `target`, for `t` seconds: a pose that is a pure function of the time since the
   * scene began (the sad cat of the question before quitting), so it is sought and looped like the rest of the timeline.
   */
  | { do: 'pose'; target: string; scene: 'sad'; t: number }
  | { do: 'call'; fn: (ctx: PlayerContext) => void }
);

export interface SceneDef {
  id: string;
  steps: Step[];
  /** The state each island starts in (by its `data-t`). Defaults to what the markup says. */
  islands?: Record<string, IslandStateName>;
  /** Where the cursor starts; off the right-hand edge by default. */
  cursorStart?: Anchor;
  /** Seconds to hold the last frame before the loop starts over. */
  hold?: number;
}

export interface PlayerContext {
  root: HTMLElement;
  q(name: string): HTMLElement | null;
}
