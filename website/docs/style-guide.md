# Design direction · working proof

**Reference:** Lukas’s `/work/` gives each project a name, a literal description and a destination. The `project` layout pairs serif headlines with monospace metadata. Borrow that hierarchy, not the whole portfolio: this site needs room for a figure and command examples. From the supplied Jekyll template keep the page/data/layout split and its neutral Tailwind + DaisyUI build. From H itself take the graphic grammar: an entry is a point, a continuation a line, a fork two labeled paths. Never draw a client as a branch or a fork as a second worker.

## Visual and interaction decisions

- Design as a field manual: warm paper, dark ink, a restrained green for actions and the alternate path. `--paper`, `--ink`, `--muted`, `--accent`, `--rule` own the palette. No gradients, floating chat bubbles, invented metrics, mascot, or web fonts. A locally drawn H mark serves at favicon size.
- Headline in a system serif; body and controls in system sans; labels and commands in monospace. Prose stays near 65–70 characters per line. A thin rule separates sections; space, not shadows, establishes priority.
- Home proof: show a single session across three steps: start in the terminal, disconnect, and watch the same run in the browser. Nothing waits on an animation. The timeline is labeled as an example, not a live status display.
- The demo is a **walkthrough**. Native disclosures let the reader inspect consequences. No terminal emulator, daemon connection, provider account, network fetch, or third-party embed. No Motion/GSAP: SVG strokes, CSS keyframes and `<details>` do the job without hydration or bundled scripts.
- Wide: pair proposition and figure. Narrow: proposition, actions, full-width figure. The three primary nav links stay visible; manual chapters collapse into a named disclosure. Use one H1, a skip link, descriptive text links and visible keyboard focus. Target WCAG 2.2 AA; don’t claim certification.
- Release review: at 320, 390 and 1440 px, read the timeline, follow the switching guide → setup, use only Tab/Enter/Space to open a chapter and inspect a scenario. Inspect contrast and reduced-motion mode. Ask a new reader what happens to the run when the terminal closes. If they think work has moved to the browser, revise the timeline.
