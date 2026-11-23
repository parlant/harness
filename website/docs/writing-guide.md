# Writing about H

Write for someone with a checkout open and a coding session they would rather not lose. The first sentence should tell them what H does. The next should give them something they can see or try. For example:

> H is a local daemon for coding-agent sessions. Branch from an earlier answer to try another approach. The original conversation is still there when you come back.

## Editorial references

Two local references informed this guide. The Jekyll template (`~/Work/Parlant/Templates/jekyll-website`, `5c9866a`) supplies the content model, not the voice. Its `docs/brief.md` asks who is reading and what they should do next. Its `docs/content-model.md` puts a page's title, description and section choices next to its Markdown, not in the renderer.

The Lukas Rieder site (`~/Work/Parlant/www.lukasrieder.com`, working copy based on `bd284d7`) supplies an editorial example. On [Work](https://www.lukasrieder.com/work/), a short introduction explains why the projects are grouped together; each description names a tool and its use. The [KMS project history](https://www.lukasrieder.com/blog/how-an-elixir-umbrella-let-kms-become-its-own-project/) starts with a storage constraint and explains why key management got its own OTP application. Borrow that order: problem, decision, consequence. Don't borrow the author's anecdotes. His `AGENTS.md` calls for full sentences, sentence-case subject headings, straight quotes and no em dashes in published prose.

## Pages and voice

| Surface | How to write it |
| --- | --- |
| Home | Name the object once: “H, a local coding-agent daemon”. Show the branch before explaining the process that owns it. Use a specific link such as “See the terminal demo”, not “Discover the power of H”. |
| Client demo | Guide the reader through one small, labeled example. Show where the paths diverge, which entry each client displays, and what stayed unchanged. Mark example output as an illustration. A static page does not run the daemon. Caption a diagram with what the reader should notice; its text alternative must explain the relationship without relying on colour or motion. |
| Setup or recipe | Address the operator as “you”. Start with a task and prerequisites. Say where to run the command, what it changes and what success looks like. If an action can send data, spend provider credit or run a tool with host permissions, tell the reader **before** the action. Finish with a check, not a slogan. |
| Reference | Use the literal command, field or component name as the heading. Put defaults, scope and failure behaviour beside the operation. Link to the recipe rather than repeating setup. |
| Portfolio | Write in the first person when explaining a choice the code demonstrates. Show a consequence for someone using it. No invented client, launch story, benchmark, sponsor, free tier or testimonial. A project note is not a second installation manual. |

### Terms that change the meaning

- **H** is the product. `h-daemon` is the standalone launcher. `hi` is the native terminal client. Phoenix LiveView supplies the web client. Opening a client and starting a server are different actions.
- Use *branch* to introduce a second path in a conversation. In instructions use the exact control: the terminal's `/fork` edits from a prompt's predecessor; `/branch` branches after an entry. Never describe a fork as cloning a directory, copying active tool calls or undoing filesystem changes. See [terminal implementation notes](../../docs/hi/build.md).
- Say *disconnect* or *detach* for leaving a client; reserve *interrupt* for stopping work. “You can close the terminal while the daemon runs” is narrower and more useful than “your work is never lost”.
- Say where data and effects go. History is stored locally with the file backend. A model request can go to an external provider. Host tools run with the user's permissions. A writer lease coordinates writes; it isn't a security boundary. Don't promise a sandbox, offline inference or access from another machine.
- For recovery, name the effect. “H reports an interrupted shell command instead of running it again” is testable. “H automatically resumes everything” is false. Keep retries distinct from items needing operator attention. Check the [architecture and recovery tests](../../docs/architecture.md#storage-and-recovery) before tightening any guarantee.

## Editing and placement

Give a page one reader, one question and one next action from the [discovery map](discovery.md). Put its distinguishing terms early in its title and description: “Branch a conversation in the terminal” is more findable than “Branching reimagined”. Use nouns that match the screen and verbs that describe the result. Keep command names in code, preserve their case, and don't use syntax-shaped placeholders in a purported transcript.

Keep page prose in Markdown; section titles and CTA labels particular to the page can live in its front matter. Put repeated records in `_data/`, shared interface labels in `_data/i18n/`, and markup and styling in layouts and includes. Link translations only when their pages exist. Keep `website/docs/` for excluded editorial material, **not** the source of a published `/docs/` route. Private paths, proposed domains and pre-launch research don't belong in metadata, generated LLM indexes or public copy.

Before review, read the headings alone. Could a reader find setup, a session fork and the host-permissions warning? Read the lead aloud; replace adjectives such as “seamless” with what actually stays connected. Compare each command with the [current setup instructions](../../README.md) and provider claims with [provider setup](../../docs/providers.md). Use the [roadmap](../../docs/roadmap.md) to spot proposals, not as proof that a feature shipped. Check links, captions and next actions in the rendered page. Leave a claim out if its only source is the design brief.
