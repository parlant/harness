# Director’s brief · review before launch

**What hooks a visitor?** A developer already has a terminal and a chat UI. Show a familiar moment: quit the terminal and follow the same active run in the browser. Make that continuity the hook ("Close your terminal. *Your Hiness keeps court.*"), paired with a dark museum-gallery aesthetic for **`hiness.dev`** and **`hiness.app`**. Let the demos show branching as a separate capability, and map royal houses truthfully to `H.Harness` session profiles (`coding`, `example.greeting.v1`, custom `H.Harness`, and embedded `:harness`). Present the terminal UI and desktop/mobile browsers as supported surfaces, paired with `H.app` on macOS. Local file storage and few direct dependencies support the lean-core story. Keep `_config.yml` preview-safe until explicit owner DNS/launch approval.

**What does the visitor need to decide?** Replace “what is it good for?” and “how does it help?” (the same question) with a task and proof. Ask, in order:

1. Is this for me? A local coding-agent daemon for people who work in a checkout.
2. What can I do differently? Try a second approach without copying a transcript or abandoning the first.
3. Can I see that happen? An example session timeline, followed by a practical guide to switching clients and two illustrated fork demos.
4. Where does it run and what must I trust? My machine, my provider, my user’s permissions. Not a hosted or sandboxed agent service.
5. What do I need to try it? Supported development tools, one daemon, an owner token, a client. Send the visitor to setup, not to five equal calls to action.
6. If I build on it, where is the seam? Protocol for clients, trusted startup packages for extensions, documented behaviours for tools and profiles.

## Page and interaction contract

- Home: proposition + session timeline → recovery → synchronized clients → ways to extend → local operating boundary and first-run route. In a five-second read a visitor should be able to say what H is and explain what happens when the terminal closes. No splash delay.
- Demo: a self-contained example in each client; show the same scenario and distinguish a diagram from a live session. Mobile gets the same content, not a clipped desktop screenshot.
- Manual: a task index for setup and configuration, references for architecture/clients/extensions/security, then recipes and contribution. Desktop chapter navigation, mobile disclosure, linked section headings/contents. Teach ancestry vs ownership vs supervision vs cursor. One canonical recipe per task.
- Extensions: browse by what exists, not popularity. Each detail states purpose, authority, boot/disable path, limits and source. No store or one-click executable installs.
- Machine readers: generated sitemap and LLM indexes from the published pages. Portfolio copy is a separate handoff. Never publish internal planning, local paths or review drafts as articles.

## Roles and sequence

| Gate | Owner | Evidence required to move on |
|---|---|---|
| Discover | Product editor + researcher | Check real commands/claims against repository; inspect site template and portfolio schema; compare candidate names and search intents. |
| Shape | Information architect + art director | Prioritised questions above; one route per task; annotated hero timeline; mobile, no-script and reduced-motion states. |
| Produce preview | Interaction designer + docs editor + static-site engineer | Content in Markdown/data, presentation in Liquid/CSS, native controls first; use locked template tools only. Work in independent lanes. |
| Integrate | Director | Read end to end, resolve conflicting names/status, verify output and local links, inspect narrow and wide layouts. |
| Release | Owner + director | Owner confirms emphasis, voice, name, domain cost and portfolio publication; check domain again, set canonical URL, run build/link/keyboard/motion checks, then publish. No registration or deployment from this pass. |
