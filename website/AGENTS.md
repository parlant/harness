# Editing the H website

Read the root `AGENTS.md`, [site instructions](README.md), [brief](docs/brief.md), [style decisions](docs/style-guide.md) and [writing guide](docs/writing-guide.md). This site is an adaptation of the Parlant Jekyll template and follows the editorial writing rules from `~/Work/Parlant/www.lukasrieder.com`.

- Page prose belongs in Markdown/front matter. Navigation, figure labels and shared records belong in `_data/`. Use `_layouts/` and `_includes/` for markup and Liquid. No HTML, CSS classes or executable scripts in Markdown.
- Apply the Unslop editing rules in [docs/writing-guide.md](docs/writing-guide.md): state what happens positively instead of adding defensive "what it is not" counter-statements, remove hedging and relativizations, use imperative verb-led calls to action, and use straight quotes with no em dashes.
- Keep English as the only published language until there is a real translation. Keep research, portfolio copy and release instructions in excluded `docs/`; the public manual lives in `manual/` with explicit permalinks.
- Update `_data/manual.yml` when adding a chapter. On documentation pages use the Kramdown TOC marker and descriptive level-two headings. Keep commands in fenced blocks and status claims anchored to source.
- Prefer platform interactions to JavaScript. Any new dependency needs a concrete interaction, accessibility and supply-chain review; record the decision first. Preserve lockfiles and `.npmrc`. Keep build outputs out of Git.
- Run `make verify` from `website/`. After layout changes check wide and narrow viewports, visible keyboard focus, disclosures and reduced motion. Test with fake example content, never personal accounts, tokens, transcripts or live model requests.
- A preview is not permission to set DNS, publish the portfolio or deploy a service. Obtain owner approval and run the release checks in `README.md`.
