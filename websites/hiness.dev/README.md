# hiness.dev website

Primary developer website for **H** (`hiness` by Parlant GmbH): CLI (`hi`), local OTP daemon (`:harness`), browser workbench (`hiweb`), 16-chapter operator manual, illustrated demos, and extension directory. Companion macOS application site lives in `../hiness.app` (`https://hiness.app`), and synchronized company/release records live in `../shared/`.

Start with [the director's brief](docs/brief.md), [design direction](docs/style-guide.md), [naming and search research](docs/discovery.md), and [writing guide](docs/writing-guide.md).

## Preview and verify

From `websites/hiness.dev/`, use Ruby/Bundler and Node/npm (Ruby 3.3+, Bundler 2.4+, Node 22+, npm 11+):

```sh
bundle config set --local path vendor/bundle
bundle install
npm ci --ignore-scripts
make verify
make serve
```

`make serve` binds loopback (`127.0.0.1` by default, override with `HOST=...` and `PORT=...`). Rebuild styles after changing templates (`npm run css:build`), or run `npm run css:watch` alongside the server. Reload the browser after changes; LiveReload is off by default. If an older preview left broken symlinks in `_site`, run `make clean` once. `make verify` builds production-mode HTML and checks routes, fragments, sitemap membership, `llms.txt` / `llms-full.txt`, straight-quote punctuation, and slop vocabulary.

## Shared records across hiness.dev and hiness.app

`websites/shared/` provides the single source of truth symlinked into both sites:

- `websites/shared/data/company.yml` -> `_data/company.yml` (Parlant GmbH statutory details)
- `websites/shared/data/releases.yml` -> `_data/releases.yml` (news dispatches, release changelog, artifacts, GitHub & GitLab URLs)
- `websites/shared/includes/{forge-icons,release-feed,legal-notice-body,privacy-body}.html` -> `_includes/`

Keep `websites/hiness.dev/install.sh` byte-identical to `../../scripts/install.sh` (`diff -u scripts/install.sh websites/hiness.dev/install.sh` runs in CI).

## Production build (`https://hiness.dev`)

Production deploys to Cloudflare Pages (`hiness-dev`) pass `_config.prod.yml` alongside `_config.yml`:

```sh
npm run css:build
JEKYLL_ENV=production bundle exec jekyll build --config _config.yml,_config.prod.yml --destination _site
ruby scripts/verify_site.rb _site
```
