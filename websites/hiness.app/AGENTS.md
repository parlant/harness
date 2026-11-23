# Editing hiness.app

Read the root `AGENTS.md`, [site instructions](README.md), and `../hiness.dev/docs/{style-guide,writing-guide}.md`. Companion CLI/manual site lives in `../hiness.dev`, and shared company/release records live in `../shared/`.

- Page prose belongs in Markdown/front matter. Shared corporate and release records live in `../shared/data/` (symlinked into `_data/`). Markup and Liquid belong in `_layouts/` and `_includes/`. Zero raw HTML, CSS classes, or executable scripts in Markdown.
- Apply the Unslop editing rules: state behavior positively, use imperative calls to action, and use straight quotes (`"` and `'`) with zero curly quotes and zero em dashes.
- Keep all `H.app` claims anchored to [`packaging/macos/HApp.swift`](https://github.com/parlant/harness/blob/main/packaging/macos/HApp.swift), [`packaging/macos/Info.plist.in`](https://github.com/parlant/harness/blob/main/packaging/macos/Info.plist.in), and [`scripts/build-macos-app.sh`](https://github.com/parlant/harness/blob/main/scripts/build-macos-app.sh). Keep planned iOS/iPadOS companion work clearly labeled as planned.
- Preserve lockfiles (`Gemfile.lock`, `package-lock.json`) and `.npmrc`. Keep `_site/` out of Git.
- Run `make verify` from `websites/hiness.app/` (and `websites/hiness.dev/` whenever `websites/shared/` changes).
