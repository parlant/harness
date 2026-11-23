# H website

A static, English-language site. It doesn’t run the harness. Start with [the director’s brief](docs/brief.md), [design direction](docs/style-guide.md), [naming and search research](docs/discovery.md) and [writing guide](docs/writing-guide.md). The [portfolio handoff](docs/portfolio/) is for the separate Lukas Rieder site, not a second copy of this landing page.

## Preview and verify

From `website/`, use Ruby/Bundler and Node/npm (template CI baseline: Ruby 3.3, Bundler 2.4.22, Node 22 and npm 11). No Elixir application, provider key, account store or database is needed.

```sh
bundle config set --local path vendor/bundle
bundle install
npm ci --ignore-scripts
make verify
make serve
```

The server prints a loopback URL (port 8080 or next available). Rebuild styles after changing templates, or run `npm run css:watch` alongside the server. `make verify` builds production-mode HTML then checks local routes, fragments, sitemap membership and LLM indexes. `_site/`, `vendor/`, `node_modules/`, caches and compiled CSS are local build products.

## Where things live

| Edit | Location |
|---|---|
| Home narrative and section order | `index.md` front matter |
| Illustrated examples | `demo/`, `_data/figures.yml` |
| Public documentation | `manual/*.md` and subdirectories; explicit `/docs/…/` permalinks; add entries to `_data/manual.yml` |
| Public extension directory | `extensions/` |
| Site shell, chapter navigation and diagrams | `_layouts/`, `_includes/`, `_data/navigation.yml`, `_data/i18n/` |
| Style | `assets/css/input.css` imports component rules; edit source, not `main.css` |
| Private editorial/release documents | `docs/` (excluded by Jekyll) |

Keep page-specific prose in Markdown/front matter, reusable records in YAML and presentation in Liquid/CSS. Use root-relative links in Markdown so the LLM plugin can emit ordinary absolute links. Deploy **at an origin root**, not a project subpath. The public manual is a task-oriented introduction; verify changes to commands and security boundaries against the linked engine docs and tests. Don’t confuse the static demo with a hosted instance of `hiweb`.

## Provenance and release

Adapted from `Parlant/Templates/jekyll-website` at `5c9866a41167327b5a64d2ee68daeff0761b2e9a`. Kept the locked Jekyll stack, Tailwind 4, typography and DaisyUI `lofi`, npm release-age policy, auto-port server and verify workflow. Removed sample blog and translations. No new npm dependencies, client framework, runtime analytics or CDN requests. No nested Git repository or deployment credentials. The template’s root-project CI is intentionally **not** copied over the harness pipeline.

The checked-in origin is loopback. Preview pages request no indexing. After domain, public source access/licensing and copy approval, pass an **outside-the-site** config file to Jekyll containing `url: https://<approved-host>` and `preview: false`. From `website/`:

```sh
npm run css:build
JEKYLL_ENV=production bundle exec jekyll build --config _config.yml,/absolute/path/to/site-release.yml
ruby scripts/verify_site.rb _site
```

Inspect `robots.txt`, canonical tags, `/sitemap.xml`, `/llms.txt` and `/llms-full.txt` on the final origin. Upload **only `_site/`** to a static host with HTTPS; never serve the checkout. Confirm the settings at the live domain before enabling discovery. No deployment, registration, recurring fee or CI publisher is implied by the preview.
