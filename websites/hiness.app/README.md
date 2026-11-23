# hiness.app website

Dedicated macOS (and future iOS) website for **H.app** (`hiness` by Parlant GmbH): native Swift/AppKit menu-bar supervisor, embedded OTP 29 + Rust bundle, drag-and-drop `.dmg` / `.app.zip` installation, and synchronized release history. Companion CLI and operator manual live in `../hiness.dev` (`https://hiness.dev`), and shared company/release records live in `../shared/`.

## Preview and verify

From `websites/hiness.app/`, use Ruby/Bundler and Node/npm:

```sh
bundle config set --local path vendor/bundle
bundle install
npm ci --ignore-scripts
make verify
make serve
```

`make serve` defaults to port `8082` (override with `HOST=...` and `PORT=...`). `make verify` compiles Tailwind v4 CSS, builds production HTML, and validates all routes (`/`, `/bundle/`, `/ios/`, `/releases/`, `/legal-notice/`, `/privacy/`), anchors, `sitemap.xml`, `llms.txt` / `llms-full.txt`, straight quotes, and editorial rules.

## Production build (`https://hiness.app`)

Production deploys to Cloudflare Pages (`hiness-app`) pass `_config.prod.yml` alongside `_config.yml`:

```sh
npm run css:build
JEKYLL_ENV=production bundle exec jekyll build --config _config.yml,_config.prod.yml --destination _site
ruby scripts/verify_site.rb _site
```
