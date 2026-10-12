# Nook — website

[Visit the website](https://danielssf.github.io/Nook/) · [Download Nook](https://github.com/DANIELSSF/Nook/releases/latest/download/Nook.zip) · [Release notes](https://github.com/DANIELSSF/Nook/releases) · [App source](https://github.com/DANIELSSF/Nook)

The product site for Nook: a calm, animated landing page in Spanish. Static output (Astro + TypeScript), GSAP + ScrollTrigger for
the scroll story, Lenis for smooth scrolling. No runtime dependency besides those two.

```sh
cd site
npm install
npm run dev        # http://localhost:4321/Nook/
npm run build      # static site in dist/
npm run preview    # serve dist/ at http://localhost:4321/Nook/
npm run check      # type-check (astro check)
```

If your npm has `ignore-scripts` on, nothing here needs install scripts, and no script of the site downloads a binary by itself:
`npm run export:demos` uses the browser you point it at and an ffmpeg that is already on your Mac (see "Clips" below).

## Where things are changed

| What | Where |
| --- | --- |
| Repo owner, repo name, release asset (`Nook.zip`), base path, site origin | `src/config.ts` — one constant, everything else derives from it |
| Every word on the page | `src/i18n/es.ts` (typed; add `en.ts` with the same shape and select it in `src/i18n/index.ts`) |
| Colours, type, spacing (light and dark in one place, `light-dark()`) | `src/styles/tokens.css` |
| The cat (the app's, ported: check it with `npm run compare:cat`) | `src/cat/` |
| The demo player and its scenes | `src/demo/` |

The download button points to `https://github.com/<owner>/<repo>/releases/latest/download/<asset>`.

## How it is built

- **The cat** (`src/cat/`) is a TypeScript port of the app's own rig: `pose.ts` and `anim.ts` are `PetPose`/`PetAnimation`,
  `render.ts` is `PetPainter` drawing SVG, and `actor.ts` is the pet director in small (blinks, glances, gestures, naps, curiosity
  about the pointer, reactions to scroll, and the hour of the day). The static SVG is rendered by Astro at build time and the same
  `paint()` function updates it in the browser, so it is the same drawing before and after the script runs.
- **The island** (`src/components/Island*.astro`, `src/styles/island.css`) is recreated in HTML/CSS. Its shape is a clip-path made of
  three custom properties that `src/demo/island.ts` tweens, so it grows out of the notch without animating any layout property.
- **The story** (`src/components/Story.astro`, `src/scripts/story.ts`): a sticky stage; the scroll position is the clock. Layers
  drift by different amounts, the day goes from dawn to night, and the cat, the cursor and the island follow the scroll.
- **Environment** (`src/scripts/env.ts` and friends): theme (system + manual), reduced motion (system + manual, live), touch,
  pointer, hour of the day, tab visibility, scroll speed, "not a Mac". Everything that reacts reads it from there.

## The cat's sleep

A visit that begins at night (23:00 to 06:00 for the visitor, the same night as the app's `PetDayPart.night`: `NIGHT` in `src/cat/night.ts`, the one place the window is written) on a
dark page begins with the cat asleep: curled up, breathing slowly, a z floating up, and now and then a twitch of an ear or a paw, as in
a dream. It sleeps in the hero, on its stage, by the download, on the edge of "what it does not do", in the story's wing and in the
header's mark (the tab's icon sleeps too). It is one state for the whole page (`src/cat/slumber.ts`); the cats themselves do the
stirring and the waking (`src/cat/actor.ts`).

None of it is a pose of its own: the cat is the app's cat. `src/cat/` is a port of the Swift (`PetPose`, `PetPainter`, `PetAnimation`,
`PetGestures`, `PetBehaviors`, `PetLife`, `PetSecondary` and `PetWake`), and a sleeper is the app's nap that never ends, waking is the app's
waking (the beats are `WAKE` in `anim.ts`) and falling asleep is the beginning of the app's nap. `npm run compare:cat -- <set> <the app's
contact sheet.png>` draws the website's cat in the app's own grid and prints how closely each tile matches (about 0.99: the same cat);
run it again whenever the app's cat changes. The sets are the app's own films: `wake-header`, `wake-compact` (and `wake-light-*`),
`stretch-header`, `yawn-header`, `nap-compact` and `sad-header`, `sad-compact`. Whatever the cat does at random (a blink, a twitch, a
sigh) uses the app's own hash (`hash()` in `anim.ts`, the same 64-bit mix), so it happens at the same moments as in the app and a
sheet with such events can be compared whole.

- A pointer that comes close makes it stir: it twitches as it does in a dream and a lid cracks open, then back to sleep. Touch screens
  have no hover.
- A click, a tap, or Enter or Space on it wakes it (while it sleeps it is a button named «Despertar al gato»). It never wakes at once:
  about four seconds of an ear flick, eyes that open and sink again, a stretch (front legs out, rear up, back arched) with a yawn, a
  slow blink, and it sits up.
- If the page turns light while it sleeps (the toggle, or the system), it squints at the light first and then wakes the same way.
- Once woken it stays awake for the visit (`sessionStorage`), even if you go back to dark. Only four minutes without a move, a key or a
  scroll, at night and in the dark, let it doze off again: it lies down and curls up as the app's cat does when it naps. Awake in the
  night hours it looks as the app's sleepy cat does (half-lidded, ears a little back).
- Reduced motion: the same states as still poses (the app's asleep pose; lying awake for a moment; sitting), with no stirring,
  breathing, z's or stretch.
- A hidden tab pauses everything; a wake in progress carries on when you come back.

To see any state at any time: `?hora=23` (or `?hour=23`) makes it that hour for the cat and its greetings, and `?doze=5` shortens the four
minutes to five seconds. In `npm run dev`, `window.__nookCat` holds the state (`slumber`, `env`, `actors()`). A headless probe can use the
OS color scheme (`colorScheme: 'dark'`), a fresh context for a fresh `sessionStorage`, and the theme toggle for the light.

## The sad cat

When Nook is asked to quit, the island dims and a card comes up with the same cat, drooped: head low and leaning, ears folded out and down,
a limp tail, wet eyes, a tear that runs down its cheek now and then, a long blink and a sigh. It is `sad()` in `src/cat/anim.ts` (the app's
`PetAnimation.sad`, `PetSad.swift`), a pure function of the seconds since the scene began, so nothing about it needs a clock of its own:
the demo engine plays it with a `pose` step (see `src/demo/scenes/quit.ts`) and it is sought and looped like the rest of the timeline.
`npm run compare:cat -- sad-header <the app's sad-header-zoom.png>` checks it against the app's render.

## The demo engine (Recordly-style, in code)

Each feature is a scripted scene played by `src/demo/player.ts`: a styled frame (wallpaper, padding, rounded window, soft
shadow), a smooth synthetic cursor that glides along eased arcs, click ripples, a camera that eases into the area being used and
back out, typing with a human cadence, keystroke chips and captions. It is DOM and SVG (crisp at any size, no video), driven by
one GSAP timeline per scene, and it:

- plays only while at least a third of it is on screen and the tab is visible, and restarts if you come back after a while;
- follows the page theme (the screen around the island is light or dark; the island is black, and a scene can turn its body to paper, as the app's light theme does);
- shows one still frame, with the steps listed as text, when motion is reduced.

A scene is two files. The markup (`src/components/scenes/XScene.astro`) names the elements with `data-t`; the script
(`src/demo/scenes/x.ts`) is a list of steps:

```ts
export default function x(copy: { typed: string }): SceneDef {
  return {
    id: 'x',
    islands: { island: 'collapsed' },              // each island's first state
    steps: [
      { do: 'caption', n: 0 },                      // caption text comes from the markup's steps list
      { do: 'move', to: { el: 'cat', at: [0.5, 0.5] }, t: 1.2 },   // the cursor glides there
      { do: 'island', state: 'open', t: 0.9 },      // morph: collapsed | peek | open | tall
      { do: 'click', to: 'send', press: 'send' },   // press + ripple
      { do: 'zoom', to: { el: 'field', at: [0.3, 0.2] }, scale: 1.4 },   // the camera; 'fit' goes back out
      { do: 'type', target: 'typed', text: copy.typed, cps: 20 },
      { do: 'keys', keys: ['⌘', 'Q'], t: 1 },       // keystroke chips
      { do: 'show', target: 'msg', fx: 'rise' },    // fade | rise | drop | pop | slide (hide is the mirror)
      { do: 'scroll', list: 'list', to: 'msg' },    // scroll the conversation
      { do: 'label', name: 'poster' },              // the still frame for Reduce Motion
      { do: 'wait', t: 1 },
    ],
  };
}
```

Any step can start with the previous one (`with: true`), at a time (`at`) or later (`delay`). Positions are measured from the markup
when the timeline is built (and rebuilt on resize), so a script never contains coordinates. The full vocabulary is in
`src/demo/types.ts`. Add the scene to `src/components/Features.astro`; the manager (`src/demo/manager.ts`) picks it up by its
`data-demo` id. A scene reads its copy by the feature's id (`feature('customize')` in `src/i18n`), so the order of the list is only a
matter of the page.

Two steps are for the app's newer moves. `drag` takes a tab (any element of a row) past its neighbours the way the app reorders its tabs:
the cursor takes hold, the tab lifts (`is-lifted`) and follows it, each neighbour springs aside as the tab's edge passes its middle, and it
settles; only offsets are tweened, so the markup keeps its order and the measured positions stay valid. `pose` plays one of the cat's
scenes (`sad`) on a cat inside an element, as a function of the timeline's time. The big cats of the home and the greeting are
`data-stage-cat="name"` (`src/components/HomeStage.astro`): the same cat, drawn large, that looks at the demo's cursor and answers
`{ do: 'cat', action: 'celebrate' | 'wave', target: 'name' }`.

Two pieces of the app are ported so a scene can show them as they are. The tab icons (`src/lib/tabIcons.ts` is the app's own geometry,
sixteen icons) rest until a step gives them `is-moving`: an `<svg class="tabicon" data-icon="flame">` is all a scene needs, and the demo
player redraws it twenty times a second while the demo plays. The light theme: wrap the scene in a `.skinscope` and add or remove
`is-paper` on it with a `class` step (see `src/components/scenes/CustomizeScene.astro`): the body of the island turns to paper inside the
black shell, the popovers and the settings card follow, and the colors cross-fade. A tab can wear the slashed speaker of a muted one
(`muted` on the tab, or `is-on` on its `-mute` element, as the customize scene does). A scene that needs more room than 640 × 400 takes `h` on
`<Demo>`.

The scenes: `home` (the greeting and the home, with no tab), `follow`, `question`, `compose`, `agents`, `alerts`, `customize` (name, color,
icon, the tab's sound, reordering, Settings and the theme) and `quit` (under the cat's stage).

### Clips for the README or social media

```sh
npx playwright install chromium            # once (or: PLAYWRIGHT_CHANNEL=msedge|chrome to use an installed browser)
npm run export:demos                       # all demos, light theme
npm run export:demos -- --scene follow --theme both
```

It builds the site with the demo pages switched on (`EXPORT_DEMOS=1`, never shipped), records each scene at 1280 × 720 with
Playwright and writes `exports/<scene>-<theme>.webm` and `.mp4` (H.264). Trimming and the MP4 use an ffmpeg already on the Mac (`$FFMPEG`, the PATH — `brew install ffmpeg` — or a `ffmpeg-static` binary you installed yourself); the script never downloads one, and without it writes the raw WebM only. `exports/` is ignored by git.

## Assets

`src/pages/favicon.svg.ts`, `favicon-sleep.svg.ts` (shown while the tab is in the background), `apple-touch-icon.png.ts`,
`robots.txt.ts` and `sitemap.xml.ts` are generated at build time from the cat's drawing and `src/config.ts`.
`public/og.png` (the social image) is made by `npm run assets` from `scripts/make-assets.mjs`; regenerate it if the hero changes.

## Deploying to GitHub Pages

The public site is served at **[https://danielssf.github.io/Nook/](https://danielssf.github.io/Nook/)** from the root of the
**`gh-pages`** branch. The app and website source live on `main`; `site/dist/` is generated output and stays out of that branch.

1. Build and check the source from `main`:

   ```sh
   cd site
   npm ci --ignore-scripts
   npm run check
   npm run build
   ```

2. In a separate checkout of `gh-pages`, publish the **contents** of `site/dist/` at the branch root, alongside an empty
   **`.nojekyll`** file. The root must contain `index.html`, `_astro/`, the generated icons, `og.png`, `robots.txt` and `sitemap.xml`.
   `.nojekyll` keeps GitHub from processing the site with Jekyll and ensures the `_astro/` assets are served.
3. Commit and push that branch. In **Settings → Pages → Build and deployment**, select **Deploy from a branch**, **gh-pages**,
   **/ (root)**. Keep this source selected for subsequent deployments.
4. Wait for GitHub's Pages deployment to finish, then check the live site, its theme and motion controls, and the download link.

The base path is `/Nook/` and the origin is `https://danielssf.github.io` (`src/config.ts`). Keep both aligned with the published
URL. The download button expects a published GitHub release with **`Nook.zip`** attached; release uploads are separate from the
website deployment. The packaged app currently requires **macOS 27 or later on Apple Silicon**, uses an ad hoc signature, and is
not notarized.

There is no active custom Actions workflow for the website. `deploy-pages.yml.example` is an optional alternative for a future
switch to Actions-based publishing; it is not used by the current branch deployment.
