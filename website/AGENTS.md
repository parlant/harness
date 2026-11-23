# Editing the H website

Read the root `AGENTS.md`, [site instructions](README.md), [brief](docs/brief.md), [style decisions](docs/style-guide.md) and [writing guide](docs/writing-guide.md). This is an adaptation of the Parlant Jekyll template, not another client of the daemon.

- Page prose belongs in Markdown/front matter. Navigation, figure labels and shared records belong in `_data/`. Use `_layouts/` and `_includes/` for markup and Liquid. No HTML, CSS classes or executable scripts in Markdown.
- Keep English as the only published language until there is a real translation. Keep research, portfolio copy and release instructions in excluded `docs/`; the public manual lives in `manual/` with explicit permalinks.
- Update `_data/manual.yml` when adding a chapter. On documentation pages use the Kramdown TOC marker and descriptive level-two headings. Keep commands in fenced blocks and status claims anchored to source.
- Prefer platform interactions to JavaScript. Any new dependency needs a concrete interaction, accessibility and supply-chain review; record the decision first. Preserve lockfiles and `.npmrc`. Keep build outputs out of Git.
- Run `make verify` from `website/`. After layout changes check wide and narrow viewports, visible keyboard focus, disclosures and reduced motion. Test with fake example content, never personal accounts, tokens, transcripts or live model requests.
- A preview is not permission to set DNS, publish the portfolio or deploy a service. Obtain owner approval and run the release checks in `README.md`.
