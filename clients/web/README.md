# Working on the web UI

From `clients/web`, run `mix deps.get && mix phx.server` in **dev**. Sign in at
<http://127.0.0.1:4000> with the owner token for your `H_DATA_DIR`. Upgrading
from the non-reloading endpoint requires **one server restart**; finish or stop
active runs first. Use the same `H_DATA_DIR` to keep the existing sessions.
Don't start a second daemon against that store. For an independent preview,
use a fresh `H_DATA_DIR`, a different `PORT`, and a separate browser profile
(loopback cookies are not scoped by port).

Phoenix watches this client's `lib/` and `priv/static/`. CSS swaps in place;
JS, HEEx and web Elixir changes refresh the page and recompile web code as
needed. No Node build step. Restart for configuration, dependency, supervision
or engine changes. The reloader and inspector are development tools: keep the
server on loopback, not behind a public proxy. Neither is enabled in prod.

## Inspect → review → save or ask

1. Choose **Inspect UI**, then **Pick element**. Hover to outline it, click to
   select it without activating it, or press Escape to cancel. The picker
   records a pathname and element locator, not page HTML or form contents.
2. **Capture element** uses Region Capture in supported desktop Chromium
   browsers. Share **this tab** when prompted. Only the visible element crop
   becomes an attachment; the capture tracks are stopped afterward. Or use
   your OS region screenshot shortcut and paste into the feedback form, or
   attach a PNG, JPEG or WebP. Review the preview for private information;
   **Remove image** discards it. A note works without any screenshot.
3. **Save note** appends to the `web-ui-feedback` session without starting a
   run. **Ask agent** submits normal coding input to that session (queues if
   busy). This can incur model costs and execute host tools. Saved notes and
   images are history, and may be sent on a later ask. Use a vision-capable
   model for image feedback; use the full session view to configure it.
4. Keep browsing or minimize the panel. It shows the last three committed
   note/reply excerpts; **Open feedback session** has the full transcript,
   images and run controls. The dedicated session's working directory is
   the server's `clients/web` checkout, **not** the inspected directory.
   A screenshot and unsubmitted draft stay in memory across live navigation,
   but are discarded on a full page refresh. Submit before editing JS/HEEx.

## Pane composition

`HWeb.Workbench.split/1` is a function component with `:sidebar` and `:main`
slots, not a registry of pane processes. Both routes use it. The separator is
draggable or keyboard adjustable (arrows, Home, End); widths are per view and
browser tab. On narrow screens the workspace stacks and the session sidebar
becomes a drawer. The chat keeps its composer in place and follows output
only while you're at the bottom; **Latest** returns there.

- Put presentation in function components (`ConversationComponents`), and
  page markup in colocated `*.html.heex`. Keep URL params, subscriptions,
  command dispatch and the entry stream in the routed LiveView.
- A slot can contain `<.live_component module={MyComponent} id="filters" />`
  for local state/events in that same process. Target its events with
  `@myself`. Don't create a LiveComponent just to wrap markup.
- For independent subscriptions/lifecycle, render a child in the slot with
  `{live_render(@socket, MyLive, id: "activity")}`. Use a stable, unique ID.
  Pass only plain minimal session data and authenticate the child on mount.
  `InspectorLive` uses the sticky variant in the app layout so it survives
  navigation between routes; it doesn't borrow the routed chat's subscription.

The slotted navigation, bounded transcript and jump-to-latest interaction
were informed by `diy-chat`; there is no dependency on that project. This
workbench supports two resizable regions, not arbitrary drag-to-dock tabs.

## Check a change

Run `mix format`, `mix compile --warnings-as-errors`, and `mix test` here.
For a browser smoke check, pick the workspace's **Start New Session** button
(it must not start anything), preview a crop, and save a note. Open its
session, verify the image, and return to workspaces. Change a CSS rule, then
a HEEx label: the first should update without navigation and the second
should refresh the page and restore the inspector mode. None of these steps
requires a provider call.
