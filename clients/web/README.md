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
needed. To enable Monaco for file review, run
`(cd assets && npm ci && npm run build)` once in `clients/web` (and when the
asset lockfile changes). Without the assets, plain-text review still works.
Native bundle builds package Monaco; there is no CDN or runtime Node dependency.
Restart for configuration, dependency, supervision
or engine changes. The reloader and inspector are development tools: keep the
server on loopback, not behind a public proxy. Neither is enabled in prod.

## Attach a screenshot or file in chat

Open **Reply**, then choose **Attach file** (+) beside the model button.
Choose one PNG, JPEG or WebP image (up to 2 MiB), or one UTF-8 text file
(up to 64 KiB). Review the filename and screenshot preview, then add a note
and press **Send**. **Remove** lets you discard the selection before sending.
If your phone saves HEIC photos, use a screenshot or export to JPEG first.

For UI feedback, include your device/browser, what you did and what you expected.
Sending adds the attachment to conversation history and submits it to the agent;
use a vision-capable model for screenshots. Remove private information before
sending. The file is not copied into the workspace. Switching conversations or
reloading discards the unsent attachment. This works in the bundled Web UI
without enabling the development inspector below.

## Inspect → review → save or ask (development only)

1. Choose **Main menu → Inspect UI**, then **Pick element**. Hover to outline it, click to
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

Authenticated pages share `HWeb.Layouts.app_bar/1`: one row for navigation,
page title and immediate actions. The main menu opens over the page. The central
content takes the remaining viewport height and scrolls independently of the bar.
In a session this is the transcript. **Reply** reveals the message field; **Hide
reply** tucks it away without clearing text or the selected attachment. The model
button in the composer opens **Agent settings**. Browsing providers doesn't
change the conversation; choosing a model or reasoning level applies it directly.
The transcript follows output while you're at the end. Reading earlier messages
turns following off; **Latest** returns to the end. **Stop** remains available
during a run even with the composer closed.

Session details (**⋯**), workspace sessions and Inbox filters use native dialog
panels rather than expanding the header. File review uses `HWeb.Workbench.split/1`
with `:sidebar` and `:main` slots; the separator is draggable or keyboard adjustable
(arrows, Home, End). Width is per view and browser tab. On narrow screens **Browse**
switches between the tree and the editor rather than stacking two scroll areas.

The Inbox filter panel and session details share working-directory, tag, and text filters.
The filters travel in the URL: opening a row, jumping to the next session
needing attention, switching branches, and returning to the Inbox preserve
them. A directory filter matches the exact environment and directory; a tag
filter matches the full tag. Use **Clear filters** to reset the view. Edit a
session's tags in **Session details**. In the Inbox browser,
`n`/`p` cycle through attention rows; Tab moves between controls.

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

## Conversation display

The session transcript shows user messages and assistant replies. Assistant
replies render Markdown while streaming and after commit; fenced `console`
and shell blocks use a scrollable terminal style and are never executed.
User text stays plain, and attached screenshots display in the transcript.
Markdown does not render raw HTML or load images from URLs.

Consecutive tool and system activity appears in one line between messages,
including across **Load earlier** pages. A tool call and its result count once.
The line shows a spinner while work is underway, or a status such as **Waiting**,
**Complete**, **Paused**, or **Failed**. This is a web display change; the daemon
and `hi` still have the original transcript and tool output.

## Check a change

Run `mix format`, `mix compile --warnings-as-errors`, and `mix test` here.
For a browser smoke check, pick the workspace's **Start New Session** button
(it must not start anything), preview a crop, and save a note. Open its
session, verify the image, and return to workspaces. Change a CSS rule, then
a HEEx label: the first should update without navigation and the second
should refresh the page and restore the inspector mode. None of these steps
requires a provider call.

## Review working files and commits

- **Workspaces → Review files** opens a dedicated **File review** session for
  that environment and directory. Reopening the workspace reuses its latest
  empty review session; after it has a transcript entry, the next open creates
  a fresh one. It does not reuse or alter unrelated sessions. Opening files
  does not start an agent run.
- **Session → ⋯ → Review files** opens review in the displayed conversation,
  including a fork. **Inbox → Files** uses the row's session. Return to the
  session to see comments in its transcript.
- In a git worktree, **Changes** shows staged, unstaged and untracked files
  under the session directory. **HEAD** and **Diff** compare with the last
  commit, not the index. Deleted text files can be read from HEAD. **All files**
  browses the directory tree and is the default outside git. Expand or collapse
  folders in place; each open folder has its own page, and closing a branch
  doesn't close the file you're reading. Git discovery is read-only and skips
  configured filters and hooks; a touched-but-unchanged tracked file can appear
  as modified until git refreshes its index.
- **History** lists commits from local Git history. Page through them or jump
  to a full or abbreviated commit hash. **Changes** compares the selected
  commit with its first parent (an empty tree for the initial commit);
  **All files** browses the selected snapshot under the session directory.
  Use **Commit file** or **Parent file** to read and comment on either side,
  including deleted text. History never checks out or writes a commit, and
  doesn't fetch missing history in a shallow clone. **Working tree** returns
  to the editable view.
- **Diff** shows one inline view of additions and deletions, including
  whitespace-only changes. Long unchanged sections are collapsed with three
  lines of context and can be expanded in place. This applies to both working
  changes and historical commits.
- Select text in a file view, choose **Use selected text**, and enter a comment.
  **Save comment** writes the verified path, revision, range, and excerpt to the
  active conversation without a provider call. Historical comments include the
  full commit hash of the selected text. **Ask agent**
  sends the comment as normal input and can start or queue a run. Highlights mark
  the draft selection; they are not persistent inline threads.
- The open working file and visible working-tree listings refresh periodically. Unsaved
  text is kept when a file changes on disk; discard the draft to reload. Saving
  checks the source revision and uses the workspace's writer lease to avoid
  overwriting agent edits. It does not stage changes. Save before leaving the
  view. Review skips symlinks and `.git`; it is not a sandbox for agent tools.
- Review supports UTF-8 text up to 512 KiB. Compatible image, audio, and video
  formats preview up to 16 MiB (codec support depends on the browser). HTML
  previews are static and sandboxed: no scripts or external assets.
