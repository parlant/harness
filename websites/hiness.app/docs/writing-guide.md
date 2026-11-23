# Writing about H

Write for someone with a checkout open and a coding session they want to keep. Tell them what H does in the first sentence. Give them something to see or try in the second:

> H is a local daemon for coding-agent sessions. Start a review in your terminal, close the client, and follow the same run in your browser.

## Writing rules from `www.lukasrieder.com`

These rules synthesize the editorial instructions in `~/Work/Parlant/www.lukasrieder.com/AGENTS.md`, `docs/style-guide.md`, `docs/content-model.md`, `docs/writing-for-spoken-language.en.md`, `.agents/skills/show-and-tell/references/article-contract.md`, and the prose checks in `scripts/verify_site.rb`. Apply them to every page, caption, table cell, figure record, and metadata description on this site.

### 1. Say what happens instead of listing what it is not

AI-generated technical copy defaults to defensive contrasts: *"X does Y, not Z"*, *"This is A; it is not B"*, or *"Not just X, but Y"*. When every paragraph closes by denying a hypothetical misconception, the text sounds anxious and robotic.

- State positively what the software does, who owns the state, and where the data goes.
- Replace negative definitions with the actual mechanism:
  - Instead of: *"The daemon API lives under `/api/v1`. These are not Phoenix login or LiveView routes."*
  - Write: *"The daemon serves its JSON and SSE API under `/api/v1` on the local Unix socket and loopback HTTP listener."*
  - Instead of: *"An illustrated terminal, not a screenshot."*
  - Write: *"This diagram shows the `hi` transcript above the `/tree` conversation picker."*
  - Instead of: *"A release, a data directory and a workspace have different lifetimes. Replacing the executable does not move the conversation, its credentials or its working files."*
  - Write: *"Upgrading the H binary leaves your data directory, credentials, and project checkouts in place."*
- Keep an explicit boundary statement only where an operator could trigger an irreversible side effect, lose work, or misunderstand a security boundary:
  1. Host tools run with your OS user's file and shell permissions rather than inside a sandbox.
  2. After an unexpected crash, H marks an interrupted `write`, `edit`, or `bash` call as interrupted rather than rerunning it automatically.
  3. Disconnecting a client (`hi` or `hiweb`) leaves the daemon running; restarting the daemon recovers from committed disk state.
  4. Forking a conversation shares earlier history entries in the session store while both branches continue to use the same working directory on disk.
  5. The remote execution environment adapter is an in-VM prototype; off-machine transport is not shipped yet.
  6. External tools can queue follow-up turns through the local API; parent-child wake signals are internal to subagents.
- State each of those six boundaries once at the point where it affects a decision, in plain positive or causal terms, rather than repeating *"it is not a..."* across every page.

### 2. Cut relativizations, hedging, and mannered transitions

Remove throat-clearing qualifiers and self-important commentary:

- Cut hedging adverbs and qualifiers that weaken a factual statement: *"not necessarily"*, *"usually"*, *"normally"*, *"simply"*, *"merely"*, *"just"*, *"really"*, *"genuinely"*, *"arguably"*, *"in practice"*. If a condition applies, name the condition (`"When running under LaunchAgent..."`).
- Remove mannered bridge sentences that congratulate the design: *"This distinction matters"*, *"That caveat matters"*, *"The useful question has changed"*, *"A practical design"*, *"That restraint..."*, *"This is where X becomes practical"*.
- Do not open every paragraph with *"Suppose..."* or *"If all you need is..."*. Address the reader directly and start with the action or component.

### 3. Lead with imperative actions and direct calls to action

Passive descriptions tell the reader that features exist; imperative writing tells the reader how to use them and where to go next.

- Turn descriptive capability summaries into direct instructions:
  - Instead of: *"A conversation can select only tools its profile installed."*
  - Write: *"Select from the tools installed by the session's harness profile."*
  - Instead of: *"Catalog queries and `GET /api/v1/sessions/events` do not activate unloaded sessions."*
  - Write: *"Query the catalog or subscribe to `GET /api/v1/sessions/events` to inspect workspace summaries without loading dormant sessions into memory."*
- Give every section and feature an explicit, verb-led call to action (`"Follow the local setup guide"`, `"Switch clients mid-run"`, `"Inspect the terminal walkthrough"`, `"Delegate a read-only review"`, `"Configure a model provider"`).
- On `/features/`, replace bolded summary slogans with a concrete imperative action and link that lets the reader try or inspect the capability immediately.

### 4. Apply the Unslop vocabulary, syntax, and punctuation rules

- **Forbidden AI vocabulary**: Never use `additionally`, `crucial`, `delve`, `enduring`, `enhance`, `fostering`, `garner`, `interplay`, `intricate`, `landscape`, `leverage`, `pivotal`, `showcase`, `tapestry`, `testament`, `underscore`, `vibrant`, `substrate`, `wedge`, `vector`, `locus`, `nexus`, `primitive`, `scaffolding`, `paradigm`, `endgame`, `north star`, `flywheel`, `seamless`, or `seamlessly`.
- **Plain verbs**: Prefer `is`, `has`, `use`, `run`, `read`, `write`, and `help` over `serves as`, `stands as`, `boasts`, `utilize`, `facilitate`, and nominalizations ending in `-tion`, `-ment`, `-ance`, or `-ity`.
- **Active voice and named actors**: Name the component or person acting (`"H commits the task"`, `"Run hi -r"`, `"The coordinator checks the attempt"`). Use passive voice only when the actor is unknown or irrelevant.
- **Short sentences and close brackets**: Keep one main idea per sentence. Put known context before new information (topic before comment). Keep subjects close to their verbs and break up long chains of pre-noun modifiers.
- **Repeat clear names**: Use the exact name (`H`, `hi`, `hiweb`, `H.Session.Server`, `extensions.json`) instead of cycling through synonyms for stylistic variety.
- **Punctuation and typography**:
  - Use **straight quotes** (`"` and `'`) in source files and rendered copy; never use curly quotes (`“ ” ‘ ’`) or em dashes (`—`).
  - Do not replace em dashes with en dashes or spaced hyphens. Split the sentence or use a comma or semicolon.
  - Use colons only before genuine lists, commands, or examples, never mid-sentence as a rhetorical pause.
  - Write complete sentences in prose and list items. Avoid telegraphic fragments and lists where a bolded label merely repeats the sentence that follows.
  - Use sentence-case headings (`## Install a signed release`, `## Storage and recovery`). Avoid clever slogans, balanced rhetorical contrasts, and miniature lessons in headings.

## Pages and voice

| Surface | How to write it |
| --- | --- |
| Home | Open with the concrete continuity moment: start in `hi`, quit the terminal, and watch the same run in `hiweb`. Pair each selling point with a direct action link. Close with local operating prerequisites and a single route to `/docs/setup/`. |
| Features | Lead each section with what the reader can do, explain the concrete mechanism and operating boundary, and finish with an imperative link to the relevant walkthrough or manual chapter. |
| Client demo | Guide the reader through one labeled parser example across `/demo/`, `/demo/hi/`, and `/demo/hiweb/`. State what the figure shows and invite the reader to open each disclosure scenario. |
| Setup or recipe | Address the operator as "you". Start with the command or decision, state prerequisites and host-permission or billing consequences before any command that triggers them, and finish with an observable verification step. |
| Reference | Use literal component, route, command, or file names in headings and tables. Put defaults, scope, and recovery behavior next to the operation and link to the task guide. |
| Portfolio | Write in the first person ("I") when explaining an architectural choice and its consequence in `website/docs/portfolio/h.md`. Keep it grounded in verified code facts. |

## Terms that keep technical claims accurate

- **H** is the daemon (`:harness`). `h-daemon` is the standalone launcher, `hi` is the Rust terminal client, and `hiweb` is the Phoenix LiveView web client.
- Use *branch* or *fork* for starting a new conversation path from an earlier entry. In terminal instructions, name the exact command: `/branch` branches after a selected entry; `/fork` edits an earlier prompt from its predecessor.
- Use *disconnect* or *detach* (`/quit`) for closing a client while the daemon continues running. Reserve *abort* (`/abort`) or *stop* (`/stop`) for cancelling active work.
- Name where data and side effects happen: `H.Storage.File` writes session commits to `<data_dir>` (`~/.local/share/h` by default), model requests send context to the configured provider, and host tools execute in the workspace with the OS user's permissions.

## Separation and review checklist

Keep page prose in Markdown and front matter, shared figure and navigation records in `_data/`, interface labels in `_data/i18n/en.yml`, and HTML/Liquid in `_layouts/` and `_includes/`. Keep `website/docs/` excluded from the published build.

Before finishing any copy pass:

1. Scan all Markdown and YAML files for curly quotes, em dashes, forbidden AI vocabulary, and `"not a"` / `"neither"` / `"rather than"` defensive reflexes.
2. Read the headings and link labels alone to confirm they name clear subjects and direct actions.
3. Run `make verify` from `website/` and update the staging build for the LAN preview if it is running.
